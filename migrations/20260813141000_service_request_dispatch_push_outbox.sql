create table public.service_request_dispatch_push_outbox (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null unique references public.service_request_dispatches(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);
create trigger service_request_dispatch_push_outbox_set_updated_at before update on public.service_request_dispatch_push_outbox
  for each row execute function public.set_updated_at();
alter table public.service_request_dispatch_push_outbox enable row level security;
revoke all on public.service_request_dispatch_push_outbox from anon, authenticated;

create or replace function public.enqueue_service_request_dispatch_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.service_request_dispatch_push_outbox (dispatch_id)
  values (new.id) on conflict (dispatch_id) do nothing;
  return new;
end;
$$;
create trigger service_request_dispatches_enqueue_push
  after insert on public.service_request_dispatches
  for each row execute function public.enqueue_service_request_dispatch_push();
