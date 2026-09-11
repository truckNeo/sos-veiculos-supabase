-- Correção: a política de INSERT não deve consultar o perfil do prestador
-- sob RLS. A FK para provider_profiles garante que o alvo existe e a RPC
-- valida que o usuário autenticado é motorista.

drop policy if exists "drivers can create favorite mechanic invites"
  on public.favorite_mechanic_invites;

create policy "drivers can create favorite mechanic invites"
  on public.favorite_mechanic_invites for insert to authenticated
  with check (driver_id = auth.uid());

alter function public.create_favorite_mechanic_invite(uuid)
  security definer;

alter function public.create_favorite_mechanic_invite(uuid)
  set search_path = public;
