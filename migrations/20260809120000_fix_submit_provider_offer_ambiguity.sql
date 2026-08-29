-- A coluna de retorno "id" da função entra no escopo PL/pgSQL. Qualificar a
-- atualização evita a ambiguidade entre essa variável de saída e a coluna da
-- tabela service_requests.

create or replace function public.submit_provider_offer(
  p_request_id uuid,
  p_travel_fee_cents integer,
  p_labor_fee_cents integer,
  p_parts_estimate_cents integer default null,
  p_estimated_arrival_minutes integer default null,
  p_notes text default null
)
returns table (
  id uuid,
  request_id uuid,
  provider_id uuid,
  status public.offer_status,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  current_provider_id uuid := auth.uid();
  target_request_status public.service_request_status;
  target_request_problem public.request_problem_type;
  target_request_location extensions.geography;
  provider_location extensions.geography;
  provider_location_updated_at timestamptz;
  provider_radius_meters integer;
  existing_offer_id uuid;
  created_offer public.provider_offers;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  if p_travel_fee_cents is null or p_labor_fee_cents is null
    or p_travel_fee_cents < 0 or p_labor_fee_cents < 0
    or (p_parts_estimate_cents is not null and p_parts_estimate_cents < 0) then
    raise exception 'Os valores do orçamento não podem ser negativos.' using errcode = '22023';
  end if;

  if p_estimated_arrival_minutes is null
    or p_estimated_arrival_minutes not between 1 and 1440 then
    raise exception 'Informe uma previsão de chegada entre 1 e 1440 minutos.'
      using errcode = '22023';
  end if;

  if p_notes is not null and char_length(trim(p_notes)) > 1000 then
    raise exception 'As observações podem ter no máximo 1000 caracteres.'
      using errcode = '22023';
  end if;

  select
    location_row.location,
    location_row.updated_at,
    provider.service_radius_km * 1000
  into
    provider_location,
    provider_location_updated_at,
    provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations location_row
    on location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id
    and provider.is_available;

  if provider_location is null then
    raise exception 'Atualize sua localização e disponibilidade antes de enviar propostas.'
      using errcode = 'P0001';
  end if;

  if provider_location_updated_at < now() - interval '15 minutes' then
    raise exception 'Atualize sua localização antes de enviar propostas.'
      using errcode = 'P0001';
  end if;

  select request_row.status, request_row.problem_type, request_row.location
  into target_request_status, target_request_problem, target_request_location
  from public.service_requests request_row
  where request_row.id = p_request_id
  for update;

  if target_request_status is null then
    raise exception 'Chamado não encontrado.' using errcode = 'P0001';
  end if;

  if target_request_status not in ('open', 'collecting_offers') then
    raise exception 'Este chamado não aceita novas propostas.' using errcode = 'P0001';
  end if;

  if not exists (
    select 1
    from public.provider_services service
    where service.provider_id = current_provider_id
      and service.problem_type = target_request_problem
  ) then
    raise exception 'Seu perfil não atende este tipo de chamado.' using errcode = 'P0001';
  end if;

  if not extensions.st_dwithin(
    target_request_location,
    provider_location,
    provider_radius_meters
  ) then
    raise exception 'Este chamado está fora do seu raio de atendimento.' using errcode = 'P0001';
  end if;

  select offer.id
  into existing_offer_id
  from public.provider_offers offer
  where offer.request_id = p_request_id
    and offer.provider_id = current_provider_id
  for update;

  if existing_offer_id is not null then
    raise exception 'Você já enviou uma proposta para este chamado.' using errcode = '23505';
  end if;

  insert into public.provider_offers (
    request_id,
    provider_id,
    travel_fee_cents,
    labor_fee_cents,
    parts_estimate_cents,
    estimated_arrival_minutes,
    notes
  )
  values (
    p_request_id,
    current_provider_id,
    p_travel_fee_cents,
    p_labor_fee_cents,
    p_parts_estimate_cents,
    p_estimated_arrival_minutes,
    nullif(trim(p_notes), '')
  )
  returning * into created_offer;

  if target_request_status = 'open' then
    update public.service_requests as request_row
    set status = 'collecting_offers'
    where request_row.id = p_request_id;

    insert into public.service_request_events (request_id, actor_id, status, note)
    values (p_request_id, current_provider_id, 'collecting_offers', 'Primeira proposta recebida.');
  end if;

  return query
  select
    created_offer.id,
    created_offer.request_id,
    created_offer.provider_id,
    created_offer.status,
    created_offer.created_at;
end;
$$;
