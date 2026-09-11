-- Substitui o marketplace Iugu pelo Asaas. Mesma arquitetura (subconta do
-- prestador, saldo retido na conta mestre, repasse e saque em etapas
-- separadas), só troca o provedor. Renomeia em vez de recriar do zero pra
-- preservar dados de teste já gerados.
--
-- Modelo validado em sandbox (scripts/asaas-escrow-poc/):
--   split de pagamento + Conta Escrow NÃO retêm valor (o split cai
--   disponível na hora); a retenção de verdade é cobrança SEM split na
--   conta mestre + POST /transfers na liberação, autorizado pelo
--   "mecanismo de validação de saque via webhook" (asaas-operation-webhook).

alter type public.iugu_account_status rename to asaas_account_status;
alter type public.iugu_transfer_status rename to asaas_transfer_status;

-- provider_iugu_accounts -> provider_asaas_accounts ---------------------

alter table public.provider_iugu_accounts rename to provider_asaas_accounts;
alter table public.provider_asaas_accounts rename column iugu_account_id to asaas_account_id;
alter table public.provider_asaas_accounts rename column withdraw_token_ciphertext to api_key_ciphertext;
alter table public.provider_asaas_accounts rename column withdraw_token_iv to api_key_iv;

comment on column public.provider_asaas_accounts.api_key_ciphertext is
  'Cifra AES-GCM da apiKey da subconta Asaas. Diferente da Iugu (que orquestra '
  'saques via conta mestre), o Asaas exige a própria chave da subconta para '
  'movimentar o saldo dela — por isso guardamos, nunca expomos ao app.';

alter table public.provider_asaas_accounts
  add column if not exists wallet_id text,
  add column if not exists bank_code text,
  add column if not exists bank_agency text,
  add column if not exists bank_account text,
  add column if not exists bank_account_digit text,
  add column if not exists bank_account_type text
    check (bank_account_type is null or bank_account_type in ('CONTA_CORRENTE', 'CONTA_POUPANCA')),
  add column if not exists onboarding_url text;

create unique index if not exists provider_asaas_accounts_wallet_id_idx
  on public.provider_asaas_accounts(wallet_id) where wallet_id is not null;

-- provider_iugu_withdrawals -> provider_asaas_withdrawals -----------------
-- No Asaas o saque É a transferência (não existe um id de "pedido" separado
-- do id da transfer); por isso guardamos direto o id da transferência.

alter table public.provider_iugu_withdrawals rename to provider_asaas_withdrawals;
alter table public.provider_asaas_withdrawals rename column iugu_withdrawal_id to asaas_transfer_id;

-- service_payment_charges: iugu_invoice_id/iugu_payment_id -> asaas_payment_id
-- O Asaas não distingue fatura vs. pagamento como a Iugu — a cobrança criada
-- em /v3/payments já É o id que confirmamos no webhook.

drop index if exists public.service_payment_charges_iugu_invoice_idx;
alter table public.service_payment_charges rename column iugu_invoice_id to asaas_payment_id;
alter table public.service_payment_charges drop column if exists iugu_payment_id;
alter table public.service_payment_charges add column if not exists asaas_end_to_end_id text;
-- Exposto ao app pra decidir entre "abrir o PIX no banco" e "simular
-- pagamento" (só sandbox) sem depender de um prefixo mágico no id, como
-- fazia o antigo IUGU_MOCK_*.
alter table public.service_payment_charges add column if not exists asaas_sandbox boolean not null default false;
create index if not exists service_payment_charges_asaas_payment_idx
  on public.service_payment_charges(asaas_payment_id) where asaas_payment_id is not null;

update public.service_payment_charges set payment_provider = 'asaas' where payment_provider = 'iugu';
alter table public.service_payment_charges alter column payment_provider set default 'asaas';
alter table public.service_payment_charges drop constraint if exists service_payment_charges_payment_provider_check;
alter table public.service_payment_charges
  add constraint service_payment_charges_payment_provider_check
  check (payment_provider in ('mercado_pago', 'asaas'));

-- service_provider_transfers: iugu_transfer_id -> asaas_transfer_id -------

alter table public.service_provider_transfers rename column iugu_transfer_id to asaas_transfer_id;

-- my_iugu_account_status -> my_asaas_account_status ----------------------

