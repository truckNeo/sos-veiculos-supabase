-- Exclusão de conta pelo próprio usuário (exigência das lojas e da LGPD).
--
-- Apagar a linha de profiles não é possível para quem tem histórico:
-- service_requests, vehicles e organizations referenciam profiles com
-- `on delete restrict`, e esses registros têm retenção fiscal e contratual.
-- O que se faz aqui é anonimizar os dados pessoais e registrar o pedido; o
-- bloqueio do login é feito pela Edge Function delete-account, que usa a
-- API administrativa do Supabase.

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  requested_at timestamptz not null default timezone('utc', now()),
  anonymized_at timestamptz,
  unique (user_id)
);

alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon, authenticated;
grant select on public.account_deletion_requests to authenticated;

create policy "owner reads own deletion request"
  on public.account_deletion_requests for select to authenticated
  using (user_id = auth.uid());

/**
 * Anonimiza o perfil de quem pediu a exclusão.
 *
 * Recusa enquanto houver atendimento em andamento: encerrar o vínculo no meio
 * de um serviço deixaria a outra parte sem contato e sem como concluir.
 */
create or replace function public.request_account_deletion()
returns void language plpgsql security definer set search_path = public
as $$
declare
  target uuid := auth.uid();
  open_requests integer;
begin
  if target is null then
    raise exception 'Sessão inválida.' using errcode = '28000';
  end if;

  select count(*) into open_requests
  from public.service_requests request
  where (request.requester_id = target or request.selected_provider_id = target)
    and request.workflow_phase not in ('completed', 'cancelled');
  if open_requests > 0 then
    raise exception 'Conclua ou cancele os atendimentos em andamento antes de excluir a conta.'
      using errcode = 'P0001';
  end if;

  update public.profiles
  set full_name = 'Conta removida',
      phone = '',
      document_last4 = '0000',
      -- O hash é único e not null: troca por um valor sem relação com o
      -- documento original, que não permite reidentificar a pessoa.
      document_hash = 'removed-' || target::text,
      avatar_path = null
  where id = target;

  update public.device_push_tokens
  set revoked_at = timezone('utc', now())
  where user_id = target and revoked_at is null;

  insert into public.account_deletion_requests (user_id, anonymized_at)
  values (target, timezone('utc', now()))
  on conflict (user_id) do update set anonymized_at = timezone('utc', now());
end;
$$;

revoke all on function public.request_account_deletion() from public;
grant execute on function public.request_account_deletion() to authenticated;
