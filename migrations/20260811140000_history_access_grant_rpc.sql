-- Concede acesso explícito ao histórico somente após a escolha do prestador.
create or replace function public.grant_history_access(p_request_id uuid, p_provider_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requester uuid := auth.uid();
  vehicle uuid;
  phase public.service_workflow_phase;
begin
  select request_row.vehicle_id, request_row.workflow_phase
    into vehicle, phase
  from public.service_requests request_row
  where request_row.id = p_request_id and request_row.requester_id = requester
  for update;
  if vehicle is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  if phase not in ('awaiting_dispatch_payment', 'diagnosis', 'service_released', 'awaiting_driver_confirmation') then
    raise exception 'O histórico só pode ser compartilhado após a escolha do prestador.' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.provider_offers offer
    where offer.request_id = p_request_id and offer.provider_id = p_provider_id and offer.status = 'accepted'
  ) then
    raise exception 'O prestador não está selecionado neste chamado.' using errcode = 'P0001';
  end if;
  insert into public.history_access_grants (request_id, vehicle_id, provider_id, granted_by, revoked_at)
  values (p_request_id, vehicle, p_provider_id, requester, null)
  on conflict (request_id, provider_id) do update
    set granted_by = excluded.granted_by, granted_at = timezone('utc', now()), revoked_at = null;
  update public.service_requests set history_access_allowed = true where id = p_request_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, requester, (select status from public.service_requests where id = p_request_id), 'Motorista autorizou o prestador a consultar o histórico do veículo.');
end;
$$;

revoke all on function public.grant_history_access(uuid, uuid) from public;
grant execute on function public.grant_history_access(uuid, uuid) to authenticated;
