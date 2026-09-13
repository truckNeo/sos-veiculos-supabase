begin;
-- Upgrade installations that applied the isolated product migration under its old name.
do $$ begin
  if to_regclass('public.product_notifications') is null and exists(select 1 from information_schema.columns where table_schema='public' and table_name='app_notifications' and column_name='category') then
    alter table public.app_notifications rename to product_notifications;
  end if;
end $$;

alter table public.vehicle_maintenance_plans add column occurrence_id uuid not null default gen_random_uuid(),
 add column revision integer not null default 1, add column remind_days integer not null default 7 check(remind_days between 0 and 365),
 add column remind_km integer not null default 500 check(remind_km between 0 and 100000);
alter table public.vehicle_maintenance_records drop constraint vehicle_maintenance_records_plan_id_previous_due_date_key;
alter table public.vehicle_maintenance_records add column occurrence_id uuid unique,
 add column title_snapshot text, add column interval_days_snapshot integer, add column interval_km_snapshot integer,
 add column previous_due_odometer integer, add column service_request_id uuid references public.service_requests(id);
create unique index maintenance_request_once on public.vehicle_maintenance_records(plan_id,service_request_id) where service_request_id is not null;
create index maintenance_records_page on public.vehicle_maintenance_records(plan_id,completed_at desc,id);

create table public.vehicle_odometer_readings (
 id uuid primary key default gen_random_uuid(), vehicle_id uuid not null references public.vehicles(id),
 odometer integer not null check(odometer>=0), observed_at timestamptz not null, created_at timestamptz not null default now(),
 recorded_by uuid not null references public.profiles(id), correction_reason text,
 previous_id uuid references public.vehicle_odometer_readings(id), command_id uuid not null unique
);
create index odometer_latest on public.vehicle_odometer_readings(vehicle_id,created_at desc,id);
alter table public.vehicles add column odometer_reading_id uuid references public.vehicle_odometer_readings(id);
alter table public.vehicle_odometer_readings enable row level security;
grant select on public.vehicle_odometer_readings to authenticated;
create policy odometer_manager on public.vehicle_odometer_readings for select to authenticated using(public.can_manage_vehicle(vehicle_id));
-- Never let a direct vehicle update forge the current reading.
create function public.guard_vehicle_odometer() returns trigger language plpgsql set search_path=public as $$ begin
 if current_user in ('authenticated','anon') and ((tg_op='INSERT' and new.odometer_reading_id is not null) or (tg_op='UPDATE' and new.odometer_reading_id is distinct from old.odometer_reading_id)) then
  raise exception 'Atualize a quilometragem pela operação autorizada.' using errcode='42501';
 end if; return new; end $$;
create trigger vehicle_odometer_guard before insert or update on public.vehicles for each row execute function public.guard_vehicle_odometer();

