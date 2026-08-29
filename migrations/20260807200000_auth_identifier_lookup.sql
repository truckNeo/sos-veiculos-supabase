-- Lookup de telefone usado somente pelas Edge Functions com service role.
-- O documento continua protegido por HMAC e não é pesquisável pelo cliente.

alter table public.profiles
  add column phone_lookup text unique;

create index profiles_phone_lookup_idx on public.profiles(phone_lookup);

drop policy "profile owners can create their profile" on public.profiles;
