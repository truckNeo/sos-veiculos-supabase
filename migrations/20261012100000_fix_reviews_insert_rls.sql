-- Corrige a política de INSERT em public.reviews.
--
-- A migration 20260830110000_bidirectional_reviews.sql substituiu a política
-- original, que exigia participação no chamado, por `reviewer_id = auth.uid()`.
-- Com isso qualquer usuário autenticado passou a conseguir inserir avaliação em
-- qualquer chamado. Como reviews.request_id é UNIQUE, isso também permitia
-- bloquear de forma permanente a avaliação legítima daquele atendimento.
--
-- A autorização fica numa função SECURITY DEFINER, no mesmo padrão de
-- is_request_participant e can_access_vehicle. Isso é necessário porque dentro
-- de uma policy o EXISTS roda sob a RLS do chamador: o prestador só enxerga
-- service_requests via is_request_participant, que depende de provider_offers.
-- Avaliar a regra numa função definer desacopla a autorização da visibilidade.
--
-- Formatos válidos:
--   motorista  -> prestador : reviewer = requester_id         e provider_id = selected_provider_id
--   prestador  -> motorista : reviewer = selected_provider_id e driver_id    = requester_id
-- Nos dois casos o atendimento precisa ter chegado à conferência do motorista.
--
-- Observação: as avaliações feitas pelo motorista hoje são gravadas dentro de
-- funções SECURITY DEFINER (complete_service_with_review e
-- release_service_payment), que não passam por RLS. A política client-side
-- cobre na prática o prestador avaliando o motorista.
--
-- Esta migration trata apenas da autorização. A constraint UNIQUE(request_id)
-- continua impedindo que os dois lados avaliem o mesmo chamado; isso é tratado
-- separadamente, junto com provider_id nullable.

create or replace function public.can_review_service_request(
  target_request_id uuid,
  target_provider_id uuid,
  target_driver_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.service_requests request
    where request.id = target_request_id
      and request.workflow_phase in (
        'awaiting_driver_confirmation',
        'release_processing',
        'in_dispute',
        'completed'
      )
      and (
        -- motorista avaliando o prestador do atendimento
        (
          request.requester_id = auth.uid()
          and target_provider_id = request.selected_provider_id
          and target_driver_id is null
        )
        or
        -- prestador selecionado avaliando o motorista
        (
          request.selected_provider_id = auth.uid()
          and target_driver_id = request.requester_id
        )
      )
  );
$$;

revoke all on function public.can_review_service_request(uuid, uuid, uuid) from public;
grant execute on function public.can_review_service_request(uuid, uuid, uuid) to authenticated;

drop policy if exists "authenticated can insert review" on public.reviews;

create policy "participants can create review after service"
  on public.reviews for insert to authenticated
  with check (
    reviewer_id = auth.uid()
    and public.can_review_service_request(request_id, provider_id, driver_id)
  );
