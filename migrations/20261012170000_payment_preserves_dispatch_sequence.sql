-- Claim persistente da emissão: um timeout nunca autoriza outro POST financeiro.
alter table public.service_payment_charges add column if not exists asaas_checkout_claimed_at timestamptz;
create or replace function public.claim_asaas_charge_checkout(p_charge_id uuid,p_requester_id uuid,p_sandbox boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare target_request public.service_requests;
begin
  select r.* into target_request from public.service_requests r
  join public.service_payment_charges c on c.request_id=r.id
  where c.id=p_charge_id and r.requester_id=p_requester_id for update of r;
  if target_request.id is null then raise exception 'Cobrança não encontrada ou sem permissão.' using errcode='42501'; end if;
  if target_request.status<>'offer_accepted' or target_request.workflow_phase<>'awaiting_dispatch_payment' then
    raise exception 'O chamado não está disponível para emitir PIX.';
  end if;
  update public.service_payment_charges set asaas_checkout_claimed_at=now(),asaas_sandbox=p_sandbox
  where id=p_charge_id and kind='dispatch' and status='pending' and asaas_checkout_claimed_at is null;
  return found;
end; $$;
revoke all on function public.claim_asaas_charge_checkout(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.claim_asaas_charge_checkout(uuid,uuid,boolean) to service_role;

-- Confirma pagamento sem simular a chegada do prestador.
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
  -- O PIX autoriza a saída; somente a chegada do prestador avança a fase.
  -- A confirmação não representa presença física no local.
  if charge_row.kind = 'dispatch' then
    update public.service_requests set updated_at=now() where id=charge_row.request_id;
  else
    update public.service_requests r set workflow_phase = 'service_released', status = 'in_service'
    where r.id = charge_row.request_id and r.workflow_phase = 'awaiting_final_payment';
  end if;
  insert into public.service_request_events (request_id, actor_id, status, note)
  select charge_row.request_id, null, r.status,
    'Pagamento Asaas confirmado; valor recebido pela plataforma e aguardando conferência do atendimento.'
  from public.service_requests r where r.id = charge_row.request_id;
end;
$$;

grant execute on function public.confirm_asaas_charge_payment(text, text) to service_role;

-- O prestador precisa do status, mas não deve acessar QR, documento ou payload PIX.
create or replace function public.is_dispatch_payment_confirmed(p_request_id uuid)
returns boolean language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not exists(select 1 from public.service_requests where id=p_request_id and (requester_id=auth.uid() or selected_provider_id=auth.uid())) then
    raise exception 'Chamado não encontrado ou sem permissão.' using errcode='42501';
  end if;
  return exists(select 1 from public.service_payment_charges where request_id=p_request_id and kind='dispatch' and status='paid');
end; $$;
revoke all on function public.is_dispatch_payment_confirmed(uuid) from public;
grant execute on function public.is_dispatch_payment_confirmed(uuid) to authenticated;

-- Cancelamento não pode abandonar dinheiro recebido na conta mestre.
create or replace function public.transition_service_request_status(
  p_request_id uuid,
  p_target_status public.service_request_status,
  p_note text default null
)
returns table (
  request_id uuid,
  status public.service_request_status,
  workflow_phase public.service_workflow_phase
)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  requester_id uuid;
  selected_provider_id uuid;
  current_status public.service_request_status;
  current_phase public.service_workflow_phase;
  target_problem public.request_problem_type;
  dispatch_paid boolean;
  receipt_sent boolean;
  next_phase public.service_workflow_phase;
begin
  if actor_id is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;
  if p_note is not null and char_length(trim(p_note)) > 500 then
    raise exception 'A observação pode ter no máximo 500 caracteres.' using errcode = '22023';
  end if;

  select request_row.requester_id, request_row.selected_provider_id,
    request_row.status, request_row.workflow_phase, request_row.problem_type
  into requester_id, selected_provider_id, current_status, current_phase, target_problem
  from public.service_requests request_row
  where request_row.id = p_request_id
  for update;
  if requester_id is null then
    raise exception 'Chamado não encontrado.' using errcode = 'P0001';
  end if;

  select exists (
    select 1 from public.service_payment_charges charge
    where charge.request_id = p_request_id and charge.kind = 'dispatch' and charge.status = 'paid'
  ) into dispatch_paid;
  -- Mantido apenas para a nota do evento: não autoriza mais nada.
  select exists (
    select 1 from public.request_attachments attachment
    where attachment.request_id = p_request_id and attachment.kind::text = 'payment_receipt'
  ) into receipt_sent;

  next_phase := current_phase;
  if p_target_status = 'cancelled' then
    if dispatch_paid or exists(select 1 from public.service_payment_charges pending_charge where pending_charge.request_id=p_request_id and (pending_charge.status='awaiting_payment' or (pending_charge.status='pending' and pending_charge.asaas_checkout_claimed_at is not null))) then
      raise exception 'Há cobrança PIX emitida ou paga; solicite suporte para cancelamento financeiro.' using errcode='P0001';
    end if;
    if requester_id <> actor_id then
      raise exception 'Somente o motorista pode cancelar este chamado.' using errcode = '42501';
    end if;
    if current_phase not in ('open', 'awaiting_dispatch_payment') then
      raise exception 'Este chamado não pode mais ser cancelado nesta etapa.' using errcode = 'P0001';
    end if;
    next_phase := 'cancelled';
  elsif p_target_status = 'provider_en_route' then
    if selected_provider_id <> actor_id then
      raise exception 'Somente o prestador selecionado pode iniciar o deslocamento.' using errcode = '42501';
    end if;
    if current_status <> 'offer_accepted' or current_phase <> 'awaiting_dispatch_payment' then
      raise exception 'O chamado não está aguardando o deslocamento.' using errcode = 'P0001';
    end if;
    if not dispatch_paid then
      raise exception 'O pagamento ainda não foi confirmado pelo provedor. O comprovante enviado não libera o deslocamento.' using errcode = 'P0001';
    end if;
  elsif p_target_status = 'provider_on_site' then
    if selected_provider_id <> actor_id then
      raise exception 'Somente o prestador selecionado pode confirmar a chegada.' using errcode = '42501';
    end if;
    if current_status <> 'provider_en_route' then
      raise exception 'O prestador precisa iniciar o deslocamento antes de confirmar a chegada.' using errcode = 'P0001';
    end if;
    -- A fase só avança com pagamento confirmado.
    if dispatch_paid then
      next_phase := case when target_problem in ('tire', 'towing') then 'service_released' else 'diagnosis' end;
    end if;
  else
    raise exception 'Transição de status não permitida.' using errcode = '22023';
  end if;

  update public.service_requests request_row
  set status = p_target_status, workflow_phase = next_phase
  where request_row.id = p_request_id;

  insert into public.service_request_events (request_id, actor_id, status, note)
  values (
    p_request_id,
    actor_id,
    p_target_status,
    coalesce(nullif(trim(p_note), ''), case
      when p_target_status = 'provider_en_route' then
        case when receipt_sent then 'Prestador iniciou o deslocamento (pagamento confirmado; comprovante também anexado).'
             else 'Prestador iniciou o deslocamento (pagamento confirmado).' end
      when p_target_status = 'provider_on_site' then 'Prestador confirmou chegada ao local.'
      else 'Chamado cancelado pelo motorista.'
    end)
  );

  return query select p_request_id, p_target_status, next_phase;
end;
$$;

-- Bloqueia cancelamento após pagamento, inclusive sem foto de comprovante.
create or replace function public.provider_cancel_dispatch(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  select * into r from public.service_requests where id=p_request_id and selected_provider_id=auth.uid() for update;
  if r.id is null then raise exception 'Atendimento não encontrado ou sem permissão.' using errcode='42501'; end if;
  if r.workflow_phase<>'awaiting_dispatch_payment' then raise exception 'Cancelamento indisponível nesta etapa.'; end if;
  if exists(select 1 from public.service_payment_charges where request_id=p_request_id and (status in ('paid','awaiting_payment') or (status='pending' and asaas_checkout_claimed_at is not null))) then
    raise exception 'Há cobrança PIX emitida ou paga. Solicite suporte para cancelamento financeiro.';
  end if;
  update public.provider_offers set status='rejected',updated_at=now() where request_id=p_request_id and provider_id=auth.uid() and status='accepted';
  update public.service_payment_charges set status='cancelled' where request_id=p_request_id and status='pending';
  update public.service_requests set workflow_phase='open',status='open',selected_provider_id=null,history_access_allowed=false,updated_at=now() where id=p_request_id;
end; $$;
