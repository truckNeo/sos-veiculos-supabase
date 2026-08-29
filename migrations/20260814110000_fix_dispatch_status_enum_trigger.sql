-- Cada tabela possui um enum de status diferente. Funções de trigger separadas
-- evitam que o plano PL/pgSQL reutilize offer_status como service_request_status.

drop trigger if exists provider_offers_sync_dispatches on public.provider_offers;
drop trigger if exists service_requests_sync_dispatches on public.service_requests;

create or replace function public.sync_provider_offer_dispatches()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'submitted'::public.offer_status then
    update public.service_request_dispatches
    set status = 'offered'
    where request_id = new.request_id and provider_id = new.provider_id and status in ('pending', 'seen');
  elsif new.status = 'accepted'::public.offer_status then
    update public.service_request_dispatches
    set status = case when provider_id = new.provider_id then 'offered' else 'cancelled' end
    where request_id = new.request_id and status not in ('dismissed', 'cancelled');
  end if;
  return new;
end;
$$;

create or replace function public.sync_service_request_dispatches()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.selected_provider_id is not null then
    update public.service_request_dispatches
    set status = case when provider_id = new.selected_provider_id then 'offered' else 'cancelled' end
    where request_id = new.id and status not in ('dismissed', 'cancelled');
  elsif new.status = 'cancelled'::public.service_request_status then
    update public.service_request_dispatches
    set status = 'cancelled'
    where request_id = new.id and status not in ('dismissed', 'cancelled');
  end if;
  return new;
end;
$$;

create trigger provider_offers_sync_dispatches
  after insert or update of status on public.provider_offers
  for each row execute function public.sync_provider_offer_dispatches();
create trigger service_requests_sync_dispatches
  after update of selected_provider_id, status on public.service_requests
  for each row execute function public.sync_service_request_dispatches();
