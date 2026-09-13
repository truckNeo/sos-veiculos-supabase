begin;
alter table public.product_notifications add column push_sent_at timestamptz,
  add column push_attempts integer not null default 0,
  add column push_lease_until timestamptz,
  add column push_claim uuid;
create function public.claim_product_notifications()
returns setof public.product_notifications
language sql security definer set search_path = public as $$
  update public.product_notifications n set push_attempts = n.push_attempts + 1,
    push_lease_until = now() + interval '10 minutes', push_claim = gen_random_uuid()
  where n.id in (select id from public.product_notifications
    where push_sent_at is null and push_attempts < 6
      and (push_lease_until is null or push_lease_until < now())
    order by created_at limit 25 for update skip locked)
  returning n.*;
$$;
revoke all on function public.claim_product_notifications() from public;
grant execute on function public.claim_product_notifications() to service_role;
commit;
