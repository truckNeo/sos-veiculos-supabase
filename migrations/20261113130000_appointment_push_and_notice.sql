-- Antecedência mínima de 4 h (resposta garantida de pelo menos 2 h ao prestador),
-- notificações de agendamento que dizem o que aconteceu e reserva do push imediato.
create or replace function public.enforce_appointment_notice() returns trigger language plpgsql as $$
begin
  if new.starts_at < now() + interval '4 hours' then
    raise exception 'Agende com pelo menos 4 horas de antecedência.';
  end if;
  return new;
end $$;

create or replace function public.list_provider_available_slots(p_provider_id uuid, p_date date,
  p_duration_minutes integer default 60, p_vehicle_id uuid default null)
returns table(starts_at timestamptz) language plpgsql stable security definer set search_path = public as $$
declare tz text;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.' using errcode = '42501'; end if;
  if p_date is null or p_duration_minutes is null or p_duration_minutes not between 15 and 480 then
    raise exception 'Data ou duração inválida.'; end if;
  tz := public.provider_timezone(p_provider_id);
  if exists (select 1 from public.provider_schedule_blocks where provider_id = p_provider_id and block_date = p_date) then
    return; end if;
  return query
    select s.ts from (
      select (g.ls at time zone tz) as ts
      from public.provider_schedule_windows w
      cross join lateral generate_series(p_date + w.start_time,
        p_date + w.end_time - make_interval(mins => p_duration_minutes), interval '30 minutes') as g(ls)
      where w.provider_id = p_provider_id and w.weekday = extract(dow from p_date)::int
    ) s
    where s.ts >= now() + interval '4 hours'
      and not exists (select 1 from public.service_appointments a
        where (a.provider_id = p_provider_id or (p_vehicle_id is not null and a.vehicle_id = p_vehicle_id))
        and a.status in ('requested','confirmed','in_service')
        and a.starts_at < s.ts + make_interval(mins => p_duration_minutes) and a.ends_at > s.ts)
    order by s.ts;
end $$;

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
    values(recipient, 'appointments',
      case p_status when 'confirmed' then 'Agendamento confirmado'
        when 'rejected' then 'Pedido de agendamento recusado'
        when 'cancelled' then 'Agendamento cancelado'
        else 'Agendamento atualizado' end,
      case p_status when 'confirmed' then 'O prestador confirmou o horário. Consulte os detalhes.'
        when 'rejected' then 'O prestador não poderá atender neste horário. Faça um novo agendamento.'
        when 'cancelled' then 'O agendamento foi cancelado pela outra parte.'
        else 'Consulte o novo status do seu agendamento.' end,
      p_id, p_id::text || ':' || p_status)
    on conflict (dedupe_key) do nothing;
end $$;

-- Reserva (atomicamente) a notificação que a outra parte deve receber agora, para
-- a Edge Function enviar o push sem esperar o agendador de lembretes.
create function public.claim_appointment_notification(p_appointment_id uuid, p_actor uuid)
returns setof public.product_notifications
language plpgsql security definer set search_path = public as $$
declare a public.service_appointments; recipient uuid;
begin
  select * into a from public.service_appointments where id = p_appointment_id;
  if not found or p_actor is null or p_actor not in (a.requester_id, a.provider_id) then
    raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  recipient := case when p_actor = a.requester_id then a.provider_id else a.requester_id end;
  return query
    update public.product_notifications n set push_attempts = n.push_attempts + 1,
      push_lease_until = now() + interval '1 minute', push_claim = gen_random_uuid()
    where n.id in (select id from public.product_notifications
      where resource_id = p_appointment_id and user_id = recipient and category = 'appointments'
        and push_sent_at is null and push_attempts < 6
        and (push_lease_until is null or push_lease_until < now())
        and created_at > now() - interval '15 minutes'
      order by created_at for update skip locked)
    returning n.*;
end $$;
revoke all on function public.claim_appointment_notification(uuid, uuid) from public;
grant execute on function public.claim_appointment_notification(uuid, uuid) to service_role;
