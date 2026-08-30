-- Avaliações bidirecionais: prestador pode avaliar o motorista.
-- Adicionar driver_id para reviews feitas pelo prestador sobre o motorista.
-- reviewer_id + provider_id = motorista avaliou prestador (existente)
-- reviewer_id + driver_id = prestador avaliou motorista (novo)

alter table public.reviews
  add column if not exists driver_id uuid references auth.users(id);

-- Permitir INSERT para authenticated (prestador avaliando motorista)
drop policy if exists "requester can create review after service" on public.reviews;
create policy "authenticated can insert review"
  on public.reviews for insert to authenticated
  with check (reviewer_id = auth.uid());

-- Expandir SELECT para incluir reviews onde o usuário é o driver avaliado
drop policy if exists "requesters and reviewed providers can read review" on public.reviews;
create policy "participants can read review"
  on public.reviews for select to authenticated
  using (
    reviewer_id = auth.uid()
    OR provider_id = auth.uid()
    OR driver_id = auth.uid()
  );

-- Garantir que INSERT seja permitido
grant insert on public.reviews to authenticated;
grant select on public.reviews to authenticated;
