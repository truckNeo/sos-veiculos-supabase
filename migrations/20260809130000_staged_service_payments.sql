-- Fluxo em etapas: deslocamento, diagnóstico, orçamento final, execução,
-- aceite do motorista, liberação de saldo e avaliação obrigatória.

alter type public.request_problem_type add value if not exists 'suspension';
alter type public.request_problem_type add value if not exists 'cooling';
alter type public.request_problem_type add value if not exists 'bodywork';
alter type public.request_problem_type add value if not exists 'towing';

create type public.service_workflow_phase as enum (
  'open',
  'awaiting_dispatch_payment',
  'diagnosis',
  'awaiting_final_payment',
  'service_released',
  'awaiting_driver_confirmation',
  'completed',
  'cancelled'
);

create type public.service_charge_kind as enum ('dispatch', 'final');
create type public.service_charge_status as enum ('pending', 'awaiting_payment', 'paid', 'cancelled', 'expired');
create type public.wallet_entry_status as enum ('held', 'available', 'payout_requested', 'paid_out', 'reversed');

grant usage on type public.service_workflow_phase, public.service_charge_kind,
  public.service_charge_status, public.wallet_entry_status to authenticated;

alter table public.service_requests
  add column workflow_phase public.service_workflow_phase not null default 'open',
  add column selected_provider_id uuid references public.provider_profiles(provider_id) on delete restrict,
  add column diagnostic_started_at timestamptz,
  add column service_completed_at timestamptz,
  add column driver_confirmed_at timestamptz,
  add column payment_released_at timestamptz;

alter table public.provider_offers
  add column other_fee_cents integer not null default 0 check (other_fee_cents >= 0),
  add column diagnosis_notes text,
  add column final_quoted_at timestamptz;

create table public.service_payment_charges (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete cascade,
  offer_id uuid not null references public.provider_offers(id) on delete restrict,
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  kind public.service_charge_kind not null,
  amount_cents integer not null check (amount_cents > 0),
  status public.service_charge_status not null default 'pending',
  mercado_pago_order_id text unique,
  mercado_pago_payment_id text,
  pix_ticket_url text,
  pix_copy_paste text,
  pix_expires_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  unique (request_id, kind)
);

