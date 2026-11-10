-- A chegada exige prova recente no servidor; uma posição exibida no app não
-- autoriza a transição. A exceção manual só existe após confirmação do motorista.
create table public.dispatch_manual_arrival_requests (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id),
  status text not null default 'pending' check (status in ('pending','confirmed')),
  reason text not null,
  requested_at timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid references public.profiles(id)
);
alter table public.dispatch_manual_arrival_requests enable row level security;
revoke all on public.dispatch_manual_arrival_requests from public,anon,authenticated;
grant select on public.dispatch_manual_arrival_requests to authenticated;
create policy "participants read manual arrival" on public.dispatch_manual_arrival_requests
  for select to authenticated using (public.is_request_participant(request_id));

alter table public.driver_event_push_outbox drop constraint if exists driver_event_push_outbox_kind_check;
alter table public.driver_event_push_outbox add constraint driver_event_push_outbox_kind_check
  check (kind in ('offer_received','provider_en_route','provider_on_site',
    'awaiting_driver_confirmation','dispute_opened','service_closed','arrival_manual_requested'));

alter table public.dispatch_arrival_evidence
  add column qualified_sample_count integer not null default 0,
  add column geofence_verified boolean not null default false;

-- A rota legada permitia ao prestador gravar coordenadas arbitrárias por RPC.
-- O V2 envia posições pelo gateway autenticado e as persiste com service role.
revoke execute on function public.record_service_request_location(uuid,double precision,double precision,double precision) from authenticated;

create or replace function public.arrival_distance_meters(
  p_lat_a double precision,p_lon_a double precision,p_lat_b double precision,p_lon_b double precision
) returns double precision language sql immutable set search_path=public as $$
  select 2*6371000*asin(least(1,sqrt(
    power(sin(radians((p_lat_b-p_lat_a)/2)),2)+
    cos(radians(p_lat_a))*cos(radians(p_lat_b))*power(sin(radians((p_lon_b-p_lon_a)/2)),2)
  )))
$$;
revoke all on function public.arrival_distance_meters(double precision,double precision,double precision,double precision) from public,anon;

create or replace function public.validate_provider_arrival_geofence() returns trigger
language plpgsql security definer set search_path=public as $$
declare near_count integer; first_seen timestamptz; last_seen timestamptz;
begin
  if new.status='provider_on_site' and old.status is distinct from new.status then
    if exists(select 1 from public.dispatch_manual_arrival_requests m
      where m.request_id=new.id and m.provider_id=new.selected_provider_id
        and m.status='confirmed' and m.confirmed_by=new.requester_id) then
      return new;
    end if;
    select count(*),min(l.received_at),max(l.received_at)
      into near_count,first_seen,last_seen
    from public.service_request_locations l
    where l.request_id=new.id and l.provider_id=new.selected_provider_id
      and l.received_at between now()-interval '90 seconds' and now()+interval '5 seconds'
      and l.captured_at between now()-interval '90 seconds' and now()+interval '5 seconds'
      and l.accuracy_meters between 0 and 50
      and public.arrival_distance_meters(l.latitude,l.longitude,new.latitude,new.longitude)<=200;
    if near_count<2 or last_seen-first_seen<interval '3 seconds' then
      raise exception 'Chegada não verificada: aproxime-se do local e aguarde duas posições recentes de GPS com boa precisão.' using errcode='P0001';
    end if;
  end if;
  return new;
end $$;
create trigger validate_provider_arrival_geofence before update of status on public.service_requests
  for each row execute function public.validate_provider_arrival_geofence();

create or replace function public.capture_dispatch_arrival_evidence() returns trigger
language plpgsql security definer set search_path=public as $$
declare n integer; q integer; nearest double precision; manual boolean;
begin
  if new.status='provider_on_site' and old.status is distinct from new.status then
    select exists(select 1 from public.dispatch_manual_arrival_requests m
      where m.request_id=new.id and m.status='confirmed' and m.confirmed_by=new.requester_id) into manual;
    select count(*),
      count(*) filter (where l.accuracy_meters between 0 and 50
        and public.arrival_distance_meters(l.latitude,l.longitude,new.latitude,new.longitude)<=150),
      min(public.arrival_distance_meters(l.latitude,l.longitude,new.latitude,new.longitude))
      into n,q,nearest from public.service_request_locations l
      where l.request_id=new.id and l.provider_id=new.selected_provider_id
        and l.received_at between now()-interval '5 minutes' and now()+interval '5 seconds'
        and l.captured_at between now()-interval '5 minutes' and now()+interval '5 seconds';
    insert into public.dispatch_arrival_evidence
      (request_id,arrived_at,sample_count,closest_meters,qualified_sample_count,geofence_verified)
      values(new.id,now(),n,nearest,q,not manual) on conflict(request_id) do nothing;
  end if;
  return new;
