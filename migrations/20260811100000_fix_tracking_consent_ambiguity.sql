-- Qualifica as referências da RPC de consentimento. O nome da coluna de saída
-- tracking_consent_at também existe na tabela e não pode ficar implícito no
-- PL/pgSQL.
create or replace function public.set_service_request_tracking_consent(
  p_request_id uuid,
  p_allowed boolean
)
returns table (request_id uuid, tracking_enabled boolean, tracking_consent_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare
  requester uuid := auth.uid();
  provider uuid;
  phase public.service_workflow_phase;
  current_status public.service_request_status;
  updated_consent_at timestamptz;
begin
  select request_row.selected_provider_id, request_row.workflow_phase, request_row.status
  into provider, phase, current_status
  from public.service_requests as request_row
  where request_row.id = p_request_id and request_row.requester_id = requester
  for update;
  if requester is null or provider is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  if phase in ('completed', 'cancelled') then
    raise exception 'O rastreamento não pode ser alterado após o encerramento.' using errcode = 'P0001';
  end if;

  update public.service_requests as request_row
  set tracking_enabled = p_allowed,
    tracking_consent_at = case when p_allowed then timezone('utc', now()) else request_row.tracking_consent_at end,
    tracking_revoked_at = case when p_allowed then null else timezone('utc', now()) end
  where request_row.id = p_request_id;

  select request_row.tracking_consent_at
  into updated_consent_at
  from public.service_requests as request_row
  where request_row.id = p_request_id;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, requester, current_status, case when p_allowed then 'Motorista autorizou o rastreamento do prestador.' else 'Motorista revogou o rastreamento do prestador.' end);
  return query select p_request_id, p_allowed, updated_consent_at;
end;
$$;

revoke all on function public.set_service_request_tracking_consent(uuid, boolean) from public;
grant execute on function public.set_service_request_tracking_consent(uuid, boolean) to authenticated;
