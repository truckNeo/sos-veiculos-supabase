-- Avaliação do atendimento na oficina: o motorista avalia o mecânico depois que
-- o prestador finaliza, sem passar pelo fluxo de chamado. A avaliação entra na
-- média do prestador e nas listas de avaliações como as demais.
alter table public.reviews alter column request_id drop not null;
alter table public.reviews add column appointment_id uuid references public.service_appointments(id) on delete cascade;
alter table public.reviews add constraint reviews_one_origin_check check ((request_id is not null) <> (appointment_id is not null));
create unique index reviews_appointment_reviewer_key on public.reviews(appointment_id, reviewer_id) where appointment_id is not null;

create function public.review_service_appointment(p_id uuid, p_rating integer, p_comment text default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.service_appointments;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.requester_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.service_request_id is not null then
    raise exception 'Este atendimento é avaliado pelo fluxo do chamado.' using errcode = 'P0001'; end if;
  if a.status <> 'completed' then raise exception 'Você poderá avaliar depois que o prestador finalizar o atendimento.' using errcode = 'P0001'; end if;
  if p_rating is null or p_rating not between 1 and 5 then raise exception 'Escolha uma nota de 1 a 5.' using errcode = 'P0001'; end if;
  insert into public.reviews(appointment_id, provider_id, reviewer_id, rating, comment)
  values(a.id, a.provider_id, auth.uid(), p_rating, nullif(trim(coalesce(p_comment, '')), ''))
  on conflict do nothing;
  update public.provider_profiles p set average_rating = (select coalesce(avg(v.rating), 0) from public.reviews v where v.provider_id = p.provider_id and v.reviewer_id <> p.provider_id)
  where p.provider_id = a.provider_id;
end $$;
revoke all on function public.review_service_appointment(uuid, integer, text) from public, anon;
grant execute on function public.review_service_appointment(uuid, integer, text) to authenticated;

drop function public.get_service_appointment_detail(uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz,
  description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text,
  vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid,
  service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text,
  has_review boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id)
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(uuid) from public;
grant execute on function public.get_service_appointment_detail(uuid) to authenticated;