drop view if exists public.my_iugu_account_status;
create view public.my_asaas_account_status
with (security_invoker = false) as
select provider_id, asaas_account_id, wallet_id, status, verification_requested_at, verified_at, rejection_reason, onboarding_url
from public.provider_asaas_accounts
where provider_id = auth.uid();
grant select on public.my_asaas_account_status to authenticated;

-- Asaas exige um customer cadastrado (POST /customers) pra criar cobrança —
-- diferente da Iugu, que aceitava o pagador inline na fatura. Guardamos o id
-- pra reaproveitar entre chamados do mesmo motorista.
alter table public.profiles add column if not exists asaas_customer_id text;

-- Funções Iugu -> Asaas ----------------------------------------------------

drop function if exists public.mark_service_charge_iugu_checkout(uuid, text, text, text, timestamptz);
drop function if exists public.confirm_iugu_charge_payment(text, text);
drop function if exists public.begin_iugu_payment_release(uuid);
drop function if exists public.complete_iugu_payment_release_with_review(uuid, text, smallint, text);
drop function if exists public.mark_iugu_transfer_manual_review(uuid, text);
drop function if exists public.claim_iugu_provider_transfer(uuid);
drop function if exists public.claim_iugu_withdrawal(integer);

create or replace function public.mark_service_charge_asaas_checkout(
  p_charge_id uuid,
  p_asaas_payment_id text,
  p_pix_ticket_url text,
  p_pix_copy_paste text,
  p_expires_at timestamptz default null,
  p_asaas_sandbox boolean default false
)
returns void
language plpgsql security definer set search_path = public
as $$
declare current_requester_id uuid := auth.uid();
begin
  if current_requester_id is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  if nullif(trim(p_asaas_payment_id), '') is null or nullif(trim(p_pix_copy_paste), '') is null then
    raise exception 'Cobrança Asaas inválida.' using errcode = '22023';
  end if;
  update public.service_payment_charges c
  set status = 'awaiting_payment', payment_provider = 'asaas', asaas_payment_id = trim(p_asaas_payment_id),
    pix_ticket_url = nullif(trim(p_pix_ticket_url), ''), pix_copy_paste = trim(p_pix_copy_paste),
    pix_expires_at = p_expires_at, asaas_sandbox = p_asaas_sandbox
  where c.id = p_charge_id and c.status = 'pending'
    and exists (select 1 from public.service_requests r where r.id = c.request_id and r.requester_id = current_requester_id);
  if not found then raise exception 'Cobrança não disponível para pagamento.' using errcode = 'P0001'; end if;
end;
$$;

-- Executada somente pelo webhook autenticado do Asaas (asaas-webhook), nunca
-- pelo app.
create or replace function public.confirm_asaas_charge_payment(
  p_asaas_payment_id text,
  p_end_to_end_id text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare charge_row public.service_payment_charges; target_problem public.request_problem_type;
begin
  select * into charge_row from public.service_payment_charges c where c.asaas_payment_id = p_asaas_payment_id for update;
  if charge_row.id is null or charge_row.status = 'paid' then return; end if;
  if charge_row.status <> 'awaiting_payment' or charge_row.payment_provider <> 'asaas' then
    raise exception 'Cobrança não está aguardando confirmação Asaas.' using errcode = 'P0001';
  end if;
  update public.service_payment_charges
  set status = 'paid', asaas_end_to_end_id = nullif(trim(p_end_to_end_id), ''), paid_at = timezone('utc', now())
  where id = charge_row.id;
  insert into public.provider_wallet_entries (provider_id, request_id, charge_id, gross_amount_cents, provider_net_cents, status)
  values (charge_row.provider_id, charge_row.request_id, charge_row.id, charge_row.amount_cents, charge_row.amount_cents, 'held');
  if charge_row.kind = 'dispatch' then
    select problem_type into target_problem from public.service_requests where id = charge_row.request_id;
    update public.service_requests r set workflow_phase = case when target_problem in ('tire', 'towing') then 'service_released' else 'diagnosis' end,
      diagnostic_started_at = case when target_problem in ('tire', 'towing') then null else timezone('utc', now()) end,
      status = case when target_problem in ('tire', 'towing') then 'in_service' else 'provider_on_site' end
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_dispatch_payment';
  else
    update public.service_requests r set workflow_phase = 'service_released', status = 'in_service'
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_final_payment';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (charge_row.request_id, charge_row.provider_id, case when charge_row.kind = 'dispatch' and target_problem not in ('tire', 'towing') then 'provider_on_site' else 'in_service' end,
    case when charge_row.kind = 'dispatch' then 'Pagamento Asaas confirmado; valor retido até a conferência do motorista.' else 'Orçamento final pago pelo Asaas; valor retido até a conferência do motorista.' end);
