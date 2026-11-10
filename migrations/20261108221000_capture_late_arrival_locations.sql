-- O gateway pode persistir o lote de GPS após a mudança para provider_on_site.
-- Completar o resumo durável sem depender da ordem entre os dois eventos.
create or replace function public.capture_late_dispatch_arrival_location()
returns trigger language plpgsql security definer set search_path=public as $$
declare arrived timestamptz; distance_m double precision;
begin
  select e.arrived_at into arrived from public.dispatch_arrival_evidence e
  join public.service_requests r on r.id=e.request_id
  where e.request_id=new.request_id and r.selected_provider_id=new.provider_id;
  if arrived is null or new.captured_at not between arrived-interval '15 minutes' and arrived+interval '5 minutes' then
    return new;
  end if;
  select sqrt(power((new.latitude-r.latitude)*111000,2)+
    power((new.longitude-r.longitude)*111000*cos(radians(r.latitude)),2))
    into distance_m from public.service_requests r where r.id=new.request_id;
  update public.dispatch_arrival_evidence
    set sample_count=sample_count+1,
        closest_meters=least(coalesce(closest_meters,distance_m),distance_m)
    where request_id=new.request_id;
  return new;
end $$;
create trigger capture_late_dispatch_arrival_location
  after insert on public.service_request_locations for each row
  execute function public.capture_late_dispatch_arrival_location();
