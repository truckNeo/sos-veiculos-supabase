-- Mesma classe de bug de begin_asaas_payment_release: a coluna de saída
-- `wallet_id` da RETURNS TABLE colide com provider_asaas_accounts.wallet_id.
create or replace function public.claim_asaas_provider_transfer(p_transfer_id uuid)
returns table (transfer_id uuid, provider_net_cents integer, wallet_id text)
language plpgsql security definer set search_path = public
as $$
declare transfer_row public.service_provider_transfers; account_wallet text;
begin
  select * into transfer_row from public.service_provider_transfers where id = p_transfer_id for update;
  if transfer_row.id is null then raise exception 'Liberação não encontrada.' using errcode = 'P0001'; end if;
  if transfer_row.status = 'completed' then return; end if;
  if transfer_row.status <> 'pending' then raise exception 'A liberação já está em processamento e será revisada pela equipe.' using errcode = 'P0001'; end if;
  select paa.wallet_id into account_wallet from public.provider_asaas_accounts paa
  where paa.provider_id = transfer_row.provider_id and paa.status = 'verified';
  if account_wallet is null then raise exception 'Subconta Asaas não verificada.' using errcode = 'P0001'; end if;
  update public.service_provider_transfers set status = 'processing', initiated_at = timezone('utc', now()) where id = p_transfer_id;
  return query select transfer_row.id, transfer_row.provider_net_cents, account_wallet;
end;
$$;