create function public.record_vehicle_odometer(p_vehicle_id uuid,p_odometer integer,p_expected_id uuid,p_command_id uuid,p_correction_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v public.vehicles; previous public.vehicle_odometer_readings; existing public.vehicle_odometer_readings; result uuid;
begin
 if auth.uid() is null or not public.can_manage_vehicle(p_vehicle_id) then raise exception 'Veículo indisponível.' using errcode='42501'; end if;
 select * into v from public.vehicles where id=p_vehicle_id for update;
 select * into existing from public.vehicle_odometer_readings where command_id=p_command_id;
 if found then
  if existing.vehicle_id<>p_vehicle_id or existing.recorded_by<>auth.uid() or existing.odometer is distinct from p_odometer then raise exception 'Comando já utilizado.'; end if;
  return existing.id;
 end if;
 if p_command_id is null or p_odometer is null or p_odometer<0 then raise exception 'Quilometragem inválida.'; end if;
 if v.odometer_reading_id is distinct from p_expected_id then raise exception 'Quilometragem atualizada por outra operação. Recarregue.'; end if;
 select * into previous from public.vehicle_odometer_readings where id=v.odometer_reading_id;
 if p_correction_reason is not null and length(trim(p_correction_reason)) not between 10 and 500 then raise exception 'Explique a correção entre 10 e 500 caracteres.'; end if;
 if previous.odometer>p_odometer and p_correction_reason is null then raise exception 'Quilometragem menor exige correção justificada.'; end if;
 insert into public.vehicle_odometer_readings(vehicle_id,odometer,observed_at,recorded_by,previous_id,command_id,correction_reason)
 values(p_vehicle_id,p_odometer,now(),auth.uid(),v.odometer_reading_id,p_command_id,nullif(trim(p_correction_reason),'')) returning id into result;
 update public.vehicles set odometer_reading_id=result where id=p_vehicle_id;
 perform public.enqueue_product_reminders();
 return result;
end $$;

create function public.maintenance_revision() returns trigger language plpgsql set search_path=public as $$ begin
 if new.vehicle_id<>old.vehicle_id or new.created_by<>old.created_by then raise exception 'Veículo e responsável do plano não podem ser alterados.'; end if;
 new.revision=old.revision+1;
 if current_user in ('authenticated','anon') then new.occurrence_id=old.occurrence_id; end if;
 new.updated_at=now();
 return new;
end $$;
create trigger maintenance_revision before update on public.vehicle_maintenance_plans for each row execute function public.maintenance_revision();
-- Versioned completion avoids stale clients advancing a different km-based occurrence.
create or replace function public.complete_vehicle_maintenance(p_plan_id uuid,p_expected_due_date date,p_odometer integer default null)
returns void language plpgsql security definer set search_path=public as $$ begin
 raise exception 'Atualize o aplicativo para registrar esta manutenção.';
end $$;
create function public.complete_vehicle_maintenance_v2(p_plan_id uuid,p_occurrence_id uuid,p_revision integer,p_odometer integer,p_expected_reading_id uuid,p_request_id uuid default null)
returns void language plpgsql security definer set search_path=public as $$
declare p public.vehicle_maintenance_plans; vehicle uuid;
begin
 select vehicle_id into vehicle from public.vehicle_maintenance_plans where id=p_plan_id;
 if vehicle is null or not public.can_manage_vehicle(vehicle) then raise exception 'Plano indisponível.' using errcode='42501'; end if;
 -- Consistent lock order: vehicle before plan, shared with odometer updates.
 perform 1 from public.vehicles where id=vehicle for update;
 select * into p from public.vehicle_maintenance_plans where id=p_plan_id for update;
 if exists(select 1 from public.vehicle_maintenance_records where plan_id=p.id and occurrence_id=p_occurrence_id) then return; end if;
 if p.occurrence_id is distinct from p_occurrence_id or p.revision is distinct from p_revision then raise exception 'Plano atualizado. Recarregue.'; end if;
 if p.interval_km is not null and p_odometer is null then raise exception 'Informe a quilometragem atual.'; end if;
 if p_request_id is not null and not exists(select 1 from public.service_requests r join public.service_appointments a on a.service_request_id=r.id
   where r.id=p_request_id and r.vehicle_id=p.vehicle_id and r.status='completed' and a.maintenance_plan_id=p.id) then raise exception 'Atendimento concluído não vinculado a este plano.'; end if;
 if p_odometer is not null then perform public.record_vehicle_odometer(p.vehicle_id,p_odometer,p_expected_reading_id,p_occurrence_id); end if;
 insert into public.vehicle_maintenance_records(plan_id,completed_by,odometer,previous_due_date,occurrence_id,title_snapshot,interval_days_snapshot,interval_km_snapshot,previous_due_odometer,service_request_id)
 values(p.id,auth.uid(),p_odometer,p.due_date,p.occurrence_id,p.title,p.interval_days,p.interval_km,p.due_odometer,p_request_id);
 update public.vehicle_maintenance_plans set due_date=current_date+p.interval_days,
 due_odometer=case when p.interval_km is not null then p_odometer+p.interval_km else null end,occurrence_id=gen_random_uuid() where id=p.id;
 perform public.enqueue_product_reminders();
end $$;

alter table public.service_appointments add column service_request_id uuid unique references public.service_requests(id),
 add column maintenance_plan_id uuid references public.vehicle_maintenance_plans(id);
alter table public.service_appointments drop constraint service_appointments_status_check;
alter table public.service_appointments add constraint service_appointments_status_check check(status in ('requested','confirmed','in_service','rejected','cancelled','completed'));
alter table public.service_requests add column scheduled_provider_id uuid references public.provider_profiles(provider_id);

create function public.create_service_appointment_v2(p_vehicle_id uuid,p_provider_id uuid,p_starts_at timestamptz,p_duration_minutes integer,p_description text,p_plan_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$ declare result uuid; begin
 if p_plan_id is not null and not exists(select 1 from public.vehicle_maintenance_plans where id=p_plan_id and vehicle_id=p_vehicle_id and public.can_manage_vehicle(vehicle_id)) then raise exception 'Plano indisponível.' using errcode='42501'; end if;
 result=public.create_service_appointment(p_vehicle_id,p_provider_id,p_starts_at,p_duration_minutes,p_description);
 update public.service_appointments set maintenance_plan_id=p_plan_id where id=result;
 return result;
end $$;

create function public.convert_service_appointment(p_id uuid,p_problem_type public.request_problem_type,p_description text,p_latitude double precision,p_longitude double precision,p_address_label text)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare a public.service_appointments; result uuid;
begin
 select * into a from public.service_appointments where id=p_id for update;
 if not found or auth.uid() is distinct from a.requester_id or not public.can_manage_vehicle(a.vehicle_id) then raise exception 'Agendamento indisponível.' using errcode='42501'; end if;
 if a.service_request_id is not null then return a.service_request_id; end if;
 if a.status<>'confirmed' or a.starts_at>now() then raise exception 'Aguarde o horário do agendamento confirmado.'; end if;
 if p_problem_type is null or p_latitude is null or not(p_latitude between -90 and 90) or p_longitude is null or not(p_longitude between -180 and 180)
 or length(trim(coalesce(p_description,''))) not between 5 and 2000 or length(trim(coalesce(p_address_label,''))) not between 3 and 500 then raise exception 'Confirme categoria, descrição e localização do atendimento.'; end if;
 perform 1 from public.vehicles where id=a.vehicle_id and status='active' for update;
 if not found then raise exception 'Veículo inativo.'; end if;
 if exists(select 1 from public.service_requests where vehicle_id=a.vehicle_id and status not in ('completed','cancelled')) then raise exception 'O veículo já possui chamado em aberto.'; end if;
 if not exists(select 1 from public.provider_profiles p join public.provider_locations l on l.provider_id=p.provider_id
  where p.provider_id=a.provider_id and p.is_available and l.updated_at>=now()-interval '15 minutes'
  and extensions.st_dwithin(extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography,l.location,p.service_radius_km*1000))
 or not exists(select 1 from public.provider_services where provider_id=a.provider_id and problem_type=p_problem_type)
 or not exists(select 1 from public.provider_vehicles where provider_id=a.provider_id and is_active) then raise exception 'Prestador deve atualizar disponibilidade, localização, especialidade e veículo operacional.'; end if;
 insert into public.service_requests(requester_id,vehicle_id,problem_type,description,latitude,longitude,address_label,scheduled_provider_id)
 values(auth.uid(),a.vehicle_id,p_problem_type,trim(p_description),p_latitude,p_longitude,trim(p_address_label),a.provider_id) returning id into result;
 update public.service_appointments set service_request_id=result,status='in_service',updated_at=now() where id=a.id;
 insert into public.service_request_events(request_id,actor_id,status,note) values(result,auth.uid(),'open','Chamado originado de agendamento confirmado.');
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 values(a.provider_id,'appointments','Atendimento agendado iniciado','Envie sua proposta para continuar.',a.id,a.id::text||':in_service') on conflict(dedupe_key) do nothing;
 return result;
end $$;

create function public.guard_scheduled_dispatch() returns trigger language plpgsql security definer set search_path=public as $$ declare target uuid; begin
 select scheduled_provider_id into target from public.service_requests where id=new.request_id;
 if target is not null and target<>new.provider_id then return null; end if;
 return new;
end $$;
create trigger scheduled_dispatch_guard before insert on public.service_request_dispatches for each row execute function public.guard_scheduled_dispatch();
create function public.guard_scheduled_offer() returns trigger language plpgsql security definer set search_path=public as $$ declare target uuid; begin
 select scheduled_provider_id into target from public.service_requests where id=new.request_id;
 if target is not null and target<>new.provider_id then raise exception 'Chamado reservado ao prestador agendado.' using errcode='42501'; end if;
 return new;
end $$;
create trigger scheduled_offer_guard before insert or update on public.provider_offers for each row execute function public.guard_scheduled_offer();
-- Provider cancellation must not reopen a scheduled request to the network.
create function public.scheduled_request_cancel() returns trigger language plpgsql set search_path=public as $$ begin
 if old.scheduled_provider_id is not null and old.selected_provider_id is not null and new.selected_provider_id is null and new.status='open' then
 new.status='cancelled'; new.workflow_phase='cancelled'; new.closed_at=now(); end if; return new;
end $$;
create trigger scheduled_request_cancel before update on public.service_requests for each row execute function public.scheduled_request_cancel();
create function public.sync_service_appointment() returns trigger language plpgsql security definer set search_path=public as $$ declare a public.service_appointments; state text; begin
 state=case when new.status='completed' then 'completed' when new.status='cancelled' then 'cancelled' else 'in_service' end;
 update public.service_appointments set status=state,updated_at=now() where service_request_id=new.id and status<>state returning * into a;
 if found then
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 select u,'appointments','Atendimento atualizado','Consulte o resultado do atendimento agendado.',a.id,a.id::text||':'||state||':'||u::text from unnest(array[a.requester_id,a.provider_id]) u on conflict(dedupe_key) do nothing;
 end if; return new;
end $$;
create trigger service_appointment_sync after update of status on public.service_requests for each row execute function public.sync_service_appointment();

create function public.list_maintenance_history(p_vehicle_id uuid,p_offset integer default 0)
returns table(id uuid,plan_id uuid,title text,completed_at timestamptz,odometer integer,completed_by_name text,service_request_id uuid)
language plpgsql stable security definer set search_path=public as $$ begin
 if not public.can_manage_vehicle(p_vehicle_id) then raise exception 'Veículo indisponível.' using errcode='42501'; end if;
 return query select r.id,r.plan_id,coalesce(r.title_snapshot,'Manutenção (registro anterior)'),r.completed_at,r.odometer,p.full_name,r.service_request_id
 from public.vehicle_maintenance_records r join public.vehicle_maintenance_plans m on m.id=r.plan_id join public.profiles p on p.id=r.completed_by
 where m.vehicle_id=p_vehicle_id order by r.completed_at desc,r.id desc limit 20 offset greatest(coalesce(p_offset,0),0);
end $$;

create or replace function public.enqueue_product_reminders() returns void language plpgsql security definer set search_path=public as $$ begin
 perform public.expire_vehicle_share_accesses();
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 select p.created_by,'maintenance',case when p.due_date<=current_date or o.odometer>=p.due_odometer then 'Manutenção vencida' else 'Manutenção próxima' end,
 'Consulte o plano e confirme os dados de quilometragem.',p.id,
 'maintenance:'||p.id::text||':'||p.occurrence_id::text||':'||p.revision::text||':'||case when p.due_date<=current_date or o.odometer>=p.due_odometer then 'due' else 'soon' end
 from public.vehicle_maintenance_plans p join public.vehicles v on v.id=p.vehicle_id left join public.vehicle_odometer_readings o on o.id=v.odometer_reading_id
 where (p.due_date<=current_date+p.remind_days or o.odometer>=p.due_odometer-p.remind_km)
 and (v.owner_profile_id=p.created_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=p.created_by))
 on conflict(dedupe_key) do nothing;
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 select u,'appointments','Agendamento próximo','Consulte os detalhes do seu horário.',a.id,'appointment-reminder:'||a.id::text||':'||u::text
 from public.service_appointments a cross join lateral unnest(array[a.requester_id,a.provider_id]) u
 where a.status='confirmed' and a.starts_at>now() and a.starts_at<=now()+interval '24 hours' on conflict(dedupe_key) do nothing;
end $$;


-- Explicit collaborator grants. Existing rows retain only basic data/plans.
alter table public.vehicle_share_invites add column scopes text[] not null default '{}',add column access_expires_at timestamptz,
 add constraint share_scopes_valid check(scopes <@ array['maintenance_history','service_history','attachments']::text[]);
create table public.vehicle_share_attachments(invite_id uuid not null references public.vehicle_share_invites(id) on delete cascade,attachment_id uuid not null references public.request_attachments(id) on delete cascade,primary key(invite_id,attachment_id));
create table public.vehicle_share_events(id uuid primary key default gen_random_uuid(),invite_id uuid not null references public.vehicle_share_invites(id),actor_id uuid references public.profiles(id),event text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
alter table public.vehicle_share_attachments enable row level security;
alter table public.vehicle_share_events enable row level security;
grant select on public.vehicle_share_attachments,public.vehicle_share_events to authenticated;
create policy share_files_manager on public.vehicle_share_attachments for select to authenticated using(exists(select 1 from public.vehicle_share_invites i where i.id=invite_id and public.can_manage_vehicle(i.vehicle_id)));
create policy share_events_manager on public.vehicle_share_events for select to authenticated using(exists(select 1 from public.vehicle_share_invites i where i.id=invite_id and public.can_manage_vehicle(i.vehicle_id)));
create function public.product_notification_is_current(p_id uuid) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce((select case when n.category='maintenance' then exists(
 select 1 from public.vehicle_maintenance_plans p join public.vehicles v on v.id=p.vehicle_id left join public.vehicle_odometer_readings o on o.id=v.odometer_reading_id
 where p.id=n.resource_id and p.created_by=n.user_id and (v.owner_profile_id=p.created_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=p.created_by))
 and n.dedupe_key='maintenance:'||p.id::text||':'||p.occurrence_id::text||':'||p.revision::text||':'||case when p.due_date<=current_date or o.odometer>=p.due_odometer then 'due' else 'soon' end
 and (p.due_date<=current_date+p.remind_days or o.odometer>=p.due_odometer-p.remind_km))
 when n.category='appointments' then exists(select 1 from public.service_appointments a where a.id=n.resource_id and n.user_id in(a.requester_id,a.provider_id)
 and (n.dedupe_key not like 'appointment-reminder:%' or (a.status='confirmed' and a.starts_at>now())))
 else exists(select 1 from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id join auth.users u on u.id=n.user_id
 where i.id=n.resource_id and i.status='pending' and i.expires_at>now() and (i.access_expires_at is null or i.access_expires_at>now()) and lower(u.email)=i.recipient_email
 and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))) end from public.product_notifications n where n.id=p_id),false);
