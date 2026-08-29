-- Dispatch individual e seguro para a descoberta ativa de chamados.
-- A elegibilidade replica a regra existente de get_nearby_service_requests.

create table public.provider_vehicles (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  vehicle_type text not null check (vehicle_type in ('service', 'towing')),
  plate text not null unique check (char_length(trim(plate)) between 7 and 10),
  model text not null check (char_length(trim(model)) >= 2),
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index provider_vehicles_active_idx on public.provider_vehicles(provider_id)
  where is_active;
create trigger provider_vehicles_set_updated_at before update on public.provider_vehicles
  for each row execute function public.set_updated_at();

alter table public.provider_vehicles enable row level security;
create policy "providers manage own operational vehicles"
  on public.provider_vehicles for all to authenticated
  using (provider_id = auth.uid()) with check (provider_id = auth.uid());
revoke all on public.provider_vehicles from anon;
grant select, insert, update, delete on public.provider_vehicles to authenticated;

create table public.service_request_dispatches (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete cascade,
  problem_type public.request_problem_type not null,
  description text not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  address_label text,
  vehicle_model text not null,
  vehicle_plate text not null,
  distance_meters integer not null check (distance_meters >= 0),
  status text not null default 'pending' check (status in ('pending', 'seen', 'dismissed', 'offered', 'cancelled')),
  seen_at timestamptz,
  dismissed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  unique (request_id, provider_id)
);

create index service_request_dispatches_provider_pending_idx
  on public.service_request_dispatches(provider_id, created_at desc)
  where status in ('pending', 'seen');

alter table public.service_request_dispatches enable row level security;
create policy "providers read own dispatches"
  on public.service_request_dispatches for select to authenticated
  using (provider_id = auth.uid());
revoke all on public.service_request_dispatches from authenticated;
grant select on public.service_request_dispatches to authenticated;

create or replace function public.create_service_request_dispatches()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.service_request_dispatches (
    request_id, provider_id, problem_type, description, latitude, longitude,
    address_label, vehicle_model, vehicle_plate, distance_meters
  )
  select new.id, provider.provider_id, new.problem_type, new.description,
    new.latitude, new.longitude, new.address_label, vehicle.model, vehicle.plate,
    round(extensions.st_distance(new.location, provider_location.location))::integer
  from public.provider_profiles provider
  join public.provider_locations provider_location on provider_location.provider_id = provider.provider_id
  join public.vehicles vehicle on vehicle.id = new.vehicle_id
  where provider.is_available
    and provider_location.updated_at >= timezone('utc', now()) - interval '15 minutes'
    and extensions.st_dwithin(new.location, provider_location.location, provider.service_radius_km * 1000)
    and exists (
      select 1 from public.provider_services service
      where service.provider_id = provider.provider_id and service.problem_type = new.problem_type
    );
  return new;
end;
$$;

create trigger service_requests_create_dispatches
  after insert on public.service_requests
  for each row execute function public.create_service_request_dispatches();

create or replace function public.mark_service_request_dispatch_seen(p_dispatch_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.service_request_dispatches
  set status = 'seen', seen_at = timezone('utc', now())
  where id = p_dispatch_id and provider_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'Dispatch não encontrado ou indisponível.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.dismiss_service_request_dispatch(p_dispatch_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.service_request_dispatches
  set status = 'dismissed', dismissed_at = timezone('utc', now())
  where id = p_dispatch_id and provider_id = auth.uid() and status in ('pending', 'seen');
  if not found then
    raise exception 'Dispatch não encontrado ou indisponível.' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.sync_service_request_dispatches()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_table_name = 'provider_offers' and new.status = 'submitted' then
    update public.service_request_dispatches
    set status = 'offered'
    where request_id = new.request_id and provider_id = new.provider_id and status in ('pending', 'seen');
  elsif tg_table_name = 'provider_offers' and new.status = 'accepted' then
    update public.service_request_dispatches
    set status = case when provider_id = new.provider_id then 'offered' else 'cancelled' end
    where request_id = new.request_id and status not in ('dismissed', 'cancelled');
  elsif tg_table_name = 'service_requests' and new.selected_provider_id is not null then
    update public.service_request_dispatches
    set status = case when provider_id = new.selected_provider_id then 'offered' else 'cancelled' end
    where request_id = new.id and status not in ('dismissed', 'cancelled');
  elsif tg_table_name = 'service_requests' and new.status = 'cancelled' then
    update public.service_request_dispatches
    set status = 'cancelled'
    where request_id = new.id and status not in ('dismissed', 'cancelled');
  end if;
  return new;
end;
$$;

create trigger provider_offers_sync_dispatches
  after insert or update of status on public.provider_offers
  for each row execute function public.sync_service_request_dispatches();
create trigger service_requests_sync_dispatches
  after update of selected_provider_id, status on public.service_requests
  for each row execute function public.sync_service_request_dispatches();

revoke all on function public.mark_service_request_dispatch_seen(uuid) from public;
revoke all on function public.dismiss_service_request_dispatch(uuid) from public;
grant execute on function public.mark_service_request_dispatch_seen(uuid) to authenticated;
grant execute on function public.dismiss_service_request_dispatch(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'service_request_dispatches'
  ) then
    alter publication supabase_realtime add table public.service_request_dispatches;
  end if;
end;
$$;
