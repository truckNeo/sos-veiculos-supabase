-- Additive product features. Existing auth, vehicle, offer, chat and review
-- policies/functions are deliberately not replaced. All timestamps use timestamptz.
begin;

create table public.app_notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  maintenance boolean not null default true,
  appointments boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.app_notification_preferences enable row level security;
grant select, insert, update on public.app_notification_preferences to authenticated;
create policy "own notification preferences" on public.app_notification_preferences
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.vehicle_maintenance_plans (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  title text not null check (length(btrim(title)) between 3 and 160),
  due_date date not null,
  interval_days integer not null check (interval_days between 1 and 3650),
  due_odometer integer check (due_odometer >= 0),
  interval_km integer check (interval_km > 0),
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((due_odometer is null) = (interval_km is null))
);
create table public.vehicle_maintenance_records (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.vehicle_maintenance_plans(id),
  completed_by uuid not null references public.profiles(id),
  completed_at timestamptz not null default now(),
  odometer integer check (odometer >= 0),
  previous_due_date date not null,
  unique (plan_id, previous_due_date)
);
alter table public.vehicle_maintenance_plans enable row level security;
alter table public.vehicle_maintenance_records enable row level security;
grant select, insert, update on public.vehicle_maintenance_plans to authenticated;
grant select on public.vehicle_maintenance_records to authenticated;
create policy "managers read maintenance" on public.vehicle_maintenance_plans
  for select to authenticated using (public.can_manage_vehicle(vehicle_id));
create policy "managers create maintenance" on public.vehicle_maintenance_plans
  for insert to authenticated with check (public.can_manage_vehicle(vehicle_id) and created_by = auth.uid());
create policy "managers update maintenance" on public.vehicle_maintenance_plans
  for update to authenticated using (public.can_manage_vehicle(vehicle_id))
  with check (public.can_manage_vehicle(vehicle_id));
create policy "managers read maintenance records" on public.vehicle_maintenance_records
  for select to authenticated using (exists (select 1 from public.vehicle_maintenance_plans p
    where p.id = plan_id and public.can_manage_vehicle(p.vehicle_id)));
create index maintenance_due_idx on public.vehicle_maintenance_plans(due_date);