create table public.provider_wallet_entries (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.provider_profiles(provider_id) on delete restrict,
  request_id uuid not null references public.service_requests(id) on delete restrict,
  charge_id uuid not null unique references public.service_payment_charges(id) on delete restrict,
  gross_amount_cents integer not null check (gross_amount_cents > 0),
  status public.wallet_entry_status not null default 'held',
  released_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table public.provider_mercadopago_accounts (
  provider_id uuid primary key references public.provider_profiles(provider_id) on delete cascade,
  mercado_pago_user_id text unique,
  split_enabled boolean not null default false,
  connected_at timestamptz,
  updated_at timestamptz not null default timezone('utc', now())
);

create index service_requests_selected_provider_idx on public.service_requests(selected_provider_id);
create index service_payment_charges_request_idx on public.service_payment_charges(request_id, created_at desc);
create index service_payment_charges_marketplace_order_idx on public.service_payment_charges(mercado_pago_order_id) where mercado_pago_order_id is not null;
create index provider_wallet_entries_provider_idx on public.provider_wallet_entries(provider_id, status, created_at desc);

create trigger service_payment_charges_set_updated_at before update on public.service_payment_charges
  for each row execute function public.set_updated_at();
create trigger provider_wallet_entries_set_updated_at before update on public.provider_wallet_entries
  for each row execute function public.set_updated_at();
create trigger provider_mercadopago_accounts_set_updated_at before update on public.provider_mercadopago_accounts
  for each row execute function public.set_updated_at();

alter table public.service_payment_charges enable row level security;
alter table public.provider_wallet_entries enable row level security;
alter table public.provider_mercadopago_accounts enable row level security;

-- Somente o motorista pode ver o QR/copia-e-cola; o prestador vê o saldo por RPC.
create policy "requester can read own payment charges"
  on public.service_payment_charges for select to authenticated
  using (exists (
    select 1 from public.service_requests request_row
    where request_row.id = service_payment_charges.request_id
      and request_row.requester_id = auth.uid()
  ));
create policy "provider can read own wallet entries"
  on public.provider_wallet_entries for select to authenticated
  using (provider_id = auth.uid());
create policy "provider can read own mercado pago account"
  on public.provider_mercadopago_accounts for select to authenticated
  using (provider_id = auth.uid());

revoke all on public.service_payment_charges, public.provider_wallet_entries,
  public.provider_mercadopago_accounts from authenticated;
grant select on public.service_payment_charges, public.provider_wallet_entries,
  public.provider_mercadopago_accounts to authenticated;

drop policy "requester can create review after service" on public.reviews;
revoke insert on public.reviews from authenticated;

-- A proposta inicial contém exclusivamente deslocamento. Mão de obra, peças e
-- outros valores só podem ser incluídos após o diagnóstico.
create or replace function public.submit_provider_dispatch_offer(
  p_request_id uuid,
  p_travel_fee_cents integer,
  p_estimated_arrival_minutes integer,
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
  target_workflow_phase public.service_workflow_phase;
  target_problem public.request_problem_type;
  target_location extensions.geography;
  provider_location extensions.geography;
  provider_location_updated_at timestamptz;
  provider_radius_meters integer;
  created_offer public.provider_offers;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if p_travel_fee_cents is null or p_travel_fee_cents <= 0 then
    raise exception 'Informe uma taxa de deslocamento maior que zero.' using errcode = '22023';
  end if;
  if p_estimated_arrival_minutes is null or p_estimated_arrival_minutes not between 1 and 1440 then
    raise exception 'Informe uma previsão de chegada entre 1 e 1440 minutos.' using errcode = '22023';
  end if;
  if p_notes is not null and char_length(trim(p_notes)) > 1000 then
    raise exception 'As observações podem ter no máximo 1000 caracteres.' using errcode = '22023';
  end if;

  select request_row.status, request_row.workflow_phase, request_row.problem_type, request_row.location
  into target_request_status, target_workflow_phase, target_problem, target_location
  from public.service_requests request_row
  where request_row.id = p_request_id
  for update;
  if target_request_status is null then
    raise exception 'Chamado não encontrado.' using errcode = 'P0001';
  end if;
  if target_workflow_phase <> 'open' or target_request_status not in ('open', 'collecting_offers') then
    raise exception 'Este chamado não está aceitando deslocamentos.' using errcode = 'P0001';
  end if;

  select location_row.location, location_row.updated_at, provider.service_radius_km * 1000
  into provider_location, provider_location_updated_at, provider_radius_meters
  from public.provider_profiles provider
  join public.provider_locations location_row on location_row.provider_id = provider.provider_id
  where provider.provider_id = current_provider_id and provider.is_available;
  if provider_location is null or provider_location_updated_at < now() - interval '15 minutes' then
    raise exception 'Atualize sua localização e disponibilidade antes de enviar propostas.' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.provider_services service
    where service.provider_id = current_provider_id and service.problem_type = target_problem
  ) then
    raise exception 'Seu perfil não atende este tipo de chamado.' using errcode = 'P0001';
  end if;
  if not extensions.st_dwithin(target_location, provider_location, provider_radius_meters) then
    raise exception 'Este chamado está fora do seu raio de atendimento.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.provider_offers offer
    where offer.request_id = p_request_id and offer.provider_id = current_provider_id
  ) then
    raise exception 'Você já enviou uma taxa de deslocamento para este chamado.' using errcode = '23505';
  end if;

  insert into public.provider_offers (
    request_id, provider_id, travel_fee_cents, labor_fee_cents,
    estimated_arrival_minutes, notes, status
  ) values (
    p_request_id, current_provider_id, p_travel_fee_cents, 0,
    p_estimated_arrival_minutes, nullif(trim(p_notes), ''), 'submitted'
  ) returning * into created_offer;

  update public.service_requests as request_row
  set status = 'collecting_offers'
  where request_row.id = p_request_id and request_row.status = 'open';
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_provider_id, 'collecting_offers', 'Taxa de deslocamento enviada pelo prestador.');

  return query select created_offer.id, created_offer.request_id, created_offer.provider_id,
    created_offer.status, created_offer.created_at;
