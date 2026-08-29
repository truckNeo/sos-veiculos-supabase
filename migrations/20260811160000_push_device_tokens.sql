-- Fundação de push: tokens por usuário e dispositivo, sem credencial Firebase
-- no aplicativo.
create table public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null check (char_length(trim(token)) between 20 and 4096),
  platform text not null check (platform in ('ios', 'android')),
  app_version text,
  last_seen_at timestamptz not null default timezone('utc', now()),
  revoked_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  unique (user_id, token)
);

create index device_push_tokens_active_idx on public.device_push_tokens(user_id)
where revoked_at is null;
alter table public.device_push_tokens enable row level security;
create policy "users manage own push tokens" on public.device_push_tokens
for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.device_push_tokens from anon;
grant select, insert, update, delete on public.device_push_tokens to authenticated;
