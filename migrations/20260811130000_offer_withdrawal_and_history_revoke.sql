-- Operações seguras de pós-envio para propostas e histórico autorizado.

create or replace function public.withdraw_provider_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  provider uuid := auth.uid();
  target_request uuid;
  target_status public.offer_status;
  request_status public.service_request_status;
  remaining_submitted integer;
begin
  select offer.request_id, offer.status, request_row.status
    into target_request, target_status, request_status
  from public.provider_offers offer
  join public.service_requests request_row on request_row.id = offer.request_id
  where offer.id = p_offer_id and offer.provider_id = provider
  for update of offer, request_row;
  if target_request is null then
    raise exception 'Proposta não encontrada ou sem permissão.' using errcode = '42501';
  end if;
  if target_status <> 'submitted' then
    raise exception 'Somente propostas pendentes podem ser retiradas.' using errcode = 'P0001';
  end if;
  if request_status not in ('open', 'collecting_offers') then
    raise exception 'Este chamado não aceita mais alterações de proposta.' using errcode = 'P0001';
  end if;

  update public.provider_offers
  set status = 'withdrawn'
  where id = p_offer_id;
  select count(*) into remaining_submitted
  from public.provider_offers
  where request_id = target_request and status = 'submitted';
  if remaining_submitted = 0 then
    update public.service_requests
    set status = 'open'
    where id = target_request and status = 'collecting_offers';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (target_request, provider, (select status from public.service_requests where id = target_request), 'Prestador retirou a proposta de deslocamento.');
end;
$$;

create or replace function public.revoke_history_access(p_request_id uuid, p_provider_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requester uuid := auth.uid();
  vehicle uuid;
begin
  select request_row.vehicle_id into vehicle
  from public.service_requests request_row
  where request_row.id = p_request_id and request_row.requester_id = requester
  for update;
  if vehicle is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  update public.history_access_grants
  set revoked_at = coalesce(revoked_at, timezone('utc', now()))
  where request_id = p_request_id and provider_id = p_provider_id and vehicle_id = vehicle
    and granted_by = requester;
  if not found then
    raise exception 'Autorização de histórico não encontrada.' using errcode = 'P0001';
  end if;
  update public.service_requests
  set history_access_allowed = false
  where id = p_request_id and selected_provider_id = p_provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, requester, (select status from public.service_requests where id = p_request_id), 'Motorista revogou o acesso do prestador ao histórico do veículo.');
end;
$$;

revoke all on function public.withdraw_provider_offer(uuid), public.revoke_history_access(uuid, uuid) from public;
grant execute on function public.withdraw_provider_offer(uuid), public.revoke_history_access(uuid, uuid) to authenticated;
