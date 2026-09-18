-- begin_asaas_payment_release falhava com "column reference provider_id is
-- ambiguous": a coluna de saída `provider_id` da RETURNS TABLE também vira
-- uma variável PL/pgSQL implícita, colidindo com provider_asaas_accounts.provider_id
-- e provider_wallet_entries.provider_id nas cláusulas WHERE sem alias.
create or replace function public.begin_asaas_payment_release(p_request_id uuid)
returns table (transfer_id uuid, provider_id uuid, provider_net_cents integer)
language plpgsql security definer set search_path = public
as $$
declare requester uuid := auth.uid(); provider uuid; phase public.service_workflow_phase;
  gross integer; fee integer; net integer; transfer_row public.service_provider_transfers;
begin
  select selected_provider_id, workflow_phase into provider, phase from public.service_requests
  where id = p_request_id and requester_id = requester for update;
  if requester is null or provider is null then raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501'; end if;
  if phase not in ('awaiting_driver_confirmation', 'release_processing') then raise exception 'O serviço não está aguardando sua conferência.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.service_payment_charges c where c.request_id = p_request_id and c.status <> 'paid') then
    raise exception 'Existem cobranças pendentes para este chamado.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.provider_asaas_accounts paa where paa.provider_id = provider and paa.status = 'verified') then
    raise exception 'O cadastro financeiro do prestador ainda não foi aprovado.' using errcode = 'P0001';
  end if;
  select * into transfer_row from public.service_provider_transfers t where t.request_id = p_request_id for update;
  if transfer_row.id is not null then
    return query select transfer_row.id, transfer_row.provider_id, transfer_row.provider_net_cents;
    return;
  end if;
  select coalesce(sum(pwe.gross_amount_cents), 0) into gross from public.provider_wallet_entries pwe
  where pwe.request_id = p_request_id and pwe.provider_id = provider and pwe.status = 'held';
  if gross <= 0 then raise exception 'Não há saldo retido para liberar.' using errcode = 'P0001'; end if;
  fee := (gross * 10) / 100;
  net := gross - fee;
  insert into public.service_provider_transfers (request_id, provider_id, gross_amount_cents, platform_fee_cents, provider_net_cents)
  values (p_request_id, provider, gross, fee, net) returning * into transfer_row;
  update public.service_requests set workflow_phase = 'release_processing' where id = p_request_id;
  return query select transfer_row.id, provider, net;
end;
$$;
