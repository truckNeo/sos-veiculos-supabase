-- Fase 2a: a taxa de deslocamento do agendamento vira uma cobrança Asaas.
-- Cobrança, saldo da carteira e repasse passam a pertencer a um chamado OU a um agendamento.

alter table public.service_payment_charges
  alter column request_id drop not null,
  alter column offer_id drop not null,
  add column appointment_id uuid references public.service_appointments(id) on delete restrict;
alter table public.service_payment_charges
  add constraint service_payment_charges_owner_check check (num_nonnulls(request_id, appointment_id) = 1),
  add constraint service_payment_charges_appointment_offer_check check (appointment_id is null or offer_id is null);
create unique index service_payment_charges_appointment_kind_key
  on public.service_payment_charges(appointment_id, kind) where appointment_id is not null;

alter table public.provider_wallet_entries
  alter column request_id drop not null,
  add column appointment_id uuid references public.service_appointments(id) on delete restrict;
alter table public.provider_wallet_entries
  add constraint provider_wallet_entries_owner_check check (num_nonnulls(request_id, appointment_id) = 1);

alter table public.service_provider_transfers
  alter column request_id drop not null,
  add column appointment_id uuid references public.service_appointments(id) on delete restrict;
alter table public.service_provider_transfers
  add constraint service_provider_transfers_owner_check check (num_nonnulls(request_id, appointment_id) = 1);
create unique index service_provider_transfers_appointment_key
  on public.service_provider_transfers(appointment_id) where appointment_id is not null;

alter table public.service_appointments
  add column fee_charge_id uuid references public.service_payment_charges(id) on delete set null,
  add column payment_due_at timestamptz,
  add column fee_paid_at timestamptz,
  add column fee_released_at timestamptz,
  add column fee_refunded_at timestamptz;

create policy "driver can read own appointment charges" on public.service_payment_charges for select
  using (exists (select 1 from public.service_appointments a where a.id = service_payment_charges.appointment_id and a.requester_id = auth.uid()));
create policy "driver can read own appointment transfer" on public.service_provider_transfers for select
  using (exists (select 1 from public.service_appointments a where a.id = service_provider_transfers.appointment_id and a.requester_id = auth.uid()));

