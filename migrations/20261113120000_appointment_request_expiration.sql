-- Expiração de pedidos de agendamento sem resposta: 24 h após o pedido ou 2 h
-- antes do horário marcado, o que vier primeiro. O prestador recebe um lembrete
-- na metade do prazo. A varredura roda no job de lembretes (uma vez por minuto).
alter table public.service_appointments drop constraint service_appointments_status_check;
alter table public.service_appointments add constraint service_appointments_status_check
  check (status in ('requested','confirmed','in_service','rejected','cancelled','completed','expired'));

create index appointments_requested_idx on public.service_appointments(created_at) where status = 'requested';

create function public.appointment_response_deadline(p_created_at timestamptz, p_starts_at timestamptz)
returns timestamptz language sql immutable as $$
  select least(p_created_at + interval '24 hours', p_starts_at - interval '2 hours');
$$;

-- Sem antecedência mínima o pedido expiraria assim que fosse criado.
create function public.enforce_appointment_notice() returns trigger language plpgsql as $$
begin
  if new.starts_at < now() + interval '2 hours' then
    raise exception 'Agende com pelo menos 2 horas de antecedência.';
  end if;
  return new;
end $$;
create trigger appointment_enforce_notice before insert on public.service_appointments
  for each row execute function public.enforce_appointment_notice();

-- Entre duas varreduras o prestador ainda poderia confirmar um pedido vencido.
create function public.block_expired_appointment_confirmation() returns trigger language plpgsql as $$
begin
  if old.status = 'requested' and new.status = 'confirmed'
    and now() >= public.appointment_response_deadline(old.created_at, old.starts_at) then
    raise exception 'Este pedido expirou. Peça um novo agendamento.';
  end if;
  return new;
end $$;
create trigger appointment_block_expired_confirm before update of status on public.service_appointments
  for each row execute function public.block_expired_appointment_confirmation();

create function public.expire_stale_appointment_requests() returns integer
language plpgsql security definer set search_path = public as $$
declare total integer;
begin
  with expired as (
    update public.service_appointments set status = 'expired', updated_at = now()
    where status = 'requested' and now() >= public.appointment_response_deadline(created_at, starts_at)
    returning id, requester_id, provider_id
  ), notified as (
    insert into public.product_notifications(user_id, category, title, body, resource_id, dedupe_key)
    select requester_id, 'appointments', 'Agendamento expirado',
      'O prestador não respondeu a tempo. Faça um novo agendamento.', id, 'appointment-expired:' || id::text || ':' || requester_id::text
    from expired
    union all
    select provider_id, 'appointments', 'Pedido de agendamento expirado',
      'O pedido foi encerrado por falta de resposta.', id, 'appointment-expired:' || id::text || ':' || provider_id::text
    from expired
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into total from expired;
  return total;
end $$;
revoke all on function public.expire_stale_appointment_requests() from public;
grant execute on function public.expire_stale_appointment_requests() to service_role;

create or replace function public.enqueue_product_reminders() returns void language plpgsql security definer set search_path=public as $$ begin
 perform public.expire_vehicle_share_accesses();
 perform public.expire_stale_appointment_requests();
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
 and (n.dedupe_key not like 'appointment-expiry-reminder:%' or a.status='requested'))
 else exists(select 1 from public.vehicle_share_invites i join public.vehicles v on v.id=i.vehicle_id join auth.users u on u.id=n.user_id
 where i.id=n.resource_id and i.status='pending' and i.expires_at>now() and (i.access_expires_at is null or i.access_expires_at>now()) and lower(u.email)=i.recipient_email
 and (v.owner_profile_id=i.invited_by or exists(select 1 from public.organizations where id=v.organization_id and owner_id=i.invited_by))) end from public.product_notifications n where n.id=p_id),false);
$$;

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
    where s.ts >= now() + interval '2 hours'
      and not exists (select 1 from public.service_appointments a
        where (a.provider_id = p_provider_id or (p_vehicle_id is not null and a.vehicle_id = p_vehicle_id))
        and a.status in ('requested','confirmed','in_service')
        and a.starts_at < s.ts + make_interval(mins => p_duration_minutes) and a.ends_at > s.ts)
    order by s.ts;
end $$;
