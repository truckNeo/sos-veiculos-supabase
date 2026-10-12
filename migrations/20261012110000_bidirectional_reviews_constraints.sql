-- Permite que os dois lados avaliem o mesmo atendimento.
--
-- A migration 20260830110000_bidirectional_reviews.sql adicionou driver_id,
-- mas manteve provider_id NOT NULL e request_id UNIQUE. Com isso a avaliação
-- do prestador sobre o motorista nunca foi gravada: faltava provider_id e,
-- mesmo com ele, a unique por chamado colidia com a avaliação do motorista.
--
-- Modelo de dados, que é o já assumido pelas consultas do app
-- (src/providers/providerReviews.ts e src/reviews/driverReviews.ts):
--   motorista -> prestador : provider_id preenchido, driver_id nulo
--   prestador -> motorista : driver_id preenchido, provider_id nulo
-- Por isso provider_id passa a ser nullable e um CHECK garante que exatamente
-- um dos dois esteja preenchido. Sem esse CHECK, uma avaliação do prestador
-- que trouxesse provider_id apareceria na aba "Recebidas" dele mesmo.

alter table public.reviews
  alter column provider_id drop not null;

-- A unique de request_id é de coluna, então o nome é gerado pelo Postgres.
-- O bloco procura qualquer unique que cubra exatamente (request_id), em vez
-- de confiar no nome, porque o estado do banco remoto não foi conferido.
do $$
declare
  constraint_name text;
begin
  select con.conname into constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'reviews'
    and con.contype = 'u'
    and con.conkey = array[
      (select attnum from pg_attribute
        where attrelid = con.conrelid and attname = 'request_id')
    ]
  limit 1;

  if constraint_name is not null then
    execute format('alter table public.reviews drop constraint %I', constraint_name);
  end if;
end;
$$;

-- Um atendimento aceita no máximo uma avaliação por autor.
alter table public.reviews
  drop constraint if exists reviews_request_reviewer_key;
alter table public.reviews
  add constraint reviews_request_reviewer_key unique (request_id, reviewer_id);

-- Exatamente um lado avaliado por linha.
alter table public.reviews
  drop constraint if exists reviews_single_target_check;
alter table public.reviews
  add constraint reviews_single_target_check
  check ((provider_id is not null) <> (driver_id is not null));
