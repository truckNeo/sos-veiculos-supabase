-- Descoberta privada de chamados para prestadores elegíveis.
-- A função abaixo é a única forma de um prestador descobrir chamados antes de
-- enviar uma proposta; a policy de SELECT das tabelas continua restritiva.

create extension if not exists postgis with schema extensions;

alter table public.provider_locations
  add column location extensions.geography(Point, 4326)
  generated always as (
    extensions.st_setsrid(
      extensions.st_makepoint(longitude, latitude),
      4326
    )::extensions.geography
  ) stored;

alter table public.service_requests
  add column location extensions.geography(Point, 4326)
  generated always as (
    extensions.st_setsrid(
      extensions.st_makepoint(longitude, latitude),
      4326
    )::extensions.geography
  ) stored;

create index provider_locations_location_gix
  on public.provider_locations using gist (location);

create index service_requests_open_location_gix
  on public.service_requests using gist (location)
  where status in ('open', 'collecting_offers');

create or replace function public.get_nearby_service_requests(p_limit integer default 30)
returns table (
  id uuid,
  problem_type public.request_problem_type,
  description text,
  latitude double precision,
  longitude double precision,
  address_label text,
  vehicle_model text,
  vehicle_plate text,
  distance_meters integer,
  opened_at timestamptz
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

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'O limite deve estar entre 1 e 100.' using errcode = '22023';
  end if;

  select
    provider_location_row.location,
    provider_location_row.updated_at,
    provider.service_radius_km * 1000
  into
    provider_location,
    provider_location_updated_at,
    provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations provider_location_row
    on provider_location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id
    and provider.is_available;

  if provider_location is null then
    raise exception 'Atualize sua localização e disponibilidade para receber chamados.'
      using errcode = 'P0001';
  end if;

  if provider_location_updated_at < timezone('utc', now()) - interval '15 minutes' then
    raise exception 'Atualize sua localização para buscar chamados próximos.'
      using errcode = 'P0001';
  end if;

  return query
  select
    request.id,
    request.problem_type,
    request.description,
    request.latitude,
    request.longitude,
    request.address_label,
    vehicle.model,
    vehicle.plate,
    round(extensions.st_distance(request.location, provider_location))::integer,
    request.opened_at
  from public.service_requests request
  join public.vehicles vehicle on vehicle.id = request.vehicle_id
  where request.status in ('open', 'collecting_offers')
    and extensions.st_dwithin(request.location, provider_location, provider_radius_meters)
    and exists (
      select 1
      from public.provider_services service
      where service.provider_id = current_provider_id
        and service.problem_type = request.problem_type
    )
    and not exists (
      select 1
      from public.provider_offers offer
      where offer.request_id = request.id
        and offer.provider_id = current_provider_id
    )
  order by extensions.st_distance(request.location, provider_location), request.opened_at asc
  limit p_limit;
end;
$$;

revoke all on function public.get_nearby_service_requests(integer) from public;
grant execute on function public.get_nearby_service_requests(integer) to authenticated;
