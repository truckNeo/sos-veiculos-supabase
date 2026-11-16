-- Horário de atendimento do prestador e horários livres para agendamento.
-- Sem janelas cadastradas o prestador não tem restrição (comportamento anterior).
create table public.provider_schedule_windows (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6), -- 0 = domingo
  start_time time not null,
  end_time time not null,
  check (end_time > start_time)
);
create index provider_schedule_windows_idx on public.provider_schedule_windows(provider_id, weekday);

create table public.provider_schedule_blocks (
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  block_date date not null,
  primary key (provider_id, block_date)
);

alter table public.provider_schedule_windows enable row level security;
alter table public.provider_schedule_blocks enable row level security;
grant select on public.provider_schedule_windows, public.provider_schedule_blocks to authenticated;
-- O horário de atendimento é informação pública para quem vai agendar.
create policy "authenticated read schedule windows" on public.provider_schedule_windows
  for select to authenticated using (true);
create policy "authenticated read schedule blocks" on public.provider_schedule_blocks
  for select to authenticated using (true);

-- Fuso do prestador pela UF do endereço (o restante do Brasil usa Brasília).
create function public.provider_timezone(p_provider_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select case upper(address_state)
    when 'AC' then 'America/Rio_Branco'
    when 'AM' then 'America/Manaus'
    when 'RO' then 'America/Porto_Velho'
    when 'RR' then 'America/Boa_Vista'
    when 'MT' then 'America/Cuiaba'
    when 'MS' then 'America/Campo_Grande'
    else 'America/Sao_Paulo' end
    from public.provider_profiles where provider_id = p_provider_id), 'America/Sao_Paulo');
$$;

-- Substitui a agenda inteira: p_windows = [{"weekday":1,"start_time":"08:00","end_time":"18:00"}].
create function public.save_provider_schedule(p_windows jsonb, p_blocked_dates date[])
returns void language plpgsql security definer set search_path = public as $$
declare provider uuid := auth.uid(); tz text; today date;
begin
  if provider is null or not exists (select 1 from public.provider_profiles where provider_id = provider) then
    raise exception 'Apenas prestadores podem definir horários.' using errcode = '42501'; end if;
  p_windows := coalesce(p_windows, '[]'::jsonb);
  if jsonb_typeof(p_windows) <> 'array' or jsonb_array_length(p_windows) > 42 then
    raise exception 'Horários inválidos.'; end if;
  if exists (select 1 from jsonb_to_recordset(p_windows) as x(weekday int, start_time text, end_time text)
    where x.weekday is null or x.weekday not between 0 and 6
      or x.start_time is null or x.start_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or x.end_time is null or x.end_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      or x.end_time <= x.start_time) then
    raise exception 'Informe dia da semana e um horário final posterior ao inicial.'; end if;
  if exists (
    with w as (select row_number() over () n, x.weekday, x.start_time::time s, x.end_time::time e
      from jsonb_to_recordset(p_windows) as x(weekday int, start_time text, end_time text))
    select 1 from w a join w b on a.weekday = b.weekday and a.n < b.n and a.s < b.e and b.s < a.e) then
    raise exception 'Os horários do mesmo dia não podem se sobrepor.'; end if;
  tz := public.provider_timezone(provider);
  today := (now() at time zone tz)::date;
  if cardinality(coalesce(p_blocked_dates, '{}')) > 366 then raise exception 'Datas bloqueadas demais.'; end if;

  delete from public.provider_schedule_windows where provider_id = provider;
  insert into public.provider_schedule_windows(provider_id, weekday, start_time, end_time)
    select provider, x.weekday, x.start_time::time, x.end_time::time
    from jsonb_to_recordset(p_windows) as x(weekday int, start_time text, end_time text);
  delete from public.provider_schedule_blocks where provider_id = provider;
  insert into public.provider_schedule_blocks(provider_id, block_date)
    select distinct provider, d from unnest(coalesce(p_blocked_dates, '{}')) d where d >= today;
end $$;

-- Recusa horários fora da agenda do prestador (se ele definiu uma).
create function public.assert_provider_slot(p_provider_id uuid, p_starts timestamptz, p_ends timestamptz)
returns void language plpgsql stable security definer set search_path = public as $$
declare tz text; ls timestamp; le timestamp;
begin
  if not exists (select 1 from public.provider_schedule_windows where provider_id = p_provider_id) then return; end if;
  tz := public.provider_timezone(p_provider_id);
  ls := p_starts at time zone tz;
  le := p_ends at time zone tz;
  if exists (select 1 from public.provider_schedule_blocks where provider_id = p_provider_id and block_date = ls::date) then
    raise exception 'O prestador não atende nesta data.'; end if;
  if ls::date <> le::date or not exists (select 1 from public.provider_schedule_windows
    where provider_id = p_provider_id and weekday = extract(dow from ls)::int
      and start_time <= ls::time and end_time >= le::time) then
    raise exception 'Fora do horário de atendimento do prestador.'; end if;
end $$;

create function public.enforce_provider_schedule() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.assert_provider_slot(new.provider_id, new.starts_at, new.ends_at);
  elsif new.proposed_starts_at is not null and new.proposed_starts_at is distinct from old.proposed_starts_at then
    perform public.assert_provider_slot(new.provider_id, new.proposed_starts_at, new.proposed_ends_at);
  end if;
  return new;
end $$;
create trigger appointment_enforce_schedule before insert or update of proposed_starts_at on public.service_appointments
  for each row execute function public.enforce_provider_schedule();

-- Horários livres de um dia (data no fuso do prestador), de 30 em 30 minutos.
create function public.list_provider_available_slots(p_provider_id uuid, p_date date,
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
    where s.ts > now()
      and not exists (select 1 from public.service_appointments a
        where (a.provider_id = p_provider_id or (p_vehicle_id is not null and a.vehicle_id = p_vehicle_id))
        and a.status in ('requested','confirmed','in_service')
        and a.starts_at < s.ts + make_interval(mins => p_duration_minutes) and a.ends_at > s.ts)
    order by s.ts;
end $$;

revoke all on function public.provider_timezone(uuid) from public;
revoke all on function public.save_provider_schedule(jsonb, date[]) from public;
revoke all on function public.assert_provider_slot(uuid, timestamptz, timestamptz) from public;
revoke all on function public.enforce_provider_schedule() from public;
revoke all on function public.list_provider_available_slots(uuid, date, integer, uuid) from public;
grant execute on function public.save_provider_schedule(jsonb, date[]) to authenticated;
grant execute on function public.list_provider_available_slots(uuid, date, integer, uuid) to authenticated;
