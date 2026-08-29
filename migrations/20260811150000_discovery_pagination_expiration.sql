-- Descoberta endurecida: cursor por offset, expiração de chamados e
-- localização recente obrigatória para o prestador.

drop function if exists public.get_nearby_service_requests(integer);

create or replace function public.get_nearby_service_requests(
  p_limit integer default 30,
  p_offset integer default 0,
  p_max_age_minutes integer default 120
)
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
  if p_limit is null or p_limit < 1 or p_limit > 30 then
    raise exception 'O limite deve estar entre 1 e 30.' using errcode = '22023';
  end if;
  if p_offset is null or p_offset < 0 or p_offset > 500 then
    raise exception 'A paginação solicitada é inválida.' using errcode = '22023';
  end if;
  if p_max_age_minutes is null or p_max_age_minutes < 5 or p_max_age_minutes > 1440 then
    raise exception 'A validade do chamado deve estar entre 5 e 1440 minutos.' using errcode = '22023';
  end if;

  select location_row.location, location_row.updated_at, provider.service_radius_km * 1000
    into provider_location, provider_location_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations location_row on location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id and provider.is_available;
  if provider_location is null then
    raise exception 'Atualize sua localização e disponibilidade para receber chamados.' using errcode = 'P0001';
  end if;
  if provider_location_updated_at < timezone('utc', now()) - interval '15 minutes' then
    raise exception 'Atualize sua localização para buscar chamados próximos.' using errcode = 'P0001';
  end if;

  return query
  select request.id, request.problem_type, request.description, request.latitude,
    request.longitude, request.address_label, vehicle.model, vehicle.plate,
    round(extensions.st_distance(request.location, provider_location))::integer,
    request.opened_at
  from public.service_requests request
  join public.vehicles vehicle on vehicle.id = request.vehicle_id
  where request.status in ('open', 'collecting_offers')
    and request.opened_at >= timezone('utc', now()) - make_interval(mins => p_max_age_minutes)
    and extensions.st_dwithin(request.location, provider_location, provider_radius_meters)
    and exists (
      select 1 from public.provider_services service
      where service.provider_id = current_provider_id and service.problem_type = request.problem_type
    )
    and not exists (
      select 1 from public.provider_offers offer
      where offer.request_id = request.id and offer.provider_id = current_provider_id
    )
  order by extensions.st_distance(request.location, provider_location), request.opened_at asc, request.id
  limit p_limit offset p_offset;
end;
$$;

revoke all on function public.get_nearby_service_requests(integer, integer, integer) from public;
grant execute on function public.get_nearby_service_requests(integer, integer, integer) to authenticated;
