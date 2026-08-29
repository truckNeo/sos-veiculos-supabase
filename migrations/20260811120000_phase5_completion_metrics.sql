-- Conclusão da Fase 5: encerramento idempotente, avaliação única e métricas
-- consistentes para o perfil do prestador.

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
  review_id uuid;
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
  if target_phase = 'completed' then
    return;
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
  values (p_request_id, current_requester_id, target_provider_id, p_rating, nullif(trim(p_comment), ''))
  on conflict (request_id) do nothing
  returning id into review_id;
  if review_id is null then
    return;
  end if;

  update public.provider_wallet_entries
  set status = 'available', released_at = timezone('utc', now())
  where request_id = p_request_id and provider_id = target_provider_id and status = 'held';
  update public.service_requests
  set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
    driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now())
  where id = p_request_id;
  update public.provider_profiles profile
  set completed_services = profile.completed_services + 1,
      average_rating = (select round(avg(review.rating)::numeric, 2)
                        from public.reviews review
                        where review.provider_id = target_provider_id)
  where profile.provider_id = target_provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (p_request_id, current_requester_id, 'completed', 'Motorista conferiu o serviço, avaliou o prestador e liberou o pagamento.');
end;
$$;

create or replace function public.complete_iugu_payment_release_with_review(
  p_transfer_id uuid, p_iugu_transfer_id text, p_rating smallint, p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  transfer_row public.service_provider_transfers;
  requester uuid;
  review_id uuid;
begin
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'A avaliação de 1 a 5 estrelas é obrigatória.' using errcode = '22023';
  end if;
  select * into transfer_row
  from public.service_provider_transfers
  where id = p_transfer_id
  for update;
  if transfer_row.id is null then
    raise exception 'Liberação não encontrada.' using errcode = 'P0001';
  end if;
  if transfer_row.status = 'completed' then
    return;
  end if;
  select requester_id into requester
  from public.service_requests
  where id = transfer_row.request_id;
  if requester is null then
    raise exception 'Chamado da liberação não encontrado.' using errcode = 'P0001';
  end if;

  insert into public.reviews (request_id, reviewer_id, provider_id, rating, comment)
  values (transfer_row.request_id, requester, transfer_row.provider_id, p_rating, nullif(trim(p_comment), ''))
  on conflict (request_id) do nothing
  returning id into review_id;
  if review_id is null then
    return;
  end if;

  update public.service_provider_transfers
  set status = 'completed', iugu_transfer_id = nullif(trim(p_iugu_transfer_id), ''), completed_at = timezone('utc', now())
  where id = p_transfer_id;
  update public.provider_wallet_entries entry
  set status = 'available',
      platform_fee_cents = case when entry.id = (
        select newest.id from public.provider_wallet_entries newest
        where newest.request_id = transfer_row.request_id and newest.provider_id = transfer_row.provider_id and newest.status = 'held'
        order by newest.created_at desc limit 1
      ) then transfer_row.platform_fee_cents - coalesce((
        select sum((other_entry.gross_amount_cents * 10) / 100)
        from public.provider_wallet_entries other_entry
        where other_entry.request_id = transfer_row.request_id and other_entry.provider_id = transfer_row.provider_id
          and other_entry.status = 'held' and other_entry.id <> entry.id
      ), 0) else (entry.gross_amount_cents * 10) / 100 end,
      provider_net_cents = entry.gross_amount_cents - case when entry.id = (
        select newest.id from public.provider_wallet_entries newest
        where newest.request_id = transfer_row.request_id and newest.provider_id = transfer_row.provider_id and newest.status = 'held'
        order by newest.created_at desc limit 1
      ) then transfer_row.platform_fee_cents - coalesce((
        select sum((other_entry.gross_amount_cents * 10) / 100)
        from public.provider_wallet_entries other_entry
        where other_entry.request_id = transfer_row.request_id and other_entry.provider_id = transfer_row.provider_id
          and other_entry.status = 'held' and other_entry.id <> entry.id
      ), 0) else (entry.gross_amount_cents * 10) / 100 end,
      released_at = timezone('utc', now())
  where entry.request_id = transfer_row.request_id and entry.provider_id = transfer_row.provider_id and entry.status = 'held';
  update public.service_requests
  set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
      driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now())
  where id = transfer_row.request_id;
  update public.provider_profiles profile
  set completed_services = profile.completed_services + 1,
      average_rating = (select round(avg(review.rating)::numeric, 2)
                        from public.reviews review
                        where review.provider_id = transfer_row.provider_id)
  where profile.provider_id = transfer_row.provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (transfer_row.request_id, requester, 'completed', 'Motorista avaliou o prestador e autorizou o repasse Iugu de 90% do saldo.');
end;
$$;
