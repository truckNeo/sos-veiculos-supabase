-- Notificações persistentes e realtime para convites de mecânicos favoritos.

create table public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null check (type in ('favorite_mechanic_invite')),
  entity_id uuid not null references public.favorite_mechanic_invites(id) on delete cascade,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  push_attempted_at timestamptz,
  push_sent_at timestamptz,
  push_error text,
  created_at timestamptz not null default timezone('utc', now()),
  unique (recipient_id, type, entity_id)
);

create index app_notifications_recipient_idx
  on public.app_notifications(recipient_id, created_at desc);

alter table public.app_notifications enable row level security;
grant select, update on public.app_notifications to authenticated;

create policy "users can read own notifications"
  on public.app_notifications for select to authenticated
  using (recipient_id = auth.uid());

create policy "users can mark own notifications read"
  on public.app_notifications for update to authenticated
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

create or replace function public.create_favorite_mechanic_invite(p_provider_id uuid)
returns public.favorite_mechanic_invites
language plpgsql security definer set search_path = public
as $$
declare
  result public.favorite_mechanic_invites;
  provider_name text;
  driver_name text;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'driver') then
    raise exception 'Apenas motoristas podem enviar convites.' using errcode = '42501';
  end if;
  select pp.business_name into provider_name
  from public.provider_profiles pp
  where pp.provider_id = p_provider_id and pp.is_available = true;
  if provider_name is null then
    raise exception 'Mecânico não encontrado ou indisponível.' using errcode = '40400';
  end if;
  select full_name into driver_name from public.profiles where id = auth.uid();

  insert into public.favorite_mechanic_invites(driver_id, provider_id, status, responded_at)
  values (auth.uid(), p_provider_id, 'pending', null)
  on conflict (driver_id, provider_id) do update
    set status = 'pending', responded_at = null, updated_at = timezone('utc', now());
  select * into result from public.favorite_mechanic_invites
  where driver_id = auth.uid() and provider_id = p_provider_id;

  insert into public.app_notifications(recipient_id, actor_id, type, entity_id, title, body, data)
  values (
    p_provider_id, auth.uid(), 'favorite_mechanic_invite', result.id,
    'Novo convite de mecânico favorito',
    coalesce(driver_name, 'Um motorista') || ' quer adicionar sua mecânica aos favoritos.',
    jsonb_build_object('type', 'favorite_mechanic_invite', 'inviteId', result.id::text)
  )
  on conflict (recipient_id, type, entity_id) do update set
    title = excluded.title, body = excluded.body, data = excluded.data,
    read_at = null, push_attempted_at = null, push_sent_at = null, push_error = null;
  return result;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'favorite_mechanic_invites'
  ) then
    alter publication supabase_realtime add table public.favorite_mechanic_invites;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_notifications'
  ) then
    alter publication supabase_realtime add table public.app_notifications;
  end if;
end;
$$;

alter table public.favorite_mechanic_invites replica identity full;
alter table public.app_notifications replica identity full;