end $$;

create or replace function public.capture_late_dispatch_arrival_location() returns trigger
language plpgsql security definer set search_path=public as $$
declare arrived timestamptz; distance_m double precision;
begin
  select e.arrived_at into arrived from public.dispatch_arrival_evidence e
  join public.service_requests r on r.id=e.request_id
  where e.request_id=new.request_id and r.selected_provider_id=new.provider_id;
  if arrived is null or new.captured_at not between arrived-interval '5 minutes' and arrived+interval '5 minutes'
     or new.received_at not between arrived-interval '5 minutes' and arrived+interval '5 minutes' then
    return new;
  end if;
  select public.arrival_distance_meters(new.latitude,new.longitude,r.latitude,r.longitude)
    into distance_m from public.service_requests r where r.id=new.request_id;
  update public.dispatch_arrival_evidence
    set sample_count=sample_count+1,
        closest_meters=least(coalesce(closest_meters,distance_m),distance_m),
        qualified_sample_count=qualified_sample_count+
          case when new.accuracy_meters between 0 and 50 and distance_m<=150 then 1 else 0 end
    where request_id=new.request_id;
  return new;
end $$;

create or replace function public.request_manual_provider_arrival(p_request_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  select * into r from public.service_requests where id=p_request_id for update;
  if r.id is null or auth.uid() is distinct from r.selected_provider_id then
    raise exception 'Atendimento não autorizado.' using errcode='42501';
  end if;
  if r.status<>'provider_en_route' or r.workflow_phase<>'awaiting_dispatch_payment' then
    raise exception 'A verificação manual só pode ser solicitada durante o deslocamento.' using errcode='P0001';
  end if;
  if not exists(select 1 from public.service_payment_charges c where c.request_id=r.id and c.kind='dispatch' and c.status='paid') then
    raise exception 'Pagamento ainda não confirmado.' using errcode='P0001';
  end if;
  if char_length(trim(coalesce(p_reason,'')))<10 or char_length(p_reason)>500 then
    raise exception 'Descreva o motivo em 10 a 500 caracteres.' using errcode='22023';
  end if;
  insert into public.dispatch_manual_arrival_requests(request_id,provider_id,reason)
    values(r.id,auth.uid(),trim(p_reason)) on conflict(request_id) do nothing;
  if found then
    insert into public.service_request_events(request_id,actor_id,status,note)
      values(r.id,auth.uid(),r.status,'Prestador solicitou confirmação manual de chegada sem prova suficiente de GPS.');
    perform public.enqueue_driver_event_push(r.id,r.requester_id,'arrival_manual_requested');
  end if;
end $$;
revoke all on function public.request_manual_provider_arrival(uuid,text) from public,anon;
grant execute on function public.request_manual_provider_arrival(uuid,text) to authenticated;

create or replace function public.confirm_manual_provider_arrival_with_review(
  p_request_id uuid,p_rating integer,p_comment text default null
) returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  select * into r from public.service_requests where id=p_request_id for update;
  if r.id is null or auth.uid() is distinct from r.requester_id then
    raise exception 'Atendimento não autorizado.' using errcode='42501';
  end if;
  if r.provider_arrival_confirmed_at is not null then
    if exists(select 1 from public.dispatch_reviews where request_id=r.id and reviewer_id=auth.uid()) then return; end if;
    raise exception 'Chegada já confirmada.' using errcode='P0001';
  end if;
  if r.status<>'provider_en_route' or r.workflow_phase<>'awaiting_dispatch_payment' or
    not exists(select 1 from public.dispatch_manual_arrival_requests m
      where m.request_id=r.id and m.provider_id=r.selected_provider_id and m.status='pending') then
    raise exception 'Não há solicitação manual de chegada pendente.' using errcode='P0001';
  end if;
  if exists(select 1 from public.service_disputes d where d.request_id=r.id) then
    raise exception 'Atendimento em disputa.' using errcode='P0001';
  end if;
  update public.dispatch_manual_arrival_requests set status='confirmed',confirmed_at=now(),confirmed_by=auth.uid()
    where request_id=r.id;
  update public.service_requests set status='provider_on_site',
    workflow_phase=case when r.problem_type in ('tire','towing') then 'service_released'::public.service_workflow_phase else 'diagnosis'::public.service_workflow_phase end
    where id=r.id;
  insert into public.service_request_events(request_id,actor_id,status,note)
    values(r.id,auth.uid(),'provider_on_site','Motorista confirmou presencialmente a chegada solicitada sem GPS confiável.');
  perform public.confirm_dispatch_arrival_with_review(r.id,p_rating,p_comment);
end $$;
revoke all on function public.confirm_manual_provider_arrival_with_review(uuid,integer,text) from public,anon;
grant execute on function public.confirm_manual_provider_arrival_with_review(uuid,integer,text) to authenticated;

create or replace function public.open_manual_provider_arrival_dispute(p_request_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  if char_length(trim(coalesce(p_reason,'')))<10 or char_length(p_reason)>2000 then
    raise exception 'Descreva o problema em 10 a 2000 caracteres.' using errcode='22023';
  end if;
  select * into r from public.service_requests where id=p_request_id for update;
  if r.id is null or r.requester_id is distinct from auth.uid() then
    raise exception 'Atendimento não autorizado.' using errcode='42501';
  end if;
  if r.status<>'provider_en_route' or r.workflow_phase<>'awaiting_dispatch_payment' or
    not exists(select 1 from public.dispatch_manual_arrival_requests m
      where m.request_id=r.id and m.status='pending' and m.provider_id=r.selected_provider_id) then
    raise exception 'Não há chegada manual pendente.' using errcode='P0001';
  end if;
  if exists(select 1 from public.service_disputes where request_id=r.id) then
    raise exception 'Este atendimento já possui uma disputa.' using errcode='P0001';
  end if;
  update public.service_requests set workflow_phase='in_dispute',status='disputed' where id=r.id;
  insert into public.service_disputes(request_id,opened_by,reason)
    values(r.id,auth.uid(),trim(p_reason));
  insert into public.service_request_events(request_id,actor_id,status,note)
    values(r.id,auth.uid(),'disputed','Motorista contestou a chegada declarada sem prova de GPS.');
end $$;
revoke all on function public.open_manual_provider_arrival_dispute(uuid,text) from public,anon;
grant execute on function public.open_manual_provider_arrival_dispute(uuid,text) to authenticated;

create or replace function public.process_overdue_dispatch_arrivals()
returns table(auto_released integer,manual_review integer)
language plpgsql security definer set search_path=public as $$
declare r public.service_requests; evidence public.dispatch_arrival_evidence; gross integer; fee integer;
begin
  if auth.role() <> 'service_role' then raise exception 'Acesso restrito.' using errcode='42501'; end if;
  auto_released:=0; manual_review:=0;
  for r in select s.* from public.service_requests s
    where s.provider_arrival_confirmed_at is null and s.status in ('provider_on_site','in_service')
      and exists(select 1 from public.service_request_events e where e.request_id=s.id and e.status='provider_on_site' and e.created_at <= now()-interval '24 hours')
      and not exists(select 1 from public.service_disputes d where d.request_id=s.id)
    order by s.opened_at limit 25 for update of s skip locked
  loop
    select * into evidence from public.dispatch_arrival_evidence where request_id=r.id;
    if evidence.request_id is null or not evidence.geofence_verified or evidence.qualified_sample_count<3 then
      insert into public.dispatch_arrival_manual_reviews(request_id,reason)
        values(r.id,'Rastreamento insuficiente para liberação automática.') on conflict do nothing;
      manual_review:=manual_review+1;
      continue;
    end if;
    if exists(select 1 from public.asaas_dispute_operations where request_id=r.id) then continue; end if;
    if not exists(select 1 from public.service_payment_charges c where c.request_id=r.id and c.kind='dispatch' and c.status='paid') then continue; end if;
    select coalesce(sum(w.gross_amount_cents),0) into gross from public.provider_wallet_entries w
      join public.service_payment_charges c on c.id=w.charge_id
      where w.request_id=r.id and w.provider_id=r.selected_provider_id and w.status='held' and c.kind='dispatch' and c.status='paid';
    if gross<=0 then continue; end if;
    fee:=(gross*10)/100;
    insert into public.service_provider_transfers(request_id,provider_id,gross_amount_cents,platform_fee_cents,provider_net_cents)
      values(r.id,r.selected_provider_id,gross,fee,gross-fee) on conflict(request_id) do nothing;
    update public.service_requests set provider_arrival_confirmed_at=now() where id=r.id;
    insert into public.service_request_events(request_id,actor_id,status,note)
      values(r.id,null,r.status,'Deslocamento liberado automaticamente após 24 horas sem disputa e com rastreamento verificado.');
    auto_released:=auto_released+1;
  end loop;
  return next;
end $$;
