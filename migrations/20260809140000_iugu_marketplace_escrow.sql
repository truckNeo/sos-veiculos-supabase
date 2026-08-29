-- Iugu Marketplace: cobrança integral na Conta Mestre, retenção e liberação
-- posterior para a subconta verificada do prestador.

alter type public.service_workflow_phase add value if not exists 'release_processing';
alter type public.service_workflow_phase add value if not exists 'in_dispute';
alter type public.service_request_status add value if not exists 'disputed';

create type public.iugu_account_status as enum (
  'not_started', 'verification_requested', 'verified', 'rejected', 'error'
);
create type public.iugu_transfer_status as enum (
  'pending', 'processing', 'completed', 'manual_review', 'failed'
);
create type public.service_dispute_status as enum ('open', 'provider_released', 'driver_refunded', 'cancelled');

grant usage on type public.iugu_account_status, public.iugu_transfer_status,
  public.service_dispute_status to authenticated;

alter table public.service_payment_charges
  add column iugu_invoice_id text unique,
  add column iugu_payment_id text,
  add column payment_provider text not null default 'mercado_pago'
    check (payment_provider in ('mercado_pago', 'iugu'));

alter table public.provider_wallet_entries
  add column platform_fee_cents integer not null default 0 check (platform_fee_cents >= 0),
  add column provider_net_cents integer not null default 0 check (provider_net_cents >= 0);

create table public.provider_iugu_accounts (
  provider_id uuid primary key references public.provider_profiles(provider_id) on delete cascade,
  iugu_account_id text unique,
  status public.iugu_account_status not null default 'not_started',
  verification_requested_at timestamptz,
  verified_at timestamptz,
  rejection_reason text,
  -- Cifra AES-GCM do live_api_token da subconta. Nunca é exposta ao app.
  withdraw_token_ciphertext text,
  withdraw_token_iv text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.service_provider_transfers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references public.service_requests(id) on delete restrict,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  gross_amount_cents integer not null check (gross_amount_cents > 0),
  platform_fee_cents integer not null check (platform_fee_cents >= 0),
  provider_net_cents integer not null check (provider_net_cents > 0),
  iugu_transfer_id text unique,
  status public.iugu_transfer_status not null default 'pending',
  initiated_at timestamptz,
  completed_at timestamptz,
  failure_reason text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  check (gross_amount_cents = platform_fee_cents + provider_net_cents)
);