$$;
create function public.can_read_vehicle_share(p_vehicle_id uuid,p_scope text default null) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id where i.vehicle_id=p_vehicle_id and i.accepted_by=auth.uid() and i.status='accepted'
 and (i.access_expires_at is null or i.access_expires_at>now()) and (p_scope is null or p_scope=any(i.scopes))
 and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by)));
$$;
create or replace function public.list_shared_vehicles() returns table(id uuid,plate text,model text,year integer) language sql stable security definer set search_path=public as $$
 select v.id,v.plate::text,v.model::text,v.year::integer from public.vehicles v where public.can_read_vehicle_share(v.id);
$$;
create function public.audit_vehicle_share() returns trigger language plpgsql security definer set search_path=public as $$ begin
 insert into public.vehicle_share_events(invite_id,actor_id,event,details) values(new.id,auth.uid(),case when tg_op='INSERT' then 'created' when new.status='expired' then 'expired' when new.status='revoked' then 'revoked' else 'updated' end,jsonb_build_object('status',new.status,'scopes',new.scopes,'access_expires_at',new.access_expires_at));
 if new.status='pending' then
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 select id,'sharing','Convite para consultar veículo','Revise as permissões antes de aceitar.',new.id,'share:'||new.id::text from auth.users where lower(email)=new.recipient_email on conflict(dedupe_key) do nothing;
 end if; return new;