end;
$$;

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
  if exists (select 1 from public.service_payment_charges where request_id = p_request_id and status <> 'paid') then
    raise exception 'Existem cobranças pendentes para este chamado.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.provider_asaas_accounts where provider_id = provider and status = 'verified') then
    raise exception 'O cadastro financeiro do prestador ainda não foi aprovado.' using errcode = 'P0001';
  end if;
  select * into transfer_row from public.service_provider_transfers where request_id = p_request_id for update;
  if transfer_row.id is not null then
    return query select transfer_row.id, transfer_row.provider_id, transfer_row.provider_net_cents;
    return;
  end if;
  select coalesce(sum(gross_amount_cents), 0) into gross from public.provider_wallet_entries
  where request_id = p_request_id and provider_id = provider and status = 'held';
  if gross <= 0 then raise exception 'Não há saldo retido para liberar.' using errcode = 'P0001'; end if;
  fee := (gross * 10) / 100;
  net := gross - fee;
  insert into public.service_provider_transfers (request_id, provider_id, gross_amount_cents, platform_fee_cents, provider_net_cents)
  values (p_request_id, provider, gross, fee, net) returning * into transfer_row;
  update public.service_requests set workflow_phase = 'release_processing' where id = p_request_id;
  return query select transfer_row.id, provider, net;
end;
$$;

-- Repassa o valor líquido do gross calculado a cada wallet_entry (arredondamento
-- por chamado, não por cobrança individual) e é idempotente + recalcula
-- average_rating — mesmo comportamento final que o fluxo Iugu tinha antes de
-- ser retirado (fix de Phase 5 aplicado direto aqui, sem passar pela versão
-- com o bug de arredondamento nem pela sem idempotência).
create or replace function public.complete_asaas_payment_release_with_review(
  p_transfer_id uuid, p_asaas_transfer_id text, p_rating smallint, p_comment text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare transfer_row public.service_provider_transfers; requester uuid; newest_entry_id uuid;
  fee_allocated integer; review_id uuid;
begin
  if p_rating not between 1 and 5 then raise exception 'A avaliação de 1 a 5 estrelas é obrigatória.' using errcode = '22023'; end if;
  select * into transfer_row from public.service_provider_transfers where id = p_transfer_id for update;
  if transfer_row.id is null then raise exception 'Liberação não encontrada.' using errcode = 'P0001'; end if;
  if transfer_row.status = 'completed' then return; end if;
  select requester_id into requester from public.service_requests where id = transfer_row.request_id;
  if requester is null then raise exception 'Chamado da liberação não encontrado.' using errcode = 'P0001'; end if;

  insert into public.reviews (request_id, reviewer_id, provider_id, rating, comment)
  values (transfer_row.request_id, requester, transfer_row.provider_id, p_rating, nullif(trim(p_comment), ''))
  on conflict (request_id) do nothing
  returning id into review_id;
  if review_id is null then return; end if;

  update public.service_provider_transfers set status = 'completed', asaas_transfer_id = nullif(trim(p_asaas_transfer_id), ''), completed_at = timezone('utc', now()) where id = p_transfer_id;

  select id into newest_entry_id from public.provider_wallet_entries
  where request_id = transfer_row.request_id and provider_id = transfer_row.provider_id and status = 'held'
  order by created_at desc limit 1;
  select coalesce(sum((gross_amount_cents * 10) / 100), 0) into fee_allocated
  from public.provider_wallet_entries
  where request_id = transfer_row.request_id and provider_id = transfer_row.provider_id
    and status = 'held' and id <> newest_entry_id;

  update public.provider_wallet_entries entry set status = 'available',
    platform_fee_cents = case when entry.id = newest_entry_id
      then transfer_row.platform_fee_cents - fee_allocated
      else (entry.gross_amount_cents * 10) / 100 end,
    provider_net_cents = entry.gross_amount_cents - (case when entry.id = newest_entry_id
      then transfer_row.platform_fee_cents - fee_allocated
      else (entry.gross_amount_cents * 10) / 100 end),
    released_at = timezone('utc', now())
  where entry.request_id = transfer_row.request_id and entry.provider_id = transfer_row.provider_id and entry.status = 'held';

  update public.service_requests set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
    driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now()) where id = transfer_row.request_id;
  update public.provider_profiles profile
  set completed_services = profile.completed_services + 1,
      average_rating = (select round(avg(review.rating)::numeric, 2)
                        from public.reviews review
                        where review.provider_id = transfer_row.provider_id)
  where profile.provider_id = transfer_row.provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (transfer_row.request_id, requester, 'completed', 'Motorista avaliou o prestador e autorizou o repasse Asaas de 90% do saldo.');
