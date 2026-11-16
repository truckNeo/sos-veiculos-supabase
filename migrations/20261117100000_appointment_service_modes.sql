-- Agendamento com dois tipos de atendimento:
--   workshop: o motorista leva o veículo à oficina; sem chamado e sem pagamento
--             pelo app. O prestador inicia e finaliza.
--   onsite:   o mecânico vai até o motorista; o local é informado ao agendar e,
--             quando o prestador inicia, vira um chamado (proposta com taxa de
--             deslocamento, pagamento e deslocamento pelo fluxo existente).
-- Também: atraso do motorista (alerta em 60 min, encerramento em 90 min) e
-- conclusão automática do plano de manutenção vinculado.

alter table public.service_appointments drop constraint service_appointments_status_check;
alter table public.service_appointments add constraint service_appointments_status_check
  check (status in ('requested','confirmed','in_service','rejected','cancelled','completed','expired','no_show'));

alter table public.service_appointments
  add column service_mode text not null default 'workshop' check (service_mode in ('workshop','onsite')),
  add column location_latitude double precision,
  add column location_longitude double precision,
  add column location_label text,
  add column started_at timestamptz,
  add column finished_at timestamptz,
  add column cancel_reason text,
  add constraint appointment_onsite_location check (service_mode = 'workshop' or (
    location_latitude between -90 and 90 and location_longitude between -180 and 180
    and length(trim(coalesce(location_label, ''))) between 3 and 500));

create index appointments_late_idx on public.service_appointments(starts_at)
  where status = 'confirmed' and started_at is null;

