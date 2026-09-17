-- Módulo 7: usuários de homologação para testar motorista x mecânico.
-- Execute SOMENTE no projeto Supabase de desenvolvimento/staging.
--
-- IMPORTANTE:
-- 1. Opcional: substitua o valor de document_secret abaixo pelo mesmo segredo
--    configurado nas Edge Functions do projeto (DOCUMENT_HASH_SECRET).
-- 2. Este script usa a senha temporária 123456.
-- 3. Não execute em produção e não versione o segredo preenchido.
-- 4. O login por telefone não depende do HMAC; CPF/CNPJ depende dele.

create extension if not exists pgcrypto;

do $$
declare
  document_secret text := 'COLE_AQUI_O_DOCUMENT_HASH_SECRET';
  driver_id uuid;
  v_provider_id uuid;
  driver_document_hash text;
  provider_document_hash text;
begin
  driver_document_hash := encode(extensions.hmac('12345678900', document_secret, 'sha256'), 'hex');
  provider_document_hash := encode(extensions.hmac('12345678000199', document_secret, 'sha256'), 'hex');

  select id into driver_id
  from auth.users
  where lower(email) = 'carlos@sosveiculo.demo'
  limit 1;

  if driver_id is null then
    driver_id := gen_random_uuid();
    insert into auth.users (
      id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      driver_id, 'authenticated', 'authenticated', 'carlos@sosveiculo.demo',
      extensions.crypt('123456', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"Carlos Motorista"}'::jsonb, now(), now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('123456', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        banned_until = null,
        deleted_at = null,
        updated_at = now()
    where id = driver_id;
  end if;

  insert into public.profiles (
    id, role, account_kind, full_name, phone, phone_lookup,
    document_hash, document_last4
  ) values (
    driver_id, 'driver', 'individual', 'Carlos Motorista',
    '+5511999998888', '11999998888', driver_document_hash, '8900'
  )
  on conflict (id) do update set
    role = excluded.role,
    account_kind = excluded.account_kind,
    full_name = excluded.full_name,
    phone = excluded.phone,
    phone_lookup = excluded.phone_lookup,
    document_hash = excluded.document_hash,
    document_last4 = excluded.document_last4,
    updated_at = now();

  select id into v_provider_id
  from auth.users
  where lower(email) = 'rafael@sosveiculo.demo'
  limit 1;

  if v_provider_id is null then
    v_provider_id := gen_random_uuid();
    insert into auth.users (
      id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      v_provider_id, 'authenticated', 'authenticated', 'rafael@sosveiculo.demo',
      extensions.crypt('123456', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"Rafael Mecânica Diesel"}'::jsonb, now(), now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('123456', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        banned_until = null,
        deleted_at = null,
        updated_at = now()
    where id = v_provider_id;
  end if;

  insert into public.profiles (
    id, role, account_kind, full_name, phone, phone_lookup,
    document_hash, document_last4
  ) values (
    v_provider_id, 'provider', 'company', 'Rafael Mecânica Diesel',
    '+5511999997777', '11999997777', provider_document_hash, '0199'
  )
  on conflict (id) do update set
    role = excluded.role,
    account_kind = excluded.account_kind,
    full_name = excluded.full_name,
    phone = excluded.phone,
    phone_lookup = excluded.phone_lookup,
    document_hash = excluded.document_hash,
    document_last4 = excluded.document_last4,
    updated_at = now();

  insert into public.provider_profiles (
    provider_id, business_name, legal_name, postal_code, address_street,
    address_number, address_neighborhood, address_city, address_state,
    service_radius_km, is_available, is_verified
  ) values (
    v_provider_id, 'Rafael Mecânica Diesel', 'Rafael Mecânica Diesel LTDA',
    '01001000', 'Praça da Sé', '100', 'Sé', 'São Paulo', 'SP',
    80, true, true
  )
  on conflict (provider_id) do update set
    business_name = excluded.business_name,
    legal_name = excluded.legal_name,
    postal_code = excluded.postal_code,
    address_street = excluded.address_street,
    address_number = excluded.address_number,
    address_neighborhood = excluded.address_neighborhood,
    address_city = excluded.address_city,
    address_state = excluded.address_state,
    service_radius_km = excluded.service_radius_km,
    is_available = excluded.is_available,
    is_verified = excluded.is_verified,
    updated_at = now();

  insert into public.provider_services (provider_id, problem_type)
  values
    (v_provider_id, 'engine'),
    (v_provider_id, 'electrical'),
    (v_provider_id, 'tire')
  on conflict do nothing;
end;
$$;

-- Verificação sem exibir senha nem documentos completos.
select
  u.id,
  u.email,
  u.email_confirmed_at,
  p.role,
  p.full_name,
  p.phone_lookup,
  p.document_last4
from auth.users u
join public.profiles p on p.id = u.id
where lower(u.email) in ('carlos@sosveiculo.demo', 'rafael@sosveiculo.demo')
order by p.role;
