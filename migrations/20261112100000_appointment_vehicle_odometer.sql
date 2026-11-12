-- Guarda a quilometragem do veículo no momento do agendamento, para que o
-- prestador (que não lê vehicle_odometer_readings) veja o km ao receber o pedido.
alter table public.service_appointments
  add column vehicle_odometer integer check (vehicle_odometer >= 0);

create or replace function public.create_service_appointment_v2(p_vehicle_id uuid,p_provider_id uuid,p_starts_at timestamptz,p_duration_minutes integer,p_description text,p_plan_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$ declare result uuid; begin
 if p_plan_id is not null and not exists(select 1 from public.vehicle_maintenance_plans where id=p_plan_id and vehicle_id=p_vehicle_id and public.can_manage_vehicle(vehicle_id)) then raise exception 'Plano indisponível.' using errcode='42501'; end if;
 result=public.create_service_appointment(p_vehicle_id,p_provider_id,p_starts_at,p_duration_minutes,p_description);
 update public.service_appointments set maintenance_plan_id=p_plan_id,
   vehicle_odometer=(select r.odometer from public.vehicles v join public.vehicle_odometer_readings r on r.id=v.odometer_reading_id where v.id=p_vehicle_id)
 where id=result;
 return result;
end $$;