end $$;
create trigger vehicle_share_audit after insert or update on public.vehicle_share_invites for each row execute function public.audit_vehicle_share();
create function public.configure_vehicle_share(p_id uuid,p_scopes text[],p_access_expires_at timestamptz,p_attachments uuid[] default '{}')
returns void language plpgsql security definer set search_path=public as $$ declare i public.vehicle_share_invites; begin
 select * into i from public.vehicle_share_invites where id=p_id for update;
 if not found or not public.can_manage_vehicle(i.vehicle_id) or i.status not in('pending','accepted') then raise exception 'Convite indisponível.' using errcode='42501'; end if;
 if p_scopes is null or not(p_scopes <@ array['maintenance_history','service_history','attachments']::text[]) or p_access_expires_at<=now() then raise exception 'Permissões ou validade inválidas.'; end if;
 if coalesce(cardinality(p_attachments),0)>100 or (cardinality(p_attachments)>0 and not('attachments'=any(p_scopes))) then raise exception 'Revise os anexos permitidos.'; end if;
 if exists(select 1 from unnest(p_attachments) x where not exists(select 1 from public.request_attachments a join public.service_requests r on r.id=a.request_id
 where a.id=x and r.vehicle_id=i.vehicle_id and r.status='completed' and a.kind='image')) then raise exception 'Selecione somente fotos técnicas de atendimentos concluídos.'; end if;
 update public.vehicle_share_invites set scopes=p_scopes,access_expires_at=p_access_expires_at where id=p_id;
 delete from public.vehicle_share_attachments where invite_id=p_id;
 insert into public.vehicle_share_attachments select p_id,x from (select distinct unnest(p_attachments) x) a;
