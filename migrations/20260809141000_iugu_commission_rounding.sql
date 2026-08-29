-- A comissão é calculada sobre o total do chamado (e não arredondada por cobrança).

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
  update public.provider_wallet_entries entry set status = 'available',
    platform_fee_cents = case when entry.id = (
      select newest.id from public.provider_wallet_entries newest
      where newest.request_id = transfer_row.request_id and newest.provider_id = transfer_row.provider_id and newest.status = 'held'
      order by newest.created_at desc limit 1
    ) then transfer_row.platform_fee_cents - coalesce((
      select sum((other_entry.gross_amount_cents * 10) / 100) from public.provider_wallet_entries other_entry
      where other_entry.request_id = transfer_row.request_id and other_entry.provider_id = transfer_row.provider_id
        and other_entry.status = 'held' and other_entry.id <> entry.id
    ), 0) else (entry.gross_amount_cents * 10) / 100 end,
    provider_net_cents = entry.gross_amount_cents - case when entry.id = (
      select newest.id from public.provider_wallet_entries newest
      where newest.request_id = transfer_row.request_id and newest.provider_id = transfer_row.provider_id and newest.status = 'held'
      order by newest.created_at desc limit 1
    ) then transfer_row.platform_fee_cents - coalesce((
      select sum((other_entry.gross_amount_cents * 10) / 100) from public.provider_wallet_entries other_entry
      where other_entry.request_id = transfer_row.request_id and other_entry.provider_id = transfer_row.provider_id
        and other_entry.status = 'held' and other_entry.id <> entry.id
    ), 0) else (entry.gross_amount_cents * 10) / 100 end,
    released_at = timezone('utc', now())
  where entry.request_id = transfer_row.request_id and entry.provider_id = transfer_row.provider_id and entry.status = 'held';
  update public.service_requests set workflow_phase = 'completed', status = 'completed', closed_at = timezone('utc', now()),
    driver_confirmed_at = timezone('utc', now()), payment_released_at = timezone('utc', now()) where id = transfer_row.request_id;
  update public.provider_profiles set completed_services = completed_services + 1 where provider_id = transfer_row.provider_id;
  insert into public.service_request_events (request_id, actor_id, status, note)
  values (transfer_row.request_id, requester, 'completed', 'Motorista avaliou o prestador e autorizou o repasse Iugu de 90% do saldo.');
end;
$$;