-- Confirmar com taxa cria a cobrança e fixa o prazo de pagamento.
create or replace function public.confirm_service_appointment(p_id uuid, p_travel_fee_cents integer default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments; due timestamptz; charge uuid;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.service_mode in ('onsite','pickup') then
    if p_travel_fee_cents is null or p_travel_fee_cents not between 100 and 1000000 then
      raise exception 'Informe a taxa de deslocamento (de R$ 1,00 a R$ 10.000,00).' using errcode = 'P0001'; end if;
    if not exists (select 1 from public.provider_asaas_accounts pa where pa.provider_id = a.provider_id and pa.status = 'verified') then
      raise exception 'Conclua seu cadastro financeiro para cobrar a taxa de deslocamento.' using errcode = 'P0001'; end if;
    due := least(now() + interval '12 hours', a.starts_at - interval '2 hours');
    if due < now() + interval '15 minutes' then
      raise exception 'O horário está próximo demais para cobrar a taxa de deslocamento.' using errcode = 'P0001'; end if;
    update public.service_appointments set travel_fee_cents = p_travel_fee_cents where id = a.id;
  end if;
  perform public.respond_service_appointment(p_id, 'confirmed');
  if a.service_mode in ('onsite','pickup') then
    insert into public.service_payment_charges(appointment_id, provider_id, kind, amount_cents, status, payment_provider)
    values (a.id, a.provider_id, 'dispatch', p_travel_fee_cents, 'pending', 'asaas')
    on conflict (appointment_id, kind) where appointment_id is not null
    do update set amount_cents = excluded.amount_cents where service_payment_charges.status = 'pending'
    returning id into charge;
    update public.service_appointments set fee_charge_id = charge, payment_due_at = due where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'fee-due', 'Pague a taxa de deslocamento',
      'Pague R$ ' || replace(to_char(p_travel_fee_cents / 100.0, 'FM999999990.00'), '.', ',') || ' até '
      || to_char(due at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || ' para garantir o agendamento.');
  end if;
end $$;

-- A taxa só pode ser cobrada do dono do agendamento, dentro do prazo.
create or replace function public.claim_asaas_charge_checkout(p_charge_id uuid, p_requester_id uuid, p_sandbox boolean)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare target_request public.service_requests; target_appointment public.service_appointments;
begin
  if exists (select 1 from public.service_payment_charges c where c.id = p_charge_id and c.appointment_id is not null) then
    select a.* into target_appointment from public.service_appointments a
    join public.service_payment_charges c on c.appointment_id = a.id
    where c.id = p_charge_id and a.requester_id = p_requester_id for update of a;
    if target_appointment.id is null then raise exception 'Cobrança não encontrada ou sem permissão.' using errcode = '42501'; end if;
    if target_appointment.status <> 'confirmed' then raise exception 'O agendamento não está disponível para pagamento.'; end if;
    if target_appointment.payment_due_at is null or now() > target_appointment.payment_due_at then
      raise exception 'O prazo para pagar a taxa terminou.'; end if;
  else
    select r.* into target_request from public.service_requests r
    join public.service_payment_charges c on c.request_id = r.id
    where c.id = p_charge_id and r.requester_id = p_requester_id for update of r;
    if target_request.id is null then raise exception 'Cobrança não encontrada ou sem permissão.' using errcode = '42501'; end if;
    if target_request.status <> 'offer_accepted' or target_request.workflow_phase <> 'awaiting_dispatch_payment' then
      raise exception 'O chamado não está disponível para emitir PIX.';
    end if;
  end if;
  update public.service_payment_charges set asaas_checkout_claimed_at = now(), asaas_sandbox = p_sandbox
  where id = p_charge_id and kind = 'dispatch' and status = 'pending' and asaas_checkout_claimed_at is null;
  return found;
end $$;

create or replace function public.mark_service_charge_asaas_checkout(p_charge_id uuid, p_asaas_payment_id text, p_pix_ticket_url text, p_pix_copy_paste text, p_expires_at timestamptz default null, p_asaas_sandbox boolean default false)
returns void language plpgsql security definer set search_path to 'public' as $$
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
    and (exists (select 1 from public.service_requests r where r.id = c.request_id and r.requester_id = current_requester_id)
      or exists (select 1 from public.service_appointments a where a.id = c.appointment_id and a.requester_id = current_requester_id));
  if not found then raise exception 'Cobrança não disponível para pagamento.' using errcode = 'P0001'; end if;
end $$;

-- Pagamento confirmado: saldo retido e agendamento marcado como pago.
create or replace function public.confirm_asaas_charge_payment(p_asaas_payment_id text, p_end_to_end_id text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare charge_row public.service_payment_charges; target_problem public.request_problem_type; appointment_row public.service_appointments;
begin
  select * into charge_row from public.service_payment_charges c where c.asaas_payment_id = p_asaas_payment_id for update;
  if charge_row.id is null or charge_row.status = 'paid' then return; end if;
  if charge_row.status <> 'awaiting_payment' or charge_row.payment_provider <> 'asaas' then
    raise exception 'Cobrança não está aguardando confirmação Asaas.' using errcode = 'P0001';
  end if;
  update public.service_payment_charges
  set status = 'paid', asaas_end_to_end_id = nullif(trim(p_end_to_end_id), ''), paid_at = timezone('utc', now())
  where id = charge_row.id;
  insert into public.provider_wallet_entries (provider_id, request_id, appointment_id, charge_id, gross_amount_cents, provider_net_cents, status)
  values (charge_row.provider_id, charge_row.request_id, charge_row.appointment_id, charge_row.id, charge_row.amount_cents, charge_row.amount_cents, 'held');
  if charge_row.appointment_id is not null then
    update public.service_appointments set fee_paid_at = now(), updated_at = now() where id = charge_row.appointment_id returning * into appointment_row;
    perform public.notify_appointment(appointment_row.provider_id, appointment_row.id, 'fee-paid', 'Taxa de deslocamento paga',
      'O motorista pagou a taxa. Você já pode sair para o atendimento no horário combinado.');
    return;
  end if;
  -- O PIX autoriza a saída; somente a chegada do prestador avança a fase.
  -- A confirmação não representa presença física no local.
  if charge_row.kind = 'dispatch' then
    update public.service_requests set updated_at = now() where id = charge_row.request_id;
  else
    update public.service_requests r set workflow_phase = 'service_released', status = 'in_service'
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_final_payment';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  select charge_row.request_id, null, r.status,
    'Pagamento Asaas confirmado; valor recebido pela plataforma e aguardando conferência do atendimento.'
  from public.service_requests r where r.id = charge_row.request_id;
end $$;

-- "Estou a caminho" só depois de a taxa cobrada estar paga.
do $$
declare d text; anchor text := E'    update public.service_appointments set stage = ''heading'', updated_at = now() where id = a.id;';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'provider_appointment_action';
  if position(anchor in d) = 0 then raise exception 'provider_appointment_action mudou; ajuste a migration.'; end if;
  d := replace(d, anchor, E'    if a.fee_charge_id is not null and a.fee_paid_at is null then\n      raise exception ''Aguardando o pagamento da taxa de deslocamento pelo motorista.'' using errcode = ''P0001''; end if;\n' || anchor);
  execute d;
end $$;