end $$;
create function public.create_vehicle_share_invite_v2(p_vehicle_id uuid,p_email text,p_scopes text[],p_access_expires_at timestamptz,p_attachments uuid[] default '{}')
returns uuid language plpgsql security definer set search_path=public as $$ declare result uuid; begin
 result=public.create_vehicle_share_invite(p_vehicle_id,p_email);
 perform public.configure_vehicle_share(result,p_scopes,p_access_expires_at,p_attachments); return result;
end $$;
create function public.get_vehicle_share_invite(p_id uuid) returns table(id uuid,vehicle_id uuid,model text,plate text,status text,scopes text[],expires_at timestamptz,access_expires_at timestamptz)
language sql stable security definer set search_path=public as $$
 select i.id,i.vehicle_id,v.model::text,v.plate::text,i.status,i.scopes,i.expires_at,i.access_expires_at from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id
 where i.id=p_id and (public.can_manage_vehicle(v.id) or exists(select 1 from auth.users u where u.id=auth.uid() and lower(u.email)=i.recipient_email and u.email_confirmed_at is not null));
$$;
create function public.get_shared_vehicle_details(p_vehicle_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$ declare result jsonb; begin
 if not public.can_read_vehicle_share(p_vehicle_id) then raise exception 'Acesso indisponível, expirado ou revogado.' using errcode='42501'; end if;
 select jsonb_build_object('vehicle',jsonb_build_object('id',v.id,'model',v.model,'plate',v.plate,'year',v.year),
 'scopes',(select coalesce(jsonb_agg(s),'[]') from (select distinct unnest(i.scopes) s from public.vehicle_share_invites i where i.vehicle_id=v.id and i.accepted_by=auth.uid() and i.status='accepted' and (i.access_expires_at is null or i.access_expires_at>now()) and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))) x)) into result from public.vehicles v where v.id=p_vehicle_id;
 return result;
end $$;
create function public.list_shared_vehicle_history(p_vehicle_id uuid,p_kind text,p_offset integer default 0)
returns table(id uuid,title text,completed_at timestamptz,odometer integer) language plpgsql stable security definer set search_path=public as $$ begin
 if p_kind is null or p_kind not in('maintenance_history','service_history') or not public.can_read_vehicle_share(p_vehicle_id,p_kind) then raise exception 'Histórico não autorizado.' using errcode='42501'; end if;
 if p_kind='maintenance_history' then return query select r.id,coalesce(r.title_snapshot,'Manutenção (registro anterior)'),r.completed_at,r.odometer from public.vehicle_maintenance_records r join public.vehicle_maintenance_plans p on p.id=r.plan_id where p.vehicle_id=p_vehicle_id order by r.completed_at desc,r.id desc limit 20 offset greatest(coalesce(p_offset,0),0);
 else return query select r.id,r.problem_type::text,r.closed_at,null::integer from public.service_requests r where r.vehicle_id=p_vehicle_id and r.status='completed' order by r.closed_at desc,r.id desc limit 20 offset greatest(coalesce(p_offset,0),0); end if;
end $$;
create function public.list_shareable_attachments(p_vehicle_id uuid) returns table(id uuid,created_at timestamptz) language plpgsql stable security definer set search_path=public as $$ begin
 if not public.can_manage_vehicle(p_vehicle_id) then raise exception 'Veículo indisponível.' using errcode='42501'; end if;
 return query select a.id,a.created_at from public.request_attachments a join public.service_requests r on r.id=a.request_id where r.vehicle_id=p_vehicle_id and r.status='completed' and a.kind='image' order by a.created_at desc limit 100;
end $$;
create function public.authorize_shared_attachment(p_attachment_id uuid) returns text language sql stable security definer set search_path=public as $$
 select a.storage_path from public.request_attachments a join public.service_requests r on r.id=a.request_id where a.id=p_attachment_id and a.kind='image' and r.status='completed' and (public.can_manage_vehicle(r.vehicle_id) or exists(
 select 1 from public.vehicle_share_attachments g join public.vehicle_share_invites i on i.id=g.invite_id join public.vehicles v on v.id=i.vehicle_id
 where g.attachment_id=a.id and i.vehicle_id=r.vehicle_id and i.accepted_by=auth.uid() and i.status='accepted' and 'attachments'=any(i.scopes)
 and (i.access_expires_at is null or i.access_expires_at>now()) and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))));
$$;
create function public.list_shared_attachments(p_vehicle_id uuid,p_offset integer default 0) returns table(id uuid,created_at timestamptz) language sql stable security definer set search_path=public as $$
 select a.id,a.created_at from public.request_attachments a join public.service_requests r on r.id=a.request_id where r.vehicle_id=p_vehicle_id and public.authorize_shared_attachment(a.id) is not null order by a.created_at desc,a.id desc limit 20 offset greatest(coalesce(p_offset,0),0);
$$;

-- Explicit grants only; helpers never grant raw-table or financial access.

