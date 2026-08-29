create or replace function public.reject_provider_offer(p_offer_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  requester uuid := auth.uid();
  offer_request uuid;
  offer_provider uuid;
  offer_status public.offer_status;
begin
  if requester is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  select offer.request_id, offer.provider_id, offer.status
  into offer_request, offer_provider, offer_status
  from public.provider_offers offer
  join public.service_requests request on request.id = offer.request_id
  where offer.id = p_offer_id and request.requester_id = requester
    and request.workflow_phase = 'open'
  for update;

  if offer_request is null or offer_status <> 'submitted'::public.offer_status then
    raise exception 'Proposta não está disponível para recusa.' using errcode = 'P0001';
  end if;

  update public.provider_offers
  set status = 'rejected'::public.offer_status
  where id = p_offer_id;

  update public.service_request_dispatches
  set status = 'cancelled'
  where request_id = offer_request and provider_id = offer_provider
    and status in ('pending', 'seen', 'offered');
end;
$$;

revoke all on function public.reject_provider_offer(uuid) from public;
grant execute on function public.reject_provider_offer(uuid) to authenticated;
