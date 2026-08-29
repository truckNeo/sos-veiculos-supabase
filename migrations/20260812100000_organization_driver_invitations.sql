-- Convite e vínculo de motoristas em transportadoras.
create extension if not exists pgcrypto;
create table public.organization_driver_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null,
  token_hash text not null unique,
  invited_by uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  expires_at timestamptz not null default timezone('utc', now()) + interval '7 days',
  accepted_by uuid references public.profiles(id) on delete set null,
  accepted_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);
create unique index organization_pending_driver_invitation_idx
  on public.organization_driver_invitations(organization_id, lower(email)) where status = 'pending';
alter table public.organization_driver_invitations enable row level security;
create policy "managers read organization invitations" on public.organization_driver_invitations
for select to authenticated using (public.is_organization_vehicle_manager(organization_id) or accepted_by = auth.uid());
revoke all on public.organization_driver_invitations from authenticated;
grant select on public.organization_driver_invitations to authenticated;

create or replace function public.invite_organization_driver(p_email text)
returns table (invitation_id uuid, invitation_token text, expires_at timestamptz)
language plpgsql security definer set search_path = public
as $$
declare manager uuid := auth.uid(); org uuid; token text := encode(gen_random_bytes(32), 'hex'); invitation uuid; expiration timestamptz := timezone('utc', now()) + interval '7 days';
begin
  select organization_id into org from public.organization_members where user_id = manager and member_role in ('owner', 'manager') limit 1;
  if org is null then select id into org from public.organizations where owner_id = manager; end if;
  if org is null then raise exception 'Você não gerencia uma transportadora.' using errcode = '42501'; end if;
  if p_email is null or p_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Informe um e-mail válido.' using errcode = '22023'; end if;
  if exists (select 1 from auth.users account join public.organization_members member on member.user_id = account.id where member.organization_id = org and lower(account.email) = lower(trim(p_email))) then raise exception 'Este motorista já pertence à transportadora.' using errcode = '23505'; end if;
  update public.organization_driver_invitations set status = 'revoked' where organization_id = org and lower(email) = lower(trim(p_email)) and status = 'pending';
  insert into public.organization_driver_invitations(organization_id, email, token_hash, invited_by, expires_at)
  values (org, lower(trim(p_email)), encode(digest(token, 'sha256'), 'hex'), manager, expiration) returning id into invitation;
  return query select invitation, token, expiration;
end;
$$;

create or replace function public.accept_organization_driver_invitation(p_token text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare user_id uuid := auth.uid(); invitation public.organization_driver_invitations; user_email text; begin
  if user_id is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  select email into user_email from auth.users where id = user_id;
  select * into invitation from public.organization_driver_invitations where token_hash = encode(digest(trim(p_token), 'sha256'), 'hex') and status = 'pending' and expires_at > timezone('utc', now()) for update;
  if invitation.id is null then raise exception 'Convite inválido ou expirado.' using errcode = 'P0001'; end if;
  if lower(user_email) <> lower(invitation.email) then raise exception 'Entre com o e-mail que recebeu o convite.' using errcode = '42501'; end if;
  insert into public.organization_members(organization_id, user_id, member_role) values (invitation.organization_id, user_id, 'driver') on conflict do nothing;
  update public.organization_driver_invitations set status = 'accepted', accepted_by = user_id, accepted_at = timezone('utc', now()) where id = invitation.id;
  return invitation.organization_id;
end;
$$;

create or replace function public.remove_organization_driver(p_driver_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare manager uuid := auth.uid(); org uuid; begin
  select member.organization_id into org from public.organization_members member where member.user_id = manager and member.member_role in ('owner','manager') limit 1;
  if org is null then select id into org from public.organizations where owner_id = manager; end if;
  if org is null or not exists (select 1 from public.organization_members where organization_id = org and user_id = p_driver_id and member_role = 'driver') then raise exception 'Motorista não encontrado na transportadora.' using errcode = '42501'; end if;
  update public.vehicles set assigned_driver_id = null where organization_id = org and assigned_driver_id = p_driver_id;
  delete from public.organization_members where organization_id = org and user_id = p_driver_id and member_role = 'driver';
end;
$$;

revoke all on function public.invite_organization_driver(text), public.accept_organization_driver_invitation(text), public.remove_organization_driver(uuid) from public;
grant execute on function public.invite_organization_driver(text), public.accept_organization_driver_invitation(text), public.remove_organization_driver(uuid) to authenticated;
