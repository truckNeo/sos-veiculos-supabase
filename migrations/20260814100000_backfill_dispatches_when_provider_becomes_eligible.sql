-- Um prestador pode salvar a localização poucos segundos após a abertura do chamado.
-- Nessa corrida, cria o dispatch assim que ele passa a ser elegível, sem exigir refresh manual.

create or replace function public.create_dispatches_for_provider(p_provider_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  provider_location extensions.geography;
  provider_updated_at timestamptz;
  provider_radius_meters integer;
begin
  select location.location, location.updated_at, provider.service_radius_km * 1000
  into provider_location, provider_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations location on location.provider_id = provider.provider_id
  where provider.provider_id = p_provider_id and provider.is_available;

  if provider_location is null or provider_updated_at < timezone('utc', now()) - interval '15 minutes' then
    return;
  end if;

  insert into public.service_request_dispatches (
    request_id, provider_id, problem_type, description, latitude, longitude,
    address_label, vehicle_model, vehicle_plate, distance_meters
  )
  select request.id, p_provider_id, request.problem_type, request.description,
    request.latitude, request.longitude, request.address_label, vehicle.model, vehicle.plate,
    round(extensions.st_distance(request.location, provider_location))::integer
  from public.service_requests request
  join public.vehicles vehicle on vehicle.id = request.vehicle_id
  where request.status in ('open', 'collecting_offers')
    and request.workflow_phase = 'open'
    and request.opened_at >= timezone('utc', now()) - interval '120 minutes'
    and extensions.st_dwithin(request.location, provider_location, provider_radius_meters)
    and exists (
      select 1 from public.provider_services service
      where service.provider_id = p_provider_id and service.problem_type = request.problem_type
    )
  on conflict (request_id, provider_id) do nothing;
end;
$$;

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

create or replace function public.create_dispatches_after_provider_location_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.create_dispatches_for_provider(new.provider_id);
  return new;
end;
$$;

create trigger provider_locations_create_dispatches
  after insert or update of latitude, longitude, updated_at on public.provider_locations
  for each row execute function public.create_dispatches_after_provider_location_change();

create or replace function public.create_dispatches_after_provider_availability_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_available then
    perform public.create_dispatches_for_provider(new.provider_id);
  end if;
  return new;
end;
$$;

create trigger provider_profiles_create_dispatches
  after update of is_available on public.provider_profiles
  for each row execute function public.create_dispatches_after_provider_availability_change();

revoke all on function public.create_dispatches_for_provider(uuid) from public;