end;
$$;

create or replace function public.mark_asaas_transfer_manual_review(p_transfer_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$ begin
  update public.service_provider_transfers set status = 'manual_review', failure_reason = left(coalesce(p_reason, 'Falha desconhecida.'), 1000)
  where id = p_transfer_id and status = 'processing';
end; $$;

-- Retorna o walletId da subconta: é o destino do POST /transfers interno
-- (conta mestre -> subconta) que efetivamente libera o saldo retido.
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
  select wallet_id into account_wallet from public.provider_asaas_accounts
  where provider_id = transfer_row.provider_id and status = 'verified';
  if account_wallet is null then raise exception 'Subconta Asaas não verificada.' using errcode = 'P0001'; end if;
  update public.service_provider_transfers set status = 'processing', initiated_at = timezone('utc', now()) where id = p_transfer_id;
  return query select transfer_row.id, transfer_row.provider_net_cents, account_wallet;
end;
$$;

-- Retorna o necessário pra edge function decifrar a chave da subconta e
-- disparar o saque (POST /transfers assinado com a PRÓPRIA chave dela).
create or replace function public.claim_asaas_withdrawal(p_amount_cents integer)
returns table (
  withdrawal_id uuid, asaas_account_id text, api_key_ciphertext text, api_key_iv text,
  bank_code text, bank_agency text, bank_account text, bank_account_digit text, bank_account_type text
)
language plpgsql security definer set search_path = public
as $$
declare provider uuid := auth.uid(); available_cents integer; account public.provider_asaas_accounts; withdrawal public.provider_asaas_withdrawals;
begin
  if provider is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  if p_amount_cents is null or p_amount_cents < 500 then raise exception 'O saque mínimo é R$ 5,00.' using errcode = '22023'; end if;
  select coalesce(sum(provider_net_cents), 0) into available_cents from (
    select provider_net_cents from public.provider_wallet_entries
    where provider_id = provider and status = 'available' order by created_at for update
  ) available_entries;
  if p_amount_cents <> available_cents then raise exception 'Por segurança, o saque deve corresponder ao saldo disponível integral.' using errcode = '22023'; end if;
  select * into account from public.provider_asaas_accounts where provider_id = provider and status = 'verified';
  if account.asaas_account_id is null then raise exception 'Sua subconta Asaas ainda não está verificada.' using errcode = 'P0001'; end if;
  if account.bank_code is null then raise exception 'Cadastre uma conta bancária para receber o saque.' using errcode = 'P0001'; end if;
  insert into public.provider_asaas_withdrawals (provider_id, amount_cents, status) values (provider, p_amount_cents, 'requested') returning * into withdrawal;
  -- O pedido é registrado antes da chamada externa para impedir duplicidade concorrente.
  update public.provider_wallet_entries set status = 'payout_requested'
  where id in (select id from public.provider_wallet_entries where provider_id = provider and status = 'available' order by created_at for update);
  return query select withdrawal.id, account.asaas_account_id, account.api_key_ciphertext, account.api_key_iv,
    account.bank_code, account.bank_agency, account.bank_account, account.bank_account_digit, account.bank_account_type;
end;
$$;

revoke all on function public.mark_service_charge_asaas_checkout(uuid, text, text, text, timestamptz, boolean),
  public.confirm_asaas_charge_payment(text, text), public.begin_asaas_payment_release(uuid),
  public.complete_asaas_payment_release_with_review(uuid, text, smallint, text),
  public.mark_asaas_transfer_manual_review(uuid, text), public.claim_asaas_provider_transfer(uuid),
  public.claim_asaas_withdrawal(integer) from public;
grant execute on function public.mark_service_charge_asaas_checkout(uuid, text, text, text, timestamptz, boolean),
  public.begin_asaas_payment_release(uuid), public.claim_asaas_withdrawal(integer) to authenticated;
-- confirm_asaas_charge_payment, complete_asaas_payment_release_with_review,
-- mark_asaas_transfer_manual_review e claim_asaas_provider_transfer são
-- chamadas só pelas Edge Functions com a service role.
