-- A duração do atendimento é definida pelo mecânico (um padrão por prestador),
-- não pelo motorista. Os horários oferecidos e o término do agendamento usam
-- esse padrão.
alter table public.provider_profiles
  add column appointment_duration_minutes integer not null default 60
  check (appointment_duration_minutes between 15 and 480);

create function public.set_provider_appointment_duration(p_minutes integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_minutes is null or p_minutes not between 15 and 480 then
    raise exception 'Informe uma duração entre 15 minutos e 8 horas.' using errcode = 'P0001'; end if;
  update public.provider_profiles set appointment_duration_minutes = p_minutes where provider_id = auth.uid();
  if not found then raise exception 'Apenas prestadores podem definir a duração.' using errcode = '42501'; end if;
end $$;
revoke all on function public.set_provider_appointment_duration(integer) from public, anon;
grant execute on function public.set_provider_appointment_duration(integer) to authenticated;

drop function public.list_provider_available_slots(uuid, date, integer, uuid);
create function public.list_provider_available_slots(p_provider_id uuid, p_date date,
  p_duration_minutes integer default null, p_vehicle_id uuid default null)
returns table(starts_at timestamptz) language plpgsql stable security definer set search_path = public as $$
declare tz text; dur integer;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta.' using errcode = '42501'; end if;
  -- A duração é do mecânico; o parâmetro só existe para chamadas antigas.
  select coalesce(p_duration_minutes, appointment_duration_minutes) into dur from public.provider_profiles where provider_id = p_provider_id;
  if p_date is null or dur is null or dur not between 15 and 480 then
    raise exception 'Data ou duração inválida.'; end if;
  tz := public.provider_timezone(p_provider_id);
  if exists (select 1 from public.provider_schedule_blocks where provider_id = p_provider_id and block_date = p_date) then
    return; end if;
  return query
    select s.ts from (
      select (g.ls at time zone tz) as ts
      from public.provider_schedule_windows w
      cross join lateral generate_series(p_date + w.start_time,
        p_date + w.end_time - make_interval(mins => dur), interval '30 minutes') as g(ls)
      where w.provider_id = p_provider_id and w.weekday = extract(dow from p_date)::int
    ) s
    where s.ts >= now() + interval '4 hours'
      and not exists (select 1 from public.service_appointments a
        where (a.provider_id = p_provider_id or (p_vehicle_id is not null and a.vehicle_id = p_vehicle_id))
        and a.status in ('requested','confirmed','in_service')
        and a.starts_at < s.ts + make_interval(mins => dur) and a.ends_at > s.ts)
    order by s.ts;
end $$;
revoke all on function public.list_provider_available_slots(uuid, date, integer, uuid) from public;
grant execute on function public.list_provider_available_slots(uuid, date, integer, uuid) to authenticated;

-- O término do agendamento vem do padrão do mecânico, ignorando a duração
-- enviada pelo cliente.
create or replace function public.create_service_appointment_v2(p_vehicle_id uuid, p_provider_id uuid, p_starts_at timestamptz,
  p_duration_minutes integer, p_description text, p_plan_id uuid default null,
  p_service_mode text default 'workshop', p_latitude double precision default null,
  p_longitude double precision default null, p_address_label text default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare result uuid; dur integer;
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
  select appointment_duration_minutes into dur from public.provider_profiles where provider_id = p_provider_id;
  result = public.create_service_appointment(p_vehicle_id, p_provider_id, p_starts_at, coalesce(dur, p_duration_minutes), p_description);
  update public.service_appointments set maintenance_plan_id = p_plan_id, service_mode = p_service_mode,
    location_latitude = case when p_service_mode = 'onsite' then p_latitude end,
    location_longitude = case when p_service_mode = 'onsite' then p_longitude end,
    location_label = case when p_service_mode = 'onsite' then trim(p_address_label) end,
    vehicle_odometer = (select r.odometer from public.vehicles v join public.vehicle_odometer_readings r on r.id = v.odometer_reading_id where v.id = p_vehicle_id)
  where id = result;
  return result;
end $$;
