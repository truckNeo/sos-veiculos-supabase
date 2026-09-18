-- confirm_asaas_charge_payment falhava com "column workflow_phase is of type
-- service_workflow_phase but expression is of type text": o CASE com dois
-- literais resolve para text (não "unknown"), e Postgres não faz cast
-- implícito de text para enum na atribuição. Faltou o cast explícito.
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
    update public.service_requests r set workflow_phase = (case when target_problem in ('tire', 'towing') then 'service_released' else 'diagnosis' end)::public.service_workflow_phase,
      diagnostic_started_at = case when target_problem in ('tire', 'towing') then null else timezone('utc', now()) end,
      status = (case when target_problem in ('tire', 'towing') then 'in_service' else 'provider_on_site' end)::public.service_request_status
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_dispatch_payment';
  else
    update public.service_requests r set workflow_phase = 'service_released', status = 'in_service'
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_final_payment';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (charge_row.request_id, charge_row.provider_id, (case when charge_row.kind = 'dispatch' and target_problem not in ('tire', 'towing') then 'provider_on_site' else 'in_service' end)::public.service_request_status,
    case when charge_row.kind = 'dispatch' then 'Pagamento Asaas confirmado; valor retido até a conferência do motorista.' else 'Orçamento final pago pelo Asaas; valor retido até a conferência do motorista.' end);
end;
$$;
