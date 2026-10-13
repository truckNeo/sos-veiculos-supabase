-- Exige confirmação do pagamento para iniciar o deslocamento.
--
-- A regra anterior aceitava `receipt_sent OR dispatch_paid`: bastava o
-- motorista enviar uma foto de comprovante para o prestador poder sair. Ela
-- foi criada quando não havia pagamento real no MVP. Com o Asaas em
-- operação, a confirmação passa a vir do gateway, via
-- confirm_asaas_charge_payment (webhook asaas-webhook) ou, em sandbox, via
-- confirm-asaas-sandbox-payment.
--
-- O comprovante continua sendo anexado e visível ao prestador, mas deixa de
-- autorizar o deslocamento: é evidência, não confirmação.
--
-- ATENÇÃO NO DEPLOY: o webhook do Asaas precisa estar registrado no painel
-- antes desta migration, senão nenhum deslocamento inicia.

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
