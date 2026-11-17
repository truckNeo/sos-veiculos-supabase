-- Fase 2a: o app precisa do estado da cobrança da taxa.
drop function if exists public.list_my_service_appointments();
create function public.list_my_service_appointments()
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz, description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text, vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid, service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text, has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz, delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz, fee_charge_id uuid, payment_due_at timestamptz, fee_paid_at timestamptz, fee_released_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at,
    a.fee_charge_id, a.payment_due_at, a.fee_paid_at, a.fee_released_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where auth.uid() in (a.requester_id, a.provider_id)
  order by a.starts_at desc limit 200;
$$;
revoke all on function public.list_my_service_appointments() from public, anon;
grant execute on function public.list_my_service_appointments() to authenticated;

drop function if exists public.get_service_appointment_detail(p_id uuid);
create function public.get_service_appointment_detail(p_id uuid)
returns table(id uuid, requester_id uuid, provider_id uuid, vehicle_id uuid, starts_at timestamptz, ends_at timestamptz, description text, status text, service_request_id uuid, maintenance_plan_id uuid, vehicle_label text, provider_name text, vehicle_odometer integer, proposed_starts_at timestamptz, proposed_ends_at timestamptz, proposed_by uuid, service_mode text, location_label text, started_at timestamptz, finished_at timestamptz, cancel_reason text, requester_name text, has_review boolean, travel_fee_cents integer, stage text, eta_minutes integer, delivery_at timestamptz, delivery_proposed_at timestamptz, delay_minutes integer, delay_status text, delay_arrival_at timestamptz, created_at timestamptz, fee_charge_id uuid, payment_due_at timestamptz, fee_paid_at timestamptz, fee_released_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select a.id, a.requester_id, a.provider_id, a.vehicle_id, a.starts_at, a.ends_at, a.description, a.status,
    a.service_request_id, a.maintenance_plan_id, v.model || ' · ' || v.plate, p.business_name,
    a.vehicle_odometer, a.proposed_starts_at, a.proposed_ends_at, a.proposed_by,
    a.service_mode, a.location_label, a.started_at, a.finished_at, a.cancel_reason, r.full_name,
    exists(select 1 from public.reviews rv where rv.appointment_id = a.id and rv.reviewer_id = a.requester_id),
    a.travel_fee_cents, a.stage, a.eta_minutes, a.delivery_at, a.delivery_proposed_at,
    a.delay_minutes, a.delay_status, a.delay_arrival_at, a.created_at,
    a.fee_charge_id, a.payment_due_at, a.fee_paid_at, a.fee_released_at
  from public.service_appointments a join public.vehicles v on v.id = a.vehicle_id
  join public.provider_profiles p on p.provider_id = a.provider_id
  join public.profiles r on r.id = a.requester_id
  where a.id = p_id and auth.uid() in (a.requester_id, a.provider_id);
$$;
revoke all on function public.get_service_appointment_detail(p_id uuid) from public, anon;
grant execute on function public.get_service_appointment_detail(p_id uuid) to authenticated;
