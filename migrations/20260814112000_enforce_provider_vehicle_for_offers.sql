create or replace function public.require_provider_operational_vehicle()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from public.provider_vehicles vehicle
    where vehicle.provider_id = new.provider_id and vehicle.is_active
  ) then
    raise exception 'Cadastre um veículo operacional antes de enviar propostas.' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists provider_offers_require_vehicle on public.provider_offers;
create trigger provider_offers_require_vehicle
  before insert on public.provider_offers
  for each row execute function public.require_provider_operational_vehicle();