end;
$$;

-- O motorista escolhe um prestador e cria uma cobrança pendente. A Edge
-- Function é a única responsável por gerar o PIX no Mercado Pago.
create or replace function public.select_dispatch_offer(
  p_offer_id uuid
)
returns table (
  charge_id uuid,
  amount_cents integer,
  provider_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
  target_request_id uuid;
  target_requester_id uuid;
  target_phase public.service_workflow_phase;
  target_offer_status public.offer_status;
  target_provider_id uuid;
  target_travel_fee integer;
  created_charge public.service_payment_charges;
begin
  if current_requester_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  select offer.request_id, request_row.requester_id, request_row.workflow_phase,
    offer.status, offer.provider_id, offer.travel_fee_cents
  into target_request_id, target_requester_id, target_phase, target_offer_status,
    target_provider_id, target_travel_fee
  from public.provider_offers offer
  join public.service_requests request_row on request_row.id = offer.request_id
  where offer.id = p_offer_id
  for update of offer, request_row;
  if target_request_id is null or target_requester_id <> current_requester_id then
    raise exception 'Proposta não encontrada ou sem permissão.' using errcode = '42501';
  end if;
  if target_phase <> 'open' or target_offer_status <> 'submitted' then
    raise exception 'Esta taxa de deslocamento não está disponível.' using errcode = 'P0001';
  end if;

  update public.provider_offers
  set status = case when id = p_offer_id then 'accepted' else 'rejected' end
  where request_id = target_request_id and status = 'submitted';
  update public.service_requests as request_row
  set status = 'offer_accepted', workflow_phase = 'awaiting_dispatch_payment',
    selected_provider_id = target_provider_id
  where request_row.id = target_request_id;
  insert into public.service_payment_charges (request_id, offer_id, provider_id, kind, amount_cents)
  values (target_request_id, p_offer_id, target_provider_id, 'dispatch', target_travel_fee)
  returning * into created_charge;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (target_request_id, current_requester_id, 'offer_accepted', 'Prestador selecionado; aguardando pagamento do deslocamento.');

  return query select created_charge.id, created_charge.amount_cents, target_provider_id;
end;
$$;

create or replace function public.mark_service_charge_checkout(
  p_charge_id uuid,
  p_mercado_pago_order_id text,
  p_pix_ticket_url text,
  p_pix_copy_paste text,
  p_expires_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
begin
  if current_requester_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if p_mercado_pago_order_id is null or char_length(trim(p_mercado_pago_order_id)) < 4 then
    raise exception 'Cobrança do Mercado Pago inválida.' using errcode = '22023';
  end if;
  update public.service_payment_charges charge
  set status = 'awaiting_payment', mercado_pago_order_id = p_mercado_pago_order_id,
    pix_ticket_url = nullif(trim(p_pix_ticket_url), ''),
    pix_copy_paste = nullif(trim(p_pix_copy_paste), ''), pix_expires_at = p_expires_at
  where charge.id = p_charge_id
    and charge.status = 'pending'
    and exists (
      select 1 from public.service_requests request_row
      where request_row.id = charge.request_id and request_row.requester_id = current_requester_id
    );
  if not found then
    raise exception 'Cobrança não disponível para pagamento.' using errcode = 'P0001';
  end if;
end;
$$;

-- Executada somente pelo webhook autenticado do Mercado Pago através de uma
-- chave secreta da Edge Function; nunca pelo aplicativo.
create or replace function public.confirm_service_charge_payment(
  p_mercado_pago_order_id text,
  p_mercado_pago_payment_id text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  charge_row public.service_payment_charges;
  target_problem public.request_problem_type;
begin
  select * into charge_row
  from public.service_payment_charges charge
  where charge.mercado_pago_order_id = p_mercado_pago_order_id
  for update;
  if charge_row.id is null or charge_row.status = 'paid' then
    return;
  end if;
  if charge_row.status <> 'awaiting_payment' then
    raise exception 'Cobrança não está aguardando pagamento.' using errcode = 'P0001';
  end if;
  update public.service_payment_charges
  set status = 'paid', mercado_pago_payment_id = nullif(trim(p_mercado_pago_payment_id), ''),
    paid_at = timezone('utc', now())
  where id = charge_row.id;
  insert into public.provider_wallet_entries (provider_id, request_id, charge_id, gross_amount_cents, status)
  values (charge_row.provider_id, charge_row.request_id, charge_row.id, charge_row.amount_cents, 'held');

  if charge_row.kind = 'dispatch' then
    select problem_type into target_problem from public.service_requests where id = charge_row.request_id;
    update public.service_requests as request_row
    set workflow_phase = case when target_problem in ('tire', 'towing') then 'service_released' else 'diagnosis' end,
      diagnostic_started_at = case when target_problem in ('tire', 'towing') then null else timezone('utc', now()) end,
      status = case when target_problem in ('tire', 'towing') then 'in_service' else 'provider_on_site' end
    where request_row.id = charge_row.request_id and request_row.workflow_phase = 'awaiting_dispatch_payment';
    insert into public.service_request_events (request_id, actor_id, status, note)
    values (charge_row.request_id, charge_row.provider_id,
      case when target_problem in ('tire', 'towing') then 'in_service' else 'provider_on_site' end,
      case when target_problem in ('tire', 'towing') then 'Deslocamento pago; serviço liberado.' else 'Deslocamento pago; diagnóstico autorizado.' end);
  else
    update public.service_requests as request_row
    set workflow_phase = 'service_released', status = 'in_service'
    where request_row.id = charge_row.request_id and request_row.workflow_phase = 'awaiting_final_payment';
    insert into public.service_request_events (request_id, actor_id, status, note)
    values (charge_row.request_id, charge_row.provider_id, 'in_service', 'Orçamento final pago; serviço liberado.');
  end if;
end;
$$;

create or replace function public.submit_final_service_quote(
  p_request_id uuid,
  p_labor_fee_cents integer,
  p_parts_estimate_cents integer default 0,
  p_other_fee_cents integer default 0,
  p_notes text default null
)
returns table (charge_id uuid, amount_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  current_provider_id uuid := auth.uid();
  target_provider_id uuid;
  target_phase public.service_workflow_phase;
  target_offer_id uuid;
  created_charge public.service_payment_charges;
  total_cents integer;
begin
  if current_provider_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if p_labor_fee_cents is null or p_labor_fee_cents < 0
    or p_parts_estimate_cents is null or p_parts_estimate_cents < 0
    or p_other_fee_cents is null or p_other_fee_cents < 0 then
    raise exception 'Os valores do orçamento não podem ser negativos.' using errcode = '22023';
  end if;
  total_cents := p_labor_fee_cents + p_parts_estimate_cents + p_other_fee_cents;
  if total_cents <= 0 then
    raise exception 'Informe ao menos um valor no orçamento final.' using errcode = '22023';
  end if;
  if p_notes is not null and char_length(trim(p_notes)) > 2000 then
    raise exception 'O diagnóstico pode ter no máximo 2000 caracteres.' using errcode = '22023';
  end if;
  select request_row.selected_provider_id, request_row.workflow_phase, offer.id
  into target_provider_id, target_phase, target_offer_id
  from public.service_requests request_row
  join public.provider_offers offer on offer.request_id = request_row.id
    and offer.provider_id = request_row.selected_provider_id and offer.status = 'accepted'
  where request_row.id = p_request_id
  for update of request_row, offer;
  if target_provider_id <> current_provider_id then
    raise exception 'Somente o prestador selecionado pode enviar o orçamento final.' using errcode = '42501';
  end if;
  if target_phase <> 'diagnosis' then
    raise exception 'O diagnóstico ainda não está liberado para orçamento final.' using errcode = 'P0001';
  end if;
  update public.provider_offers
  set labor_fee_cents = p_labor_fee_cents, parts_estimate_cents = p_parts_estimate_cents,
    other_fee_cents = p_other_fee_cents, diagnosis_notes = nullif(trim(p_notes), ''),
    final_quoted_at = timezone('utc', now())
  where id = target_offer_id;
  insert into public.service_payment_charges (request_id, offer_id, provider_id, kind, amount_cents)
  values (p_request_id, target_offer_id, current_provider_id, 'final', total_cents)
  returning * into created_charge;
  update public.service_requests as request_row
  set workflow_phase = 'awaiting_final_payment'
  where request_row.id = p_request_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_provider_id, 'offer_accepted', 'Diagnóstico concluído; aguardando pagamento do orçamento final.');
  return query select created_charge.id, created_charge.amount_cents;
end;
$$;

create or replace function public.mark_service_completed(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_provider_id uuid := auth.uid();
begin
  update public.service_requests as request_row
  set workflow_phase = 'awaiting_driver_confirmation', service_completed_at = timezone('utc', now())
  where request_row.id = p_request_id
    and request_row.selected_provider_id = current_provider_id
    and request_row.workflow_phase = 'service_released';
  if not found then
    raise exception 'Este serviço não está disponível para conclusão.' using errcode = 'P0001';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_provider_id, 'in_service', 'Prestador informou que o serviço está pronto para conferência.');
end;
$$;

-- A avaliação é obrigatória e inserida na mesma transação que libera o saldo.
create or replace function public.release_service_payment_with_review(
  p_request_id uuid,
  p_rating smallint,
  p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_requester_id uuid := auth.uid();
  target_provider_id uuid;
  target_phase public.service_workflow_phase;
begin
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'A avaliação de 1 a 5 estrelas é obrigatória.' using errcode = '22023';
  end if;
  if p_comment is not null and char_length(trim(p_comment)) > 1000 then
    raise exception 'O comentário pode ter no máximo 1000 caracteres.' using errcode = '22023';
  end if;
  select request_row.selected_provider_id, request_row.workflow_phase
  into target_provider_id, target_phase
  from public.service_requests request_row
  where request_row.id = p_request_id and request_row.requester_id = current_requester_id
  for update;
  if target_provider_id is null then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode = '42501';
  end if;
  if target_phase <> 'awaiting_driver_confirmation' then
    raise exception 'O serviço ainda não está aguardando sua conferência.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.service_payment_charges charge
    where charge.request_id = p_request_id and charge.status <> 'paid'
  ) then
    raise exception 'Existem cobranças pendentes para este chamado.' using errcode = 'P0001';
  end if;
  insert into public.reviews (request_id, reviewer_id, provider_id, rating, comment)
  values (p_request_id, current_requester_id, target_provider_id, p_rating, nullif(trim(p_comment), ''));
  update public.provider_wallet_entries
  set status = 'available', released_at = timezone('utc', now())
  where request_id = p_request_id and provider_id = target_provider_id and status = 'held';
  update public.service_requests as request_row
  set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
    driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now())
  where request_row.id = p_request_id;
  update public.provider_profiles
  set completed_services = completed_services + 1
  where provider_id = target_provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_requester_id, 'completed', 'Motorista conferiu o serviço, avaliou o prestador e liberou o pagamento.');
end;
$$;

revoke all on function public.submit_provider_dispatch_offer(uuid, integer, integer, text) from public;
revoke all on function public.select_dispatch_offer(uuid) from public;
revoke all on function public.mark_service_charge_checkout(uuid, text, text, text, timestamptz) from public;
revoke all on function public.confirm_service_charge_payment(text, text) from public;
revoke all on function public.submit_final_service_quote(uuid, integer, integer, integer, text) from public;
revoke all on function public.mark_service_completed(uuid) from public;
revoke all on function public.release_service_payment_with_review(uuid, smallint, text) from public;
grant execute on function public.submit_provider_dispatch_offer(uuid, integer, integer, text) to authenticated;
grant execute on function public.select_dispatch_offer(uuid) to authenticated;
grant execute on function public.mark_service_charge_checkout(uuid, text, text, text, timestamptz) to authenticated;
grant execute on function public.submit_final_service_quote(uuid, integer, integer, integer, text) to authenticated;
grant execute on function public.mark_service_completed(uuid) to authenticated;
grant execute on function public.release_service_payment_with_review(uuid, smallint, text) to authenticated;
