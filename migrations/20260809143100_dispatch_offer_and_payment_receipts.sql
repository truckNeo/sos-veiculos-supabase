-- Corrige a atualização do enum ao selecionar a taxa de deslocamento e
-- registra comprovantes somente depois que o motorista escolheu o prestador.
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
  set status = case when id = p_offer_id
    then 'accepted'::public.offer_status
    else 'rejected'::public.offer_status
  end
  where request_id = target_request_id and status = 'submitted'::public.offer_status;

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

drop policy "requester can add attachments" on public.request_attachments;
create policy "requester can add non-payment attachments"
  on public.request_attachments for insert to authenticated
  with check (
    kind::text <> 'payment_receipt'
    and uploaded_by = auth.uid()
    and storage_path like auth.uid()::text || '/' || request_id::text || '/%'
    and exists (
      select 1 from public.service_requests request
      where request.id = request_id and request.requester_id = auth.uid()
    )
  );

create or replace function public.register_dispatch_payment_receipt(
  p_request_id uuid,
  p_storage_path text
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
  if p_storage_path !~ ('^' || current_requester_id::text || '/' || p_request_id::text || '/[^/]+$') then
    raise exception 'Caminho do comprovante inválido.' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.service_requests request
    where request.id = p_request_id
      and request.requester_id = current_requester_id
      and request.workflow_phase = 'awaiting_dispatch_payment'
      and request.selected_provider_id is not null
  ) then
    raise exception 'O comprovante só pode ser enviado após escolher o prestador.' using errcode = '42501';
  end if;

  insert into public.request_attachments (request_id, uploaded_by, kind, storage_path)
  values (p_request_id, current_requester_id, 'payment_receipt', p_storage_path);
end;
$$;

revoke all on function public.register_dispatch_payment_receipt(uuid, text) from public;
grant execute on function public.register_dispatch_payment_receipt(uuid, text) to authenticated;
