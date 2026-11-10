create or replace function public.confirm_manual_provider_arrival(
  p_request_id uuid
) returns void language plpgsql security definer set search_path=public as $$
declare r public.service_requests;
begin
  select * into r from public.service_requests where id=p_request_id for update;
  if r.id is null or auth.uid() is distinct from r.requester_id then
    raise exception 'Atendimento não autorizado.' using errcode='42501';
  end if;
  if r.provider_arrival_confirmed_at is not null then
    return;
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
  perform public.confirm_provider_arrival(r.id);
end $$;
revoke all on function public.confirm_manual_provider_arrival(uuid) from public,anon;
grant execute on function public.confirm_manual_provider_arrival(uuid) to authenticated;