create table public.service_disputes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references public.service_requests(id) on delete restrict,
  opened_by uuid not null references public.profiles(id) on delete restrict,
  reason text not null check (char_length(trim(reason)) between 10 and 2000),
  status public.service_dispute_status not null default 'open',
  decision_note text,
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.provider_iugu_withdrawals (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  amount_cents integer not null check (amount_cents >= 500),
  iugu_withdrawal_id text unique,
  status text not null check (status in ('requested', 'paid', 'failed', 'manual_review')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create index service_payment_charges_iugu_invoice_idx
  on public.service_payment_charges(iugu_invoice_id) where iugu_invoice_id is not null;
create index provider_iugu_withdrawals_provider_idx
  on public.provider_iugu_withdrawals(provider_id, created_at desc);

create trigger provider_iugu_accounts_set_updated_at before update on public.provider_iugu_accounts
  for each row execute function public.set_updated_at();
create trigger service_provider_transfers_set_updated_at before update on public.service_provider_transfers
  for each row execute function public.set_updated_at();
create trigger service_disputes_set_updated_at before update on public.service_disputes
  for each row execute function public.set_updated_at();
create trigger provider_iugu_withdrawals_set_updated_at before update on public.provider_iugu_withdrawals
  for each row execute function public.set_updated_at();

alter table public.provider_iugu_accounts enable row level security;
alter table public.service_provider_transfers enable row level security;
alter table public.service_disputes enable row level security;
alter table public.provider_iugu_withdrawals enable row level security;

create policy "provider can read own iugu transfer"
  on public.service_provider_transfers for select to authenticated using (provider_id = auth.uid());
create policy "driver can read own iugu transfer"
  on public.service_provider_transfers for select to authenticated using (exists (
    select 1 from public.service_requests r where r.id = request_id and r.requester_id = auth.uid()
  ));
create policy "parties can read dispute"
  on public.service_disputes for select to authenticated using (exists (
    select 1 from public.service_requests r
    where r.id = request_id and (r.requester_id = auth.uid() or r.selected_provider_id = auth.uid())
  ));
create policy "provider can read own withdrawals"
  on public.provider_iugu_withdrawals for select to authenticated using (provider_id = auth.uid());

revoke all on public.provider_iugu_accounts, public.service_provider_transfers,
  public.service_disputes, public.provider_iugu_withdrawals from authenticated;
grant select on public.service_provider_transfers, public.service_disputes,
  public.provider_iugu_withdrawals to authenticated;

create view public.my_iugu_account_status
with (security_invoker = true) as
select provider_id, iugu_account_id, status, verification_requested_at, verified_at, rejection_reason
from public.provider_iugu_accounts
where provider_id = auth.uid();
grant select on public.my_iugu_account_status to authenticated;

create or replace function public.mark_service_charge_iugu_checkout(
  p_charge_id uuid,
  p_iugu_invoice_id text,
  p_pix_ticket_url text,
  p_pix_copy_paste text,
  p_expires_at timestamptz default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare current_requester_id uuid := auth.uid();
begin
  if current_requester_id is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  if nullif(trim(p_iugu_invoice_id), '') is null or nullif(trim(p_pix_copy_paste), '') is null then
    raise exception 'Cobrança Iugu inválida.' using errcode = '22023';
  end if;
  update public.service_payment_charges c
  set status = 'awaiting_payment', payment_provider = 'iugu', iugu_invoice_id = trim(p_iugu_invoice_id),
    pix_ticket_url = nullif(trim(p_pix_ticket_url), ''), pix_copy_paste = trim(p_pix_copy_paste),
    pix_expires_at = p_expires_at
  where c.id = p_charge_id and c.status = 'pending'
    and exists (select 1 from public.service_requests r where r.id = c.request_id and r.requester_id = current_requester_id);
  if not found then raise exception 'Cobrança não disponível para pagamento.' using errcode = 'P0001'; end if;
end;
$$;

create or replace function public.confirm_iugu_charge_payment(
  p_iugu_invoice_id text,
  p_iugu_payment_id text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare charge_row public.service_payment_charges; target_problem public.request_problem_type;
begin
  select * into charge_row from public.service_payment_charges c where c.iugu_invoice_id = p_iugu_invoice_id for update;
  if charge_row.id is null or charge_row.status = 'paid' then return; end if;
  if charge_row.status <> 'awaiting_payment' or charge_row.payment_provider <> 'iugu' then
    raise exception 'Cobrança não está aguardando confirmação Iugu.' using errcode = 'P0001';
  end if;
  update public.service_payment_charges set status = 'paid', iugu_payment_id = nullif(trim(p_iugu_payment_id), ''), paid_at = timezone('utc', now()) where id = charge_row.id;
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
    case when charge_row.kind = 'dispatch' then 'Pagamento Iugu confirmado; valor retido até a conferência do motorista.' else 'Orçamento final pago pela Iugu; valor retido até a conferência do motorista.' end);
end;
$$;

create or replace function public.begin_iugu_payment_release(p_request_id uuid)
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
  if not exists (select 1 from public.provider_iugu_accounts where provider_id = provider and status = 'verified') then
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

create or replace function public.complete_iugu_payment_release_with_review(
  p_transfer_id uuid, p_iugu_transfer_id text, p_rating smallint, p_comment text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare transfer_row public.service_provider_transfers; requester uuid;
begin
  if p_rating not between 1 and 5 then raise exception 'A avaliação de 1 a 5 estrelas é obrigatória.' using errcode = '22023'; end if;
  select * into transfer_row from public.service_provider_transfers where id = p_transfer_id for update;
  if transfer_row.id is null then raise exception 'Liberação não encontrada.' using errcode = 'P0001'; end if;
  select requester_id into requester from public.service_requests where id = transfer_row.request_id;
  insert into public.reviews (request_id, reviewer_id, provider_id, rating, comment)
  values (transfer_row.request_id, requester, transfer_row.provider_id, p_rating, nullif(trim(p_comment), ''))
  on conflict (request_id) do nothing;
  update public.service_provider_transfers set status = 'completed', iugu_transfer_id = nullif(trim(p_iugu_transfer_id), ''), completed_at = timezone('utc', now()) where id = p_transfer_id;
  update public.provider_wallet_entries set status = 'available', platform_fee_cents = (gross_amount_cents * 10) / 100,
    provider_net_cents = gross_amount_cents - ((gross_amount_cents * 10) / 100), released_at = timezone('utc', now())
  where request_id = transfer_row.request_id and provider_id = transfer_row.provider_id and status = 'held';
  update public.service_requests set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
    driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now()) where id = transfer_row.request_id;
  update public.provider_profiles set completed_services = completed_services + 1 where provider_id = transfer_row.provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (transfer_row.request_id, requester, 'completed', 'Motorista avaliou o prestador e autorizou o repasse Iugu de 90% do saldo.');
end;
$$;

create or replace function public.mark_iugu_transfer_manual_review(p_transfer_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$ begin
  update public.service_provider_transfers set status = 'manual_review', failure_reason = left(coalesce(p_reason, 'Falha desconhecida.'), 1000)
  where id = p_transfer_id and status = 'processing';
end; $$;

create or replace function public.claim_iugu_provider_transfer(p_transfer_id uuid)
returns table (transfer_id uuid, provider_net_cents integer, iugu_account_id text)
language plpgsql security definer set search_path = public
as $$
declare transfer_row public.service_provider_transfers; account_id text;
begin
  select * into transfer_row from public.service_provider_transfers where id = p_transfer_id for update;
  if transfer_row.id is null then raise exception 'Liberação não encontrada.' using errcode = 'P0001'; end if;
  if transfer_row.status = 'completed' then return; end if;
  if transfer_row.status <> 'pending' then raise exception 'A liberação já está em processamento e será revisada pela equipe.' using errcode = 'P0001'; end if;
  select iugu_account_id into account_id from public.provider_iugu_accounts
  where provider_id = transfer_row.provider_id and status = 'verified';
  if account_id is null then raise exception 'Subconta Iugu não verificada.' using errcode = 'P0001'; end if;
  update public.service_provider_transfers set status = 'processing', initiated_at = timezone('utc', now()) where id = p_transfer_id;
  return query select transfer_row.id, transfer_row.provider_net_cents, account_id;
end;
$$;

create or replace function public.claim_iugu_withdrawal(p_amount_cents integer)
returns table (withdrawal_id uuid, iugu_account_id text)
language plpgsql security definer set search_path = public
as $$
declare provider uuid := auth.uid(); available_cents integer; account_id text; withdrawal public.provider_iugu_withdrawals;
begin
  if provider is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  if p_amount_cents is null or p_amount_cents < 500 then raise exception 'O saque mínimo é R$ 5,00.' using errcode = '22023'; end if;
  select coalesce(sum(provider_net_cents), 0) into available_cents from (
    select provider_net_cents from public.provider_wallet_entries
    where provider_id = provider and status = 'available' order by created_at for update
  ) available_entries;
  if p_amount_cents <> available_cents then raise exception 'Por segurança, o saque deve corresponder ao saldo disponível integral.' using errcode = '22023'; end if;
  select iugu_account_id into account_id from public.provider_iugu_accounts where provider_id = provider and status = 'verified';
  if account_id is null then raise exception 'Sua subconta Iugu ainda não está verificada.' using errcode = 'P0001'; end if;
  insert into public.provider_iugu_withdrawals (provider_id, amount_cents, status) values (provider, p_amount_cents, 'requested') returning * into withdrawal;
  -- O pedido é registrado antes da chamada externa para impedir duplicidade concorrente.
  update public.provider_wallet_entries set status = 'payout_requested'
  where id in (select id from public.provider_wallet_entries where provider_id = provider and status = 'available' order by created_at for update);
  return query select withdrawal.id, account_id;
end;
$$;

create or replace function public.open_service_dispute(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
declare requester uuid := auth.uid();
begin
  if nullif(trim(p_reason), '') is null or char_length(trim(p_reason)) < 10 then raise exception 'Descreva o problema com ao menos 10 caracteres.' using errcode = '22023'; end if;
  update public.service_requests set workflow_phase = 'in_dispute', status = 'disputed'
  where id = p_request_id and requester_id = requester and workflow_phase = 'awaiting_driver_confirmation';
  if not found then raise exception 'Este atendimento não pode abrir disputa neste momento.' using errcode = 'P0001'; end if;
  insert into public.service_disputes (request_id, opened_by, reason) values (p_request_id, requester, trim(p_reason));
  insert into public.service_request_events (request_id, actor_id, status, note) values (p_request_id, requester, 'disputed', 'Motorista abriu uma disputa antes da liberação financeira.');
end;
$$;

revoke all on function public.mark_service_charge_iugu_checkout(uuid, text, text, text, timestamptz),
  public.confirm_iugu_charge_payment(text, text), public.begin_iugu_payment_release(uuid),
  public.complete_iugu_payment_release_with_review(uuid, text, smallint, text),
  public.mark_iugu_transfer_manual_review(uuid, text), public.claim_iugu_provider_transfer(uuid),
  public.claim_iugu_withdrawal(integer), public.open_service_dispute(uuid, text) from public;
grant execute on function public.mark_service_charge_iugu_checkout(uuid, text, text, text, timestamptz),
  public.begin_iugu_payment_release(uuid), public.claim_iugu_withdrawal(integer),
  public.open_service_dispute(uuid, text) to authenticated;
