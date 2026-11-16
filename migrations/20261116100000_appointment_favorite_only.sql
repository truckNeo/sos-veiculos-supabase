-- O motorista só agenda com mecânicos que aceitaram seu convite de favorito.
-- Antes a regra existia apenas no app; a RPC aceitava qualquer prestador.
create or replace function public.create_service_appointment_v2(p_vehicle_id uuid,p_provider_id uuid,p_starts_at timestamptz,p_duration_minutes integer,p_description text,p_plan_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$ declare result uuid; begin
 if not exists(select 1 from public.favorite_mechanic_invites where driver_id=auth.uid() and provider_id=p_provider_id and status='accepted') then
  raise exception 'Você só pode agendar com mecânicos favoritos que aceitaram seu convite.' using errcode='P0001';
 end if;
 if p_plan_id is not null and not exists(select 1 from public.vehicle_maintenance_plans where id=p_plan_id and vehicle_id=p_vehicle_id and public.can_manage_vehicle(vehicle_id)) then raise exception 'Plano indisponível.' using errcode='42501'; end if;
 result=public.create_service_appointment(p_vehicle_id,p_provider_id,p_starts_at,p_duration_minutes,p_description);
 update public.service_appointments set maintenance_plan_id=p_plan_id,
   vehicle_odometer=(select r.odometer from public.vehicles v join public.vehicle_odometer_readings r on r.id=v.odometer_reading_id where v.id=p_vehicle_id)
 where id=result;
 return result;
end $$;

-- A versão sem a checagem não deve ser chamável direto pelos clientes.
revoke all on function public.create_service_appointment(uuid,uuid,timestamptz,integer,text) from public, anon, authenticated;
