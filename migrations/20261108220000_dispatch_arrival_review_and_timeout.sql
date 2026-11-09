-- Avaliação do deslocamento é distinta da avaliação posterior do serviço.
create table public.dispatch_reviews (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  provider_id uuid not null references public.provider_profiles(provider_id),
  reviewer_id uuid not null references public.profiles(id),
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);
alter table public.dispatch_reviews enable row level security;
grant select on public.dispatch_reviews to authenticated;
create policy "participants read dispatch review" on public.dispatch_reviews for select to authenticated
  using (reviewer_id=auth.uid() or provider_id=auth.uid());

create or replace function public.confirm_dispatch_arrival_with_review(
  p_request_id uuid, p_rating integer, p_comment text default null
) returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  if p_rating not between 1 and 5 or char_length(coalesce(p_comment,''))>1000 then
    raise exception 'Avalie o deslocamento de 1 a 5 estrelas.' using errcode='22023';
  end if;
  select * into r from public.service_requests where id=p_request_id for update;
  if r.id is null or r.requester_id is distinct from auth.uid() then
    raise exception 'Atendimento não autorizado.' using errcode='42501';
  end if;
  if r.provider_arrival_confirmed_at is not null then
    if exists(select 1 from public.dispatch_reviews where request_id=r.id and reviewer_id=auth.uid()) then return; end if;
    raise exception 'A chegada já foi confirmada por outro fluxo.' using errcode='P0001';
  end if;
  if exists(select 1 from public.service_disputes where request_id=r.id) then
    raise exception 'O atendimento está em disputa.' using errcode='P0001';
  end if;
  perform public.confirm_provider_arrival(r.id);
  insert into public.dispatch_reviews(request_id,provider_id,reviewer_id,rating,comment)
    values(r.id,r.selected_provider_id,auth.uid(),p_rating,nullif(trim(p_comment),''));
end $$;
revoke all on function public.confirm_dispatch_arrival_with_review(uuid,integer,text) from public,anon;
grant execute on function public.confirm_dispatch_arrival_with_review(uuid,integer,text) to authenticated;

-- Guardar um resumo da prova antes de expirar o rastreamento efêmero.
create table public.dispatch_arrival_evidence (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  arrived_at timestamptz not null,
  sample_count integer not null,
  closest_meters double precision,
  captured_at timestamptz not null default now()
);
alter table public.dispatch_arrival_evidence enable row level security;
revoke all on public.dispatch_arrival_evidence from public,anon,authenticated;
grant all on public.dispatch_arrival_evidence to service_role;

create or replace function public.capture_dispatch_arrival_evidence() returns trigger
language plpgsql security definer set search_path=public as $$
declare n integer; nearest double precision;
begin
  if new.status='provider_on_site' and old.status is distinct from new.status then
    select count(*), min(sqrt(power((l.latitude-new.latitude)*111000,2)+
      power((l.longitude-new.longitude)*111000*cos(radians(new.latitude)),2)))
      into n,nearest from public.service_request_locations l
      where l.request_id=new.id and l.provider_id=new.selected_provider_id
        and l.captured_at between now()-interval '15 minutes' and now();
    insert into public.dispatch_arrival_evidence(request_id,arrived_at,sample_count,closest_meters)
      values(new.id,now(),n,nearest) on conflict(request_id) do nothing;
  end if;
  return new;
end $$;
create trigger capture_dispatch_arrival_evidence after update of status on public.service_requests
  for each row execute function public.capture_dispatch_arrival_evidence();

create table public.dispatch_arrival_manual_reviews (
  request_id uuid primary key references public.service_requests(id) on delete cascade,
  reason text not null,
  created_at timestamptz not null default now()
);
alter table public.dispatch_arrival_manual_reviews enable row level security;
revoke all on public.dispatch_arrival_manual_reviews from public,anon,authenticated;
grant all on public.dispatch_arrival_manual_reviews to service_role;

-- A equipe de disputas pode conferir fotos enviadas pelos participantes.
create policy "dispute admins read request evidence" on public.request_attachments
  for select to authenticated using (
    public.is_service_dispute_admin() and
    exists(select 1 from public.service_disputes d where d.request_id=request_id)
  );
create policy "dispute admins read attachment objects" on storage.objects
  for select to authenticated using (
    bucket_id='request-attachments' and public.is_service_dispute_admin() and
    exists(select 1 from public.service_disputes d
      where d.request_id::text=(storage.foldername(name))[2])
  );

-- Executada pelo scheduler com service role. Não libera casos sem prova suficiente.
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
    if evidence.request_id is null or evidence.sample_count<3 or evidence.closest_meters>150 or evidence.closest_meters is null then
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
revoke all on function public.process_overdue_dispatch_arrivals() from public,anon,authenticated;
grant execute on function public.process_overdue_dispatch_arrivals() to service_role;