create table public.service_appointments (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id),
  provider_id uuid not null references public.provider_profiles(provider_id),
  vehicle_id uuid not null references public.vehicles(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  description text not null check (length(btrim(description)) between 3 and 2000),
  status text not null default 'requested' check (status in ('requested','confirmed','rejected','cancelled','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at and ends_at <= starts_at + interval '8 hours')
);
alter table public.service_appointments enable row level security;
grant select on public.service_appointments to authenticated;
create policy "participants read appointments" on public.service_appointments
  for select to authenticated using (requester_id = auth.uid() or provider_id = auth.uid());
create index appointments_provider_time_idx on public.service_appointments(provider_id, starts_at);
create index appointments_requester_idx on public.service_appointments(requester_id, starts_at);

create table public.vehicle_share_invites (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  invited_by uuid not null references public.profiles(id),
  recipient_email text not null check (length(recipient_email) between 3 and 254),
  status text not null default 'pending' check (status in ('pending','accepted','rejected','revoked')),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_by uuid references public.profiles(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.vehicle_share_invites enable row level security;
grant select on public.vehicle_share_invites to authenticated;
create policy "managers read vehicle invites" on public.vehicle_share_invites
  for select to authenticated using (public.can_manage_vehicle(vehicle_id));
create index vehicle_share_recipient_idx on public.vehicle_share_invites(accepted_by, status);
create unique index vehicle_share_active_recipient_idx on public.vehicle_share_invites(vehicle_id, recipient_email)
  where status in ('pending','accepted');

create table public.product_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null check (category in ('maintenance','appointments','sharing')),
  title text not null,
  body text not null,
  resource_id uuid not null,
  dedupe_key text not null unique,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.product_notifications enable row level security;
grant select on public.product_notifications to authenticated;
grant update (read_at) on public.product_notifications to authenticated;
create policy "own app notifications" on public.product_notifications
  for select to authenticated using (user_id = auth.uid());
create policy "mark own app notifications read" on public.product_notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create index product_notifications_user_idx on public.product_notifications(user_id, created_at desc);

create function public.complete_vehicle_maintenance(p_plan_id uuid, p_expected_due_date date, p_odometer integer default null)
returns void language plpgsql security definer set search_path = public as $$
declare plan public.vehicle_maintenance_plans;
begin
  select * into plan from public.vehicle_maintenance_plans where id = p_plan_id for update;
  if not found or not public.can_manage_vehicle(plan.vehicle_id) then
    raise exception 'Plano indisponível ou sem permissão.' using errcode = '42501';
  end if;
  if plan.due_date is distinct from p_expected_due_date then
    raise exception 'Plano já atualizado. Recarregue antes de continuar.';
  end if;
  if plan.interval_km is not null and (p_odometer is null or p_odometer < 0) then
    raise exception 'Informe a quilometragem atual.';
  end if;
  insert into public.vehicle_maintenance_records(plan_id, completed_by, odometer, previous_due_date)
    values (plan.id, auth.uid(), p_odometer, plan.due_date);
  update public.vehicle_maintenance_plans set due_date = current_date + plan.interval_days,
    due_odometer = case when plan.interval_km is not null then p_odometer + plan.interval_km else null end,
    updated_at = now() where id = plan.id;
end $$;

create function public.create_service_appointment(p_vehicle_id uuid, p_provider_id uuid,
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
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if exists (select 1 from public.service_appointments where provider_id = p_provider_id
    and status in ('requested','confirmed') and starts_at < finish and ends_at > p_starts_at) then
    raise exception 'Horário indisponível. Escolha outro horário.';
  end if;
  insert into public.service_appointments(requester_id, provider_id, vehicle_id, starts_at, ends_at, description)
    values(auth.uid(), p_provider_id, p_vehicle_id, p_starts_at, finish, btrim(p_description)) returning id into new_id;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(p_provider_id, 'appointments', 'Novo agendamento', 'Você recebeu uma solicitação de horário.', new_id, new_id::text || ':requested');
  return new_id;
end $$;

create function public.respond_service_appointment(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare appointment public.service_appointments; recipient uuid;
begin
  select * into appointment from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is null or auth.uid() not in (appointment.requester_id, appointment.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if p_status is null or p_status not in ('confirmed','rejected','cancelled','completed') then
    raise exception 'Ação inválida.'; end if;
  if p_status = appointment.status then return; end if;
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

create function public.create_vehicle_share_invite(p_vehicle_id uuid, p_email text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; email text := lower(btrim(p_email));
begin
  if auth.uid() is null or not public.can_manage_vehicle(p_vehicle_id) then
    raise exception 'Veículo indisponível.' using errcode = '42501'; end if;
  if email is null or email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'E-mail inválido.'; end if;
  update public.vehicle_share_invites set status = 'revoked' where vehicle_id = p_vehicle_id
    and recipient_email = email and status = 'pending' and expires_at <= now();
  insert into public.vehicle_share_invites(vehicle_id, invited_by, recipient_email)
    values(p_vehicle_id, auth.uid(), email) returning id into new_id;
  return new_id;
end $$;

create function public.respond_vehicle_share_invite(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare invite public.vehicle_share_invites; email text;
begin
  select lower(u.email) into email from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null;
  select * into invite from public.vehicle_share_invites where id = p_id for update;
  if not found or email is null or email <> invite.recipient_email then
    raise exception 'Convite indisponível para esta conta.' using errcode = '42501'; end if;
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

create function public.revoke_vehicle_share_invite(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.vehicle_share_invites set status = 'revoked'
    where id = p_id and public.can_manage_vehicle(vehicle_id);
  if not found then raise exception 'Convite indisponível.' using errcode = '42501'; end if;
end $$;

-- Narrow projection: never expand can_access_vehicle or expose full rows/history.
create function public.list_shared_vehicles()
returns table(id uuid, plate text, model text, year integer)
language sql stable security definer set search_path = public as $$
  select distinct v.id, v.plate::text, v.model::text, v.year::integer
  from public.vehicles v join public.vehicle_share_invites i on i.vehicle_id = v.id
  where i.accepted_by = auth.uid() and i.status = 'accepted'
    and (v.owner_profile_id = i.invited_by or exists (select 1 from public.organizations o
      where o.id = v.organization_id and o.owner_id = i.invited_by));
$$;

create function public.list_shared_vehicle_maintenance(p_vehicle_id uuid)
returns table(id uuid, title text, due_date date, due_odometer integer)
language sql stable security definer set search_path = public as $$
  select p.id, p.title, p.due_date, p.due_odometer from public.vehicle_maintenance_plans p
  where p.vehicle_id = p_vehicle_id and exists(select 1 from public.list_shared_vehicles() v where v.id = p_vehicle_id);
$$;

-- Call from an authenticated server-side scheduler. Deduplication is per occurrence.
create function public.enqueue_product_reminders()
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    select p.created_by, 'maintenance', 'Manutenção próxima', p.title, p.id,
      'maintenance:' || p.id::text || ':' || p.due_date::text
    from public.vehicle_maintenance_plans p join public.vehicles v on v.id = p.vehicle_id
    where p.due_date <= current_date + 7 and
      (v.owner_profile_id = p.created_by or exists(select 1 from public.organizations o
       where o.id = v.organization_id and o.owner_id = p.created_by))
    on conflict (dedupe_key) do nothing;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    select recipient, 'appointments', 'Agendamento próximo', 'Consulte os detalhes do seu horário.', a.id,
      'appointment-reminder:' || a.id::text || ':' || recipient::text
    from public.service_appointments a cross join lateral unnest(array[a.requester_id,a.provider_id]) recipient
    where a.status = 'confirmed' and a.starts_at > now() and a.starts_at <= now() + interval '24 hours'
    on conflict (dedupe_key) do nothing;
end $$;

revoke all on function public.complete_vehicle_maintenance(uuid,date,integer) from public;
revoke all on function public.create_service_appointment(uuid,uuid,timestamptz,integer,text) from public;
revoke all on function public.respond_service_appointment(uuid,text) from public;
revoke all on function public.create_vehicle_share_invite(uuid,text) from public;
revoke all on function public.respond_vehicle_share_invite(uuid,boolean) from public;
revoke all on function public.revoke_vehicle_share_invite(uuid) from public;
revoke all on function public.list_shared_vehicles() from public;
revoke all on function public.list_shared_vehicle_maintenance(uuid) from public;
revoke all on function public.enqueue_product_reminders() from public;
grant execute on function public.complete_vehicle_maintenance(uuid,date,integer),
  public.create_service_appointment(uuid,uuid,timestamptz,integer,text),
  public.respond_service_appointment(uuid,text), public.create_vehicle_share_invite(uuid,text),
  public.respond_vehicle_share_invite(uuid,boolean), public.revoke_vehicle_share_invite(uuid),
  public.list_shared_vehicles(), public.list_shared_vehicle_maintenance(uuid) to authenticated;
grant execute on function public.enqueue_product_reminders() to service_role;

commit;