create or replace function public.get_nearby_service_requests(
  p_limit integer default 30,
  p_offset integer default 0,
  p_max_age_minutes integer default 120
)
returns table (
  id uuid,
  problem_type public.request_problem_type,
  description text,
  latitude double precision,
  longitude double precision,
  address_label text,
  vehicle_model text,
  vehicle_plate text,
  distance_meters integer
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  current_provider_id uuid := auth.uid();
  provider_location extensions.geography;
  provider_location_updated_at timestamptz;
  provider_radius_meters integer;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 30 then
    raise exception 'O limite deve estar entre 1 e 30.' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 or p_offset > 500 then
    raise exception 'A paginação solicitada é inválida.' using errcode = '22023';
  end if;
  if p_max_age_minutes is null or p_max_age_minutes < 5 or p_max_age_minutes > 1440 then
    raise exception 'A validade do chamado deve estar entre 5 e 1440 minutos.' using errcode = '22023';
  end if;

  select location_row.location, location_row.updated_at, provider.service_radius_km * 1000
    into provider_location, provider_location_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations location_row on location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id and provider.is_available;
  if provider_location is null then
    raise exception 'Atualize sua localização e disponibilidade para receber chamados.' using errcode = 'P0001';
  end if;
  if provider_location_updated_at < timezone('utc', now()) - interval '15 minutes' then
    raise exception 'Atualize sua localização para buscar chamados próximos.' using errcode = 'P0001';
  end if;

  return query
  select request.id, request.problem_type, request.description, request.latitude,
    request.longitude, request.address_label, vehicle.model, vehicle.plate,
    round(extensions.st_distance(request.location, provider_location))::integer
  from public.service_requests request
  join public.vehicles vehicle on vehicle.id = request.vehicle_id
  where (request.scheduled_provider_id is null or request.scheduled_provider_id = current_provider_id)
    and request.status in ('open', 'collecting_offers')
    and request.opened_at >= timezone('utc', now()) - make_interval(mins => p_max_age_minutes)
    and extensions.st_dwithin(request.location, provider_location, provider_radius_meters)
    and exists (
      select 1 from public.provider_services service
      where service.provider_id = current_provider_id and service.problem_type = request.problem_type
    )
    and not exists (
      select 1 from public.provider_offers offer
      where offer.request_id = request.id and offer.provider_id = current_provider_id
    )
  order by extensions.st_distance(request.location, provider_location), request.opened_at asc, request.id
  limit p_limit offset p_offset;
end;
$$;
create or replace function public.mark_service_request_view(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_provider_id uuid := auth.uid();
  provider_location extensions.geography;
  provider_location_updated_at timestamptz;
  provider_radius_meters integer;
  request_location extensions.geography;
  request_problem public.request_problem_type;
  request_status public.service_request_status;
  request_phase public.service_workflow_phase;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  select provider_location_row.location, provider_location_row.updated_at,
    provider.service_radius_km * 1000
  into provider_location, provider_location_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations provider_location_row
    on provider_location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id and provider.is_available;

  if provider_location is null
    or provider_location_updated_at < timezone('utc', now()) - interval '15 minutes' then
    raise exception 'Atualize sua localização e disponibilidade para visualizar chamados.' using errcode = 'P0001';
  end if;

  select request.location, request.problem_type, request.status, request.workflow_phase
  into request_location, request_problem, request_status, request_phase
  from public.service_requests request
  where request.id = p_request_id;

  if exists(select 1 from public.service_requests where id=p_request_id and scheduled_provider_id is not null and scheduled_provider_id<>current_provider_id) then raise exception 'Chamado reservado.' using errcode='42501'; end if;
  if request_location is null
    or request_status not in ('open', 'collecting_offers')
    or request_phase <> 'open'
    or not exists (
      select 1 from public.provider_services service
      where service.provider_id = current_provider_id and service.problem_type = request_problem
    )
    or not extensions.st_dwithin(request_location, provider_location, provider_radius_meters) then
    raise exception 'Este chamado não está disponível para visualização.' using errcode = '42501';
  end if;

  insert into public.service_request_provider_views (request_id, provider_id, last_viewed_at)
  values (p_request_id, current_provider_id, timezone('utc', now()))
  on conflict (request_id, provider_id)
  do update set last_viewed_at = excluded.last_viewed_at;
end;
$$;
create or replace function public.respond_service_appointment(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare appointment public.service_appointments; recipient uuid;
begin
  select * into appointment from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is null or auth.uid() not in (appointment.requester_id, appointment.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if p_status is null or p_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Ação inválida.'; end if;
  if p_status = appointment.status then return; end if;
  if appointment.service_request_id is not null then raise exception 'Acompanhe e encerre pelo atendimento vinculado.'; end if;
  if appointment.status not in ('requested','confirmed') then raise exception 'Agendamento encerrado.'; end if;
  if p_status in ('confirmed','rejected') and (auth.uid() <> appointment.provider_id or appointment.status <> 'requested') then
    raise exception 'Somente o prestador pode responder à solicitação.' using errcode = '42501'; end if;
  if p_status = 'confirmed' and appointment.starts_at <= now() then raise exception 'O horário já passou.'; end if;
  if p_status = 'completed' and (auth.uid() <> appointment.requester_id or appointment.status <> 'confirmed' or appointment.starts_at > now()) then
    raise exception 'Conclusão indisponível.'; end if;
  update public.service_appointments set status = p_status, updated_at = now() where id = p_id;
  recipient := case when auth.uid() = appointment.requester_id then appointment.provider_id else appointment.requester_id end;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(recipient, 'appointments', 'Agendamento atualizado', 'Consulte o novo status do seu agendamento.', p_id, p_id::text || ':' || p_status)
    on conflict (dedupe_key) do nothing;
end $$;

create or replace function public.respond_vehicle_share_invite(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare invite public.vehicle_share_invites; email text;
begin
  select lower(u.email) into email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  select * into invite from public.vehicle_share_invites where id = p_id for update;
  if not found or email is null or email <> invite.recipient_email then
    raise exception 'Convite indisponível para esta conta.' using errcode = '42501'; end if;
  if invite.access_expires_at<=now() then raise exception 'Acesso expirado.'; end if;
  if invite.status <> 'pending' or invite.expires_at <= now() or p_accept is null then
    raise exception 'Convite encerrado ou expirado.'; end if;
  if not public.can_manage_vehicle(invite.vehicle_id) and not exists (
    select 1 from public.vehicles v where v.id = invite.vehicle_id and
      (v.owner_profile_id = invite.invited_by or exists (select 1 from public.organizations o
       where o.id = v.organization_id and o.owner_id = invite.invited_by))) then
    raise exception 'O responsável não administra mais este veículo.'; end if;
  update public.vehicle_share_invites set status = case when p_accept then 'accepted' else 'rejected' end,
    accepted_by = case when p_accept then auth.uid() else null end,
    accepted_at = case when p_accept then now() else null end where id = p_id;
end $$;

create or replace function public.claim_product_notifications()
returns setof public.product_notifications
language sql security definer set search_path = public as $$
  update public.product_notifications n set push_attempts = n.push_attempts + 1,
    push_lease_until = now() + interval '10 minutes', push_claim = gen_random_uuid()
  where n.id in (select id from public.product_notifications
    where push_sent_at is null and push_attempts < 6
      and (push_lease_until is null or push_lease_until < now())
    order by created_at limit 25 for update skip locked)
  returning n.*;
$$;
revoke all on function public.guard_vehicle_odometer() from public;
revoke all on function public.record_vehicle_odometer(uuid,integer,uuid,uuid,text) from public;
grant execute on function public.record_vehicle_odometer(uuid,integer,uuid,uuid,text) to authenticated;
revoke all on function public.maintenance_revision() from public;
revoke all on function public.complete_vehicle_maintenance_v2(uuid,uuid,integer,integer,uuid,uuid) from public;
grant execute on function public.complete_vehicle_maintenance_v2(uuid,uuid,integer,integer,uuid,uuid) to authenticated;
revoke all on function public.create_service_appointment_v2(uuid,uuid,timestamptz,integer,text,uuid) from public;
grant execute on function public.create_service_appointment_v2(uuid,uuid,timestamptz,integer,text,uuid) to authenticated;
revoke all on function public.convert_service_appointment(uuid,public.request_problem_type,text,double precision,double precision,text) from public;
grant execute on function public.convert_service_appointment(uuid,public.request_problem_type,text,double precision,double precision,text) to authenticated;
revoke all on function public.guard_scheduled_dispatch() from public;
revoke all on function public.guard_scheduled_offer() from public;
revoke all on function public.scheduled_request_cancel() from public;
revoke all on function public.sync_service_appointment() from public;
revoke all on function public.list_maintenance_history(uuid,integer) from public;
grant execute on function public.list_maintenance_history(uuid,integer) to authenticated;
revoke all on function public.product_notification_is_current(uuid) from public;
grant execute on function public.product_notification_is_current(uuid) to service_role;
revoke all on function public.can_read_vehicle_share(uuid,text) from public;
grant execute on function public.can_read_vehicle_share(uuid,text) to authenticated;
revoke all on function public.audit_vehicle_share() from public;
revoke all on function public.configure_vehicle_share(uuid,text[],timestamptz,uuid[]) from public;
grant execute on function public.configure_vehicle_share(uuid,text[],timestamptz,uuid[]) to authenticated;
revoke all on function public.create_vehicle_share_invite_v2(uuid,text,text[],timestamptz,uuid[]) from public;
grant execute on function public.create_vehicle_share_invite_v2(uuid,text,text[],timestamptz,uuid[]) to authenticated;
revoke all on function public.get_vehicle_share_invite(uuid) from public;
grant execute on function public.get_vehicle_share_invite(uuid) to authenticated;
revoke all on function public.get_shared_vehicle_details(uuid) from public;
grant execute on function public.get_shared_vehicle_details(uuid) to authenticated;
revoke all on function public.list_shared_vehicle_history(uuid,text,integer) from public;
grant execute on function public.list_shared_vehicle_history(uuid,text,integer) to authenticated;
revoke all on function public.list_shareable_attachments(uuid) from public;
grant execute on function public.list_shareable_attachments(uuid) to authenticated;
revoke all on function public.authorize_shared_attachment(uuid) from public;
grant execute on function public.authorize_shared_attachment(uuid) to authenticated;
revoke all on function public.list_shared_attachments(uuid,integer) from public;
grant execute on function public.list_shared_attachments(uuid,integer) to authenticated;
revoke all on function public.create_vehicle_share_invite(uuid,text) from public;
grant execute on function public.create_vehicle_share_invite(uuid,text) to authenticated;
revoke all on function public.revoke_vehicle_share_invite(uuid) from public;
grant execute on function public.revoke_vehicle_share_invite(uuid) to authenticated;
revoke all on function public.revoke_vehicle_share_invite(uuid) from public;
grant execute on function public.revoke_vehicle_share_invite(uuid) to authenticated;

create function public.end_declined_scheduled_offer() returns trigger language plpgsql security definer set search_path=public as $$ begin
 if new.status in ('rejected','withdrawn') then
 update public.service_requests set status='cancelled',workflow_phase='cancelled',closed_at=now()
 where id=new.request_id and scheduled_provider_id=new.provider_id and selected_provider_id is null and workflow_phase='open';
 end if; return new;
end $$;
create trigger declined_scheduled_offer after update of status on public.provider_offers for each row execute function public.end_declined_scheduled_offer();
create or replace function public.dismiss_service_request_dispatch(p_dispatch_id uuid) returns void language plpgsql security definer set search_path=public as $$ declare rid uuid; begin
 update public.service_request_dispatches set status='dismissed',dismissed_at=now() where id=p_dispatch_id and provider_id=auth.uid() and status in ('pending','seen') returning request_id into rid;
 if rid is null then raise exception 'Dispatch indisponível.' using errcode='42501'; end if;
 update public.service_requests set status='cancelled',workflow_phase='cancelled',closed_at=now() where id=rid and scheduled_provider_id=auth.uid() and workflow_phase='open';
end $$;
revoke all on function public.end_declined_scheduled_offer() from public;

create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid,requester_id uuid,provider_id uuid,vehicle_id uuid,starts_at timestamptz,ends_at timestamptz,description text,status text,service_request_id uuid,maintenance_plan_id uuid,vehicle_label text,provider_name text)
language sql stable security definer set search_path=public as $$
 select a.id,a.requester_id,a.provider_id,a.vehicle_id,a.starts_at,a.ends_at,a.description,a.status,a.service_request_id,a.maintenance_plan_id,v.model||' · '||v.plate,p.business_name
 from public.service_appointments a join public.vehicles v on v.id=a.vehicle_id join public.provider_profiles p on p.provider_id=a.provider_id where a.id=p_id and auth.uid() in (a.requester_id,a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(uuid) from public;
grant execute on function public.get_service_appointment_detail(uuid) to authenticated;

create function public.list_vehicle_share_selection(p_id uuid) returns table(attachment_id uuid) language plpgsql stable security definer set search_path=public as $$ begin
 if not exists(select 1 from public.vehicle_share_invites where id=p_id and public.can_manage_vehicle(vehicle_id)) then raise exception 'Convite indisponível.' using errcode='42501'; end if;
 return query select g.attachment_id from public.vehicle_share_attachments g where g.invite_id=p_id;
end $$;
revoke all on function public.list_vehicle_share_selection(uuid) from public;
grant execute on function public.list_vehicle_share_selection(uuid) to authenticated;
create or replace function public.create_service_appointment(p_vehicle_id uuid, p_provider_id uuid,
  p_starts_at timestamptz, p_duration_minutes integer, p_description text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; finish timestamptz;
begin
  if auth.uid() is null or not public.can_manage_vehicle(p_vehicle_id)
    or not exists (select 1 from public.profiles where id = auth.uid() and role = 'driver') then
    raise exception 'Veículo indisponível ou sem permissão.' using errcode = '42501';
  end if;
  if p_starts_at is null or p_starts_at <= now() or p_duration_minutes is null
    or p_duration_minutes not between 15 and 480 then raise exception 'Data ou duração inválida.'; end if;
  if not exists (select 1 from public.provider_profiles where provider_id = p_provider_id and is_available) then
    raise exception 'Prestador indisponível.'; end if;
  finish := p_starts_at + make_interval(mins => p_duration_minutes);
  perform 1 from public.vehicles where id=p_vehicle_id for update;
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if exists (select 1 from public.service_appointments where (provider_id = p_provider_id or vehicle_id = p_vehicle_id)
    and status in ('requested','confirmed','in_service') and starts_at < finish and ends_at > p_starts_at) then
    raise exception 'Horário indisponível. Escolha outro horário.';
  end if;
  insert into public.service_appointments(requester_id, provider_id, vehicle_id, starts_at, ends_at, description)
    values(auth.uid(), p_provider_id, p_vehicle_id, p_starts_at, finish, btrim(p_description)) returning id into new_id;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(p_provider_id, 'appointments', 'Novo agendamento', 'Você recebeu uma solicitação de horário.', new_id, new_id::text || ':requested');
  return new_id;
end $$;


create function public.guard_scheduled_active_request() returns trigger language plpgsql security definer set search_path=public as $$ begin
 perform 1 from public.vehicles where id=new.vehicle_id for update;
 if exists(select 1 from public.service_requests r where r.vehicle_id=new.vehicle_id and r.status not in ('completed','cancelled')
 and (new.scheduled_provider_id is not null or r.scheduled_provider_id is not null)) then raise exception 'Veículo com atendimento agendado em aberto.'; end if;
 return new;
end $$;
create trigger scheduled_active_request before insert on public.service_requests for each row execute function public.guard_scheduled_active_request();
revoke all on function public.guard_scheduled_active_request() from public;
revoke all on public.product_notifications from anon,authenticated;
grant select,update(read_at) on public.product_notifications to authenticated;

alter table public.vehicle_share_invites drop constraint vehicle_share_invites_status_check;
alter table public.vehicle_share_invites add constraint vehicle_share_invites_status_check check(status in ('pending','accepted','rejected','revoked','expired'));
create index share_access_expiration on public.vehicle_share_invites(access_expires_at) where status='accepted';
create index share_invite_expiration on public.vehicle_share_invites(expires_at) where status='pending';
create function public.expire_vehicle_share_accesses() returns void language plpgsql security definer set search_path=public as $$ begin
 update public.vehicle_share_invites set status='expired' where (status='pending' and expires_at<=now()) or (status in ('pending','accepted') and access_expires_at<=now());
end $$;
revoke all on function public.expire_vehicle_share_accesses() from public;
grant execute on function public.expire_vehicle_share_accesses() to service_role;
commit;
