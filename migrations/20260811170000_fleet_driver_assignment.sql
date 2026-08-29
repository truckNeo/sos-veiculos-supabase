-- Atribuição segura de motorista a veículo de transportadora.
create policy "organization managers can read member profiles"
  on public.profiles for select to authenticated
  using (exists (
    select 1 from public.organization_members member
    where member.user_id = profiles.id and public.is_organization_vehicle_manager(member.organization_id)
  ));

create or replace function public.assign_organization_vehicle_driver(
  p_vehicle_id uuid,
  p_driver_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  manager uuid := auth.uid();
  organization uuid;
begin
  select vehicle.organization_id into organization
  from public.vehicles vehicle
  where vehicle.id = p_vehicle_id
  for update;
  if organization is null or not public.is_organization_vehicle_manager(organization) then
    raise exception 'Você não pode gerenciar este veículo.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.organization_members member
    join public.profiles profile on profile.id = member.user_id
    where member.organization_id = organization and member.user_id = p_driver_id
      and member.member_role = 'driver' and profile.role = 'driver'
  ) then
    raise exception 'O motorista não pertence à transportadora.' using errcode = 'P0001';
  end if;
  update public.vehicles set assigned_driver_id = p_driver_id where id = p_vehicle_id;
end;
$$;

revoke all on function public.assign_organization_vehicle_driver(uuid, uuid) from public;
grant execute on function public.assign_organization_vehicle_driver(uuid, uuid) to authenticated;