-- Nova assinatura: modo e local. Os parâmetros novos têm default, então as
-- chamadas antigas (6 argumentos) continuam válidas.
drop function public.create_service_appointment_v2(uuid, uuid, timestamptz, integer, text, uuid);
create function public.create_service_appointment_v2(p_vehicle_id uuid, p_provider_id uuid, p_starts_at timestamptz,
  p_duration_minutes integer, p_description text, p_plan_id uuid default null,
  p_service_mode text default 'workshop', p_latitude double precision default null,
  p_longitude double precision default null, p_address_label text default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare result uuid;
begin
  if not exists(select 1 from public.favorite_mechanic_invites where driver_id = auth.uid() and provider_id = p_provider_id and status = 'accepted') then
    raise exception 'Você só pode agendar com mecânicos favoritos que aceitaram seu convite.' using errcode = 'P0001';
  end if;
  if p_service_mode is null or p_service_mode not in ('workshop','onsite') then
    raise exception 'Escolha se vai levar o veículo ou se o mecânico vai até você.' using errcode = 'P0001';
  end if;
  if p_service_mode = 'onsite' then
    if p_latitude is null or not (p_latitude between -90 and 90) or p_longitude is null or not (p_longitude between -180 and 180)
      or length(trim(coalesce(p_address_label, ''))) not between 3 and 500 then
      raise exception 'Informe o local onde o mecânico deve ir.' using errcode = 'P0001';
    end if;
    if not exists(select 1 from public.provider_profiles p join public.provider_locations l on l.provider_id = p.provider_id
      where p.provider_id = p_provider_id
        and extensions.st_dwithin(extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography,
          l.location, p.service_radius_km * 1000)) then
      raise exception 'O local informado está fora da área de atendimento do prestador.' using errcode = 'P0001';
    end if;
  end if;
  if p_plan_id is not null and not exists(select 1 from public.vehicle_maintenance_plans where id = p_plan_id and vehicle_id = p_vehicle_id and public.can_manage_vehicle(vehicle_id)) then
    raise exception 'Plano indisponível.' using errcode = '42501';
  end if;
  result = public.create_service_appointment(p_vehicle_id, p_provider_id, p_starts_at, p_duration_minutes, p_description);
  update public.service_appointments set maintenance_plan_id = p_plan_id, service_mode = p_service_mode,
    location_latitude = case when p_service_mode = 'onsite' then p_latitude end,
    location_longitude = case when p_service_mode = 'onsite' then p_longitude end,
    location_label = case when p_service_mode = 'onsite' then trim(p_address_label) end,
    vehicle_odometer = (select r.odometer from public.vehicles v join public.vehicle_odometer_readings r on r.id = v.odometer_reading_id where v.id = p_vehicle_id)
  where id = result;
  return result;
end $$;
revoke all on function public.create_service_appointment_v2(uuid, uuid, timestamptz, integer, text, uuid, text, double precision, double precision, text) from public;
grant execute on function public.create_service_appointment_v2(uuid, uuid, timestamptz, integer, text, uuid, text, double precision, double precision, text) to authenticated;

-- Conclui o plano de manutenção ligado ao agendamento, sem o motorista precisar
-- confirmar. Sem quilometragem conhecida (plano por km) avisa o motorista.
create function public.auto_complete_appointment_plan(p_appointment_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; p public.vehicle_maintenance_plans; odo integer;
begin
  select * into a from public.service_appointments where id = p_appointment_id;
  if not found or a.maintenance_plan_id is null then return; end if;
  perform 1 from public.vehicles where id = a.vehicle_id for update;
  select * into p from public.vehicle_maintenance_plans where id = a.maintenance_plan_id and vehicle_id = a.vehicle_id for update;
  if not found then return; end if;
  if exists(select 1 from public.vehicle_maintenance_records where plan_id = p.id and occurrence_id = p.occurrence_id) then return; end if;
  select r.odometer into odo from public.vehicles v join public.vehicle_odometer_readings r on r.id = v.odometer_reading_id where v.id = a.vehicle_id;
  odo := coalesce(odo, a.vehicle_odometer);
  if p.interval_km is not null and odo is null then
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(a.requester_id, 'appointments', 'Confirme a manutenção', 'Informe a quilometragem para registrar a manutenção no plano.', a.id, 'plan-needs-odometer:' || a.id::text)
    on conflict(dedupe_key) do nothing;
    return;
  end if;
  insert into public.vehicle_maintenance_records(plan_id, completed_by, odometer, previous_due_date, occurrence_id, title_snapshot,
    interval_days_snapshot, interval_km_snapshot, previous_due_odometer, service_request_id)
  values(p.id, a.requester_id, odo, p.due_date, p.occurrence_id, p.title, p.interval_days, p.interval_km, p.due_odometer, a.service_request_id);
  update public.vehicle_maintenance_plans set due_date = current_date + p.interval_days,
    due_odometer = case when p.interval_km is not null then odo + p.interval_km else null end,
    occurrence_id = gen_random_uuid() where id = p.id;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  values(a.requester_id, 'appointments', 'Manutenção registrada', 'O plano "' || p.title || '" foi atualizado após o atendimento.', a.id, 'plan-done:' || a.id::text)
  on conflict(dedupe_key) do nothing;
end $$;
revoke all on function public.auto_complete_appointment_plan(uuid) from public;

-- Chamado concluído (no local): fecha o agendamento e o plano vinculado.
create or replace function public.sync_service_appointment() returns trigger language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; state text;
begin
  state = case when new.status = 'completed' then 'completed' when new.status = 'cancelled' then 'cancelled' else 'in_service' end;
  update public.service_appointments set status = state, finished_at = case when state = 'completed' then now() else finished_at end, updated_at = now()
    where service_request_id = new.id and status <> state returning * into a;
  if found then
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    select u, 'appointments', 'Atendimento atualizado', 'Consulte o resultado do atendimento agendado.', a.id, a.id::text || ':' || state || ':' || u::text
    from unnest(array[a.requester_id, a.provider_id]) u on conflict(dedupe_key) do nothing;
    if state = 'completed' then perform public.auto_complete_appointment_plan(a.id); end if;
  end if;
  return new;
end $$;

-- O fluxo antigo (motorista inicia e informa o local) deixa de existir.
revoke all on function public.convert_service_appointment(uuid, public.request_problem_type, text, double precision, double precision, text) from public, anon, authenticated;

-- O prestador inicia o atendimento. Oficina: só muda o status. No local: cria o
-- chamado com o local do agendamento, destinado a este prestador.
create function public.start_service_appointment(p_id uuid, p_problem_type public.request_problem_type default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare a public.service_appointments; request_id uuid; descr text;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.status = 'in_service' then return a.service_request_id; end if;
  if a.status <> 'confirmed' then raise exception 'Só é possível iniciar um agendamento confirmado.' using errcode = 'P0001'; end if;
  if now() < a.starts_at - interval '30 minutes' then
    raise exception 'O atendimento só pode ser iniciado a partir de 30 minutos antes do horário.' using errcode = 'P0001';
  end if;
  if a.service_mode = 'workshop' then
    update public.service_appointments set status = 'in_service', started_at = now(), updated_at = now() where id = a.id;
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(a.requester_id, 'appointments', 'Atendimento iniciado', 'O prestador iniciou o atendimento do seu veículo.', a.id, a.id::text || ':started')
    on conflict(dedupe_key) do nothing;
    return null;
  end if;
  if p_problem_type is null then raise exception 'Escolha a categoria do atendimento.' using errcode = 'P0001'; end if;
  perform 1 from public.vehicles where id = a.vehicle_id and status = 'active' for update;
  if not found then raise exception 'Veículo inativo.' using errcode = 'P0001'; end if;
  if exists(select 1 from public.service_requests where vehicle_id = a.vehicle_id and status not in ('completed','cancelled')) then
    raise exception 'O veículo já possui chamado em aberto.' using errcode = 'P0001';
  end if;
  if not exists(select 1 from public.provider_profiles p join public.provider_locations l on l.provider_id = p.provider_id
      where p.provider_id = a.provider_id and p.is_available and l.updated_at >= now() - interval '15 minutes'
        and extensions.st_dwithin(extensions.st_setsrid(extensions.st_makepoint(a.location_longitude, a.location_latitude), 4326)::extensions.geography,
          l.location, p.service_radius_km * 1000))
    or not exists(select 1 from public.provider_services where provider_id = a.provider_id and problem_type = p_problem_type)
    or not exists(select 1 from public.provider_vehicles where provider_id = a.provider_id and is_active) then
    raise exception 'Atualize sua disponibilidade e localização, e confira especialidade e veículo operacional, para iniciar o atendimento.' using errcode = 'P0001';
  end if;
  descr := case when length(trim(a.description)) >= 5 then trim(a.description) else trim(a.description) || ' (serviço agendado)' end;
  insert into public.service_requests(requester_id, vehicle_id, problem_type, description, latitude, longitude, address_label, scheduled_provider_id)
  values(a.requester_id, a.vehicle_id, p_problem_type, descr, a.location_latitude, a.location_longitude, a.location_label, a.provider_id)
  returning id into request_id;
  update public.service_appointments set service_request_id = request_id, status = 'in_service', started_at = now(), updated_at = now() where id = a.id;
  insert into public.service_request_events(request_id, actor_id, status, note)
  values(request_id, auth.uid(), 'open', 'Chamado originado de agendamento no local, iniciado pelo prestador.');
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  values(a.requester_id, 'appointments', 'Atendimento iniciado', 'O prestador vai enviar a proposta com a taxa de deslocamento para você aprovar.', a.id, a.id::text || ':started')
  on conflict(dedupe_key) do nothing;
  return request_id;
end $$;
revoke all on function public.start_service_appointment(uuid, public.request_problem_type) from public;
grant execute on function public.start_service_appointment(uuid, public.request_problem_type) to authenticated;

-- O prestador finaliza o atendimento na oficina (sem pagamento pelo app).
create function public.finish_service_appointment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.status = 'completed' then return; end if;
  if a.service_request_id is not null then
    raise exception 'Este atendimento é concluído pelo fluxo do chamado.' using errcode = 'P0001';
  end if;
  if a.status <> 'in_service' then raise exception 'Inicie o atendimento antes de finalizar.' using errcode = 'P0001'; end if;
  update public.service_appointments set status = 'completed', finished_at = now(), updated_at = now() where id = a.id;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  values(a.requester_id, 'appointments', 'Atendimento concluído', 'O prestador finalizou o atendimento. Avalie o serviço.', a.id, a.id::text || ':completed')
  on conflict(dedupe_key) do nothing;
  perform public.auto_complete_appointment_plan(a.id);
end $$;
revoke all on function public.finish_service_appointment(uuid) from public;
grant execute on function public.finish_service_appointment(uuid) to authenticated;

-- Atraso do motorista (oficina): alerta aos dois 60 min depois do horário e
-- encerramento como não comparecimento aos 90 min.
create function public.process_late_appointments() returns void
language plpgsql security definer set search_path = public as $$
begin
  with closed as (
    update public.service_appointments set status = 'no_show', cancel_reason = 'no_show', updated_at = now()
    where status = 'confirmed' and service_mode = 'workshop' and started_at is null and service_request_id is null
      and now() >= starts_at + interval '90 minutes'
    returning id, requester_id, provider_id
  )
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  select c.requester_id, 'appointments', 'Agendamento encerrado', 'O agendamento foi encerrado porque o veículo não chegou até 90 minutos após o horário.', c.id, 'appointment-no-show:' || c.id::text || ':' || c.requester_id::text from closed c
  union all
  select c.provider_id, 'appointments', 'Agendamento encerrado', 'O agendamento foi encerrado como não comparecimento do motorista.', c.id, 'appointment-no-show:' || c.id::text || ':' || c.provider_id::text from closed c
  on conflict(dedupe_key) do nothing;

  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
  select a.requester_id, 'appointments', 'Você está atrasado', 'Seu horário passou há 1 hora. Chegue em até 30 minutos ou o agendamento será encerrado.', a.id, 'appointment-late:' || a.id::text || ':' || a.requester_id::text
  from public.service_appointments a
  where a.status = 'confirmed' and a.service_mode = 'workshop' and a.started_at is null and a.service_request_id is null
    and now() >= a.starts_at + interval '60 minutes' and now() < a.starts_at + interval '90 minutes'
  union all
  select a.provider_id, 'appointments', 'Motorista atrasado', 'O motorista ainda não chegou. Entre em contato ou cancele o agendamento. Ele será encerrado em 30 minutos.', a.id, 'appointment-late:' || a.id::text || ':' || a.provider_id::text
  from public.service_appointments a
  where a.status = 'confirmed' and a.service_mode = 'workshop' and a.started_at is null and a.service_request_id is null
    and now() >= a.starts_at + interval '60 minutes' and now() < a.starts_at + interval '90 minutes'
  on conflict(dedupe_key) do nothing;
end $$;
revoke all on function public.process_late_appointments() from public;
grant execute on function public.process_late_appointments() to service_role;


create or replace function public.enqueue_product_reminders() returns void language plpgsql security definer set search_path=public as $$ begin
 perform public.expire_vehicle_share_accesses();
 perform public.expire_stale_appointment_requests();
 perform public.process_late_appointments();
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
 insert into public.product_notifications(user_id,category,title,body,resource_id,dedupe_key)
 select a.provider_id,'appointments','Pedido de agendamento aguardando resposta','Responda antes que o pedido expire.',a.id,'appointment-expiry-reminder:'||a.id::text
 from public.service_appointments a
 where a.status='requested' and now()>=a.created_at+(public.appointment_response_deadline(a.created_at,a.starts_at)-a.created_at)/2
 and now()<public.appointment_response_deadline(a.created_at,a.starts_at) on conflict(dedupe_key) do nothing;
end $$;

create or replace function public.product_notification_is_current(p_id uuid) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce((select case when n.category='maintenance' then exists(
 select 1 from public.vehicle_maintenance_plans p join public.vehicles v on v.id=p.vehicle_id left join public.vehicle_odometer_readings o on o.id=v.odometer_reading_id
 where p.id=n.resource_id and p.created_by=n.user_id and (v.owner_profile_id=p.created_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=p.created_by))
 and n.dedupe_key='maintenance:'||p.id::text||':'||p.occurrence_id::text||':'||p.revision::text||':'||case when p.due_date<=current_date or o.odometer>=p.due_odometer then 'due' else 'soon' end
 and (p.due_date<=current_date+p.remind_days or o.odometer>=p.due_odometer-p.remind_km))
 when n.category='appointments' then exists(select 1 from public.service_appointments a where a.id=n.resource_id and n.user_id in(a.requester_id,a.provider_id)
 and (n.dedupe_key not like 'appointment-reminder:%' or (a.status='confirmed' and a.starts_at>now()))
 and (n.dedupe_key not like 'appointment-expiry-reminder:%' or a.status='requested')
 and (n.dedupe_key not like 'appointment-late:%' or (a.status='confirmed' and a.started_at is null and a.service_request_id is null)))
 else exists(select 1 from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id join auth.users u on u.id=n.user_id
 where i.id=n.resource_id and i.status='pending' and i.expires_at>now() and (i.access_expires_at is null or i.access_expires_at>now()) and lower(u.email)=i.recipient_email
 and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))) end from public.product_notifications n where n.id=p_id),false);
$$;

-- Contato entre as partes de um agendamento ativo (o telefone não é público).
create function public.get_appointment_contact(p_id uuid)
returns table(name text, phone text) language plpgsql stable security definer set search_path = public as $$
declare a public.service_appointments; other uuid;
begin
  select * into a from public.service_appointments where id = p_id;
  if not found or auth.uid() is null or auth.uid() not in (a.requester_id, a.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.status not in ('confirmed','in_service') then
    raise exception 'O contato fica disponível enquanto o agendamento está ativo.' using errcode = 'P0001'; end if;
  other := case when auth.uid() = a.requester_id then a.provider_id else a.requester_id end;
  return query select coalesce(pp.business_name, p.full_name), p.phone from public.profiles p
    left join public.provider_profiles pp on pp.provider_id = p.id where p.id = other;
end $$;
revoke all on function public.get_appointment_contact(uuid) from public;
grant execute on function public.get_appointment_contact(uuid) to authenticated;

drop function public.get_service_appointment_detail(uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz,
  description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text,
  vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid,
  service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text)
language sql stable security definer set search_path = public as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(uuid) from public;
grant execute on function public.get_service_appointment_detail(uuid) to authenticated;
