-- Propostas e aceite atômico de orçamento.
-- Escritas críticas passam exclusivamente por RPCs para impedir atualizações
-- diretas de status, propostas aceitas concorrentes e grants indevidos.

drop policy "requester can update request" on public.service_requests;
drop policy "providers can create own offers" on public.provider_offers;
drop policy "providers can update own offers" on public.provider_offers;
drop policy "providers can delete own offers" on public.provider_offers;
drop policy "requesters can grant history access" on public.history_access_grants;
drop policy "requesters can revoke history access" on public.history_access_grants;

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

  select request.status, request.problem_type, request.location
  into target_request_status, target_request_problem, target_request_location
  from public.service_requests request
  where request.id = p_request_id
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
    update public.service_requests
    set status = 'collecting_offers'
    where id = p_request_id;

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

create or replace function public.accept_provider_offer(
  p_offer_id uuid,
  p_grant_history_access boolean default false
)
returns table (
  request_id uuid,
  offer_id uuid,
  provider_id uuid,
  request_status public.service_request_status,
  offer_status public.offer_status,
  history_access_granted boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
  target_request_id uuid;
  target_vehicle_id uuid;
  target_requester_id uuid;
  target_request_status public.service_request_status;
  target_provider_id uuid;
  target_offer_status public.offer_status;
begin
  if current_requester_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  select
    request.id,
    request.vehicle_id,
    request.requester_id,
    request.status,
    offer.provider_id,
    offer.status
  into
    target_request_id,
    target_vehicle_id,
    target_requester_id,
    target_request_status,
    target_provider_id,
    target_offer_status
  from public.provider_offers offer
  join public.service_requests request on request.id = offer.request_id
  where offer.id = p_offer_id
  for update of offer, request;

  if target_request_id is null then
    raise exception 'Proposta não encontrada.' using errcode = 'P0001';
  end if;

  if target_requester_id <> current_requester_id then
    raise exception 'Você não pode aceitar propostas deste chamado.' using errcode = '42501';
  end if;

  if target_request_status not in ('open', 'collecting_offers') then
    raise exception 'Este chamado não aceita propostas neste momento.' using errcode = 'P0001';
  end if;

  if target_offer_status <> 'submitted' then
    raise exception 'Esta proposta não está disponível para aceite.' using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from public.provider_offers offer
    where offer.request_id = target_request_id
      and offer.status = 'accepted'
      and offer.id <> p_offer_id
    for update
  ) then
    raise exception 'Este chamado já possui uma proposta aceita.' using errcode = '23505';
  end if;

  update public.provider_offers
  set status = case when id = p_offer_id then 'accepted' else 'rejected' end
  where request_id = target_request_id
    and status = 'submitted';

  update public.service_requests
  set
    status = 'offer_accepted',
    history_access_allowed = p_grant_history_access
  where id = target_request_id;

  if p_grant_history_access then
    insert into public.history_access_grants (
      request_id,
      vehicle_id,
      provider_id,
      granted_by,
      revoked_at
    )
    values (
      target_request_id,
      target_vehicle_id,
      target_provider_id,
      current_requester_id,
      null
    )
    on conflict (request_id, provider_id) do update
    set
      granted_by = excluded.granted_by,
      granted_at = timezone('utc', now()),
      revoked_at = null;
  end if;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (target_request_id, current_requester_id, 'offer_accepted', 'Proposta aceita pelo solicitante.');

  return query
  select
    target_request_id,
    p_offer_id,
    target_provider_id,
    'offer_accepted'::public.service_request_status,
    'accepted'::public.offer_status,
    p_grant_history_access;
end;
$$;

revoke all on function public.submit_provider_offer(uuid, integer, integer, integer, integer, text) from public;
revoke all on function public.accept_provider_offer(uuid, boolean) from public;
grant execute on function public.submit_provider_offer(uuid, integer, integer, integer, integer, text) to authenticated;
grant execute on function public.accept_provider_offer(uuid, boolean) to authenticated;
