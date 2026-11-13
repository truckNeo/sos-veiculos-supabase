-- Reagendamento: qualquer parte propõe um novo horário para um agendamento
-- confirmado; o horário original continua valendo até a outra parte aceitar.
alter table public.service_appointments
  add column proposed_starts_at timestamptz,
  add column proposed_ends_at timestamptz,
  add column proposed_by uuid references public.profiles(id),
  add column proposed_at timestamptz,
  add constraint appointment_proposal_complete check (
    (proposed_starts_at is null) = (proposed_ends_at is null)
    and (proposed_starts_at is null) = (proposed_by is null)
    and (proposed_starts_at is null) = (proposed_at is null)
  ),
  add constraint appointment_proposal_window check (
    proposed_ends_at is null
    or (proposed_ends_at > proposed_starts_at and proposed_ends_at <= proposed_starts_at + interval '8 hours')
  );

-- Proposta só existe enquanto o agendamento está confirmado.
create function public.clear_appointment_proposal() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status <> 'confirmed' then
    new.proposed_starts_at := null;
    new.proposed_ends_at := null;
    new.proposed_by := null;
    new.proposed_at := null;
  end if;
  return new;
end $$;
create trigger appointment_clear_proposal before update on public.service_appointments
  for each row execute function public.clear_appointment_proposal();

create function public.propose_appointment_reschedule(p_id uuid, p_starts_at timestamptz, p_duration_minutes integer)
returns void language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; finish timestamptz; recipient uuid;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is null or auth.uid() not in (a.requester_id, a.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.service_request_id is not null then raise exception 'Acompanhe e encerre pelo atendimento vinculado.'; end if;
  if a.status <> 'confirmed' then raise exception 'Somente agendamentos confirmados podem ser reagendados.'; end if;
  if p_starts_at is null or p_starts_at <= now() or p_duration_minutes is null
    or p_duration_minutes not between 15 and 480 then raise exception 'Data ou duração inválida.'; end if;
  if a.proposed_by is not null and a.proposed_by <> auth.uid() then
    raise exception 'Responda à proposta de novo horário pendente.'; end if;
  if auth.uid() = a.requester_id and not exists (
    select 1 from public.provider_profiles where provider_id = a.provider_id and is_available) then
    raise exception 'Prestador indisponível.'; end if;
  finish := p_starts_at + make_interval(mins => p_duration_minutes);
  perform 1 from public.vehicles where id = a.vehicle_id for update;
  perform pg_advisory_xact_lock(hashtextextended(a.provider_id::text, 0));
  if exists (select 1 from public.service_appointments x
    where x.id <> a.id and (x.provider_id = a.provider_id or x.vehicle_id = a.vehicle_id)
    and x.status in ('requested','confirmed','in_service') and x.starts_at < finish and x.ends_at > p_starts_at) then
    raise exception 'Horário indisponível. Escolha outro horário.'; end if;
  update public.service_appointments set proposed_starts_at = p_starts_at, proposed_ends_at = finish,
    proposed_by = auth.uid(), proposed_at = clock_timestamp(), updated_at = now() where id = a.id;
  recipient := case when auth.uid() = a.requester_id then a.provider_id else a.requester_id end;
  insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    values(recipient, 'appointments', 'Novo horário proposto', 'Consulte a proposta de reagendamento.', a.id,
      'appointment-reschedule:' || a.id::text || ':' || extract(epoch from clock_timestamp())::text)
    on conflict (dedupe_key) do nothing;
end $$;

-- Quem recebeu a proposta aceita ou recusa; quem propôs só pode retirá-la.
create function public.respond_appointment_reschedule(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; recipient uuid;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is null or auth.uid() not in (a.requester_id, a.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.proposed_by is null then raise exception 'Não há proposta de novo horário pendente.'; end if;
  if p_accept is null then raise exception 'Ação inválida.'; end if;
  if a.proposed_by = auth.uid() and p_accept then
    raise exception 'Aguarde a resposta da outra parte.' using errcode = '42501'; end if;
  recipient := case when auth.uid() = a.requester_id then a.provider_id else a.requester_id end;
  if p_accept then
    if a.proposed_starts_at <= now() then raise exception 'O horário proposto já passou.'; end if;
    perform 1 from public.vehicles where id = a.vehicle_id for update;
    perform pg_advisory_xact_lock(hashtextextended(a.provider_id::text, 0));
    if exists (select 1 from public.service_appointments x
      where x.id <> a.id and (x.provider_id = a.provider_id or x.vehicle_id = a.vehicle_id)
      and x.status in ('requested','confirmed','in_service')
      and x.starts_at < a.proposed_ends_at and x.ends_at > a.proposed_starts_at) then
      raise exception 'Horário indisponível. Proponha outro horário.'; end if;
    update public.service_appointments set starts_at = proposed_starts_at, ends_at = proposed_ends_at,
      proposed_starts_at = null, proposed_ends_at = null, proposed_by = null, proposed_at = null,
      updated_at = now() where id = a.id;
    -- O lembrete de 24 h tem chave única por agendamento: apaga o antigo para
    -- que o novo horário gere um lembrete próprio.
    delete from public.product_notifications where dedupe_key like 'appointment-reminder:' || a.id::text || ':%';
  else
    update public.service_appointments set proposed_starts_at = null, proposed_ends_at = null,
      proposed_by = null, proposed_at = null, updated_at = now() where id = a.id;
  end if;
  if a.proposed_by <> auth.uid() then
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
      values(recipient, 'appointments',
        case when p_accept then 'Novo horário aceito' else 'Novo horário recusado' end,
        'Consulte o agendamento.', a.id,
        'appointment-reschedule-reply:' || a.id::text || ':' || extract(epoch from clock_timestamp())::text)
      on conflict (dedupe_key) do nothing;
  end if;
end $$;

revoke all on function public.propose_appointment_reschedule(uuid, timestamptz, integer) from public;
revoke all on function public.respond_appointment_reschedule(uuid, boolean) from public;
grant execute on function public.propose_appointment_reschedule(uuid, timestamptz, integer) to authenticated;
grant execute on function public.respond_appointment_reschedule(uuid, boolean) to authenticated;

-- O detalhe devolve colunas fixas: inclui o km do veículo (que não chegava à
-- tela) e a proposta pendente.
drop function public.get_service_appointment_detail(uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz,
  description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text,
  vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid)
language sql stable security definer set search_path = public as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(uuid) from public;
grant execute on function public.get_service_appointment_detail(uuid) to authenticated;
