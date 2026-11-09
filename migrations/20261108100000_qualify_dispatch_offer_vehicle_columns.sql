-- Qualifica as colunas do veículo para não conflitar com os campos de saída
-- da função RETURNS TABLE (id, provider_id, ...).
create or replace function public.submit_provider_dispatch_offer_with_vehicle(
  p_request_id uuid,
  p_travel_fee_cents integer,
  p_estimated_arrival_minutes integer,
  p_vehicle_id uuid,
  p_notes text default null
)
returns table (
  id uuid,
  request_id uuid,
  provider_id uuid,
  status public.offer_status,
  created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if p_vehicle_id is null or not exists (
    select 1
    from public.provider_vehicles as vehicle
    where vehicle.id = p_vehicle_id
      and vehicle.provider_id = auth.uid()
      and vehicle.is_active
      and vehicle.color is not null
  ) then
    raise exception 'Selecione um veículo completo do seu cadastro.';
  end if;
  perform set_config('sos.offer_vehicle_id', p_vehicle_id::text, true);
  return query
    select offer.id, offer.request_id, offer.provider_id, offer.status, offer.created_at
    from public.submit_provider_dispatch_offer(
      p_request_id, p_travel_fee_cents, p_estimated_arrival_minutes, p_notes
    ) as offer;
  perform set_config('sos.offer_vehicle_id', '', true);
end $$;
