create or replace function public.prevent_paid_dispatch_cancellation()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'cancelled'::public.service_request_status
    and old.workflow_phase = 'awaiting_dispatch_payment'
    and (
      exists (
        select 1 from public.service_payment_charges charge
        where charge.request_id = old.id
          and charge.kind = 'dispatch'
          and charge.status = 'paid'
      )
      or exists (
        select 1 from public.request_attachments attachment
        where attachment.request_id = old.id
          and attachment.kind::text = 'payment_receipt'
      )
    ) then
    raise exception 'O chamado não pode ser cancelado após o pagamento ou envio do comprovante PIX.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists service_requests_protect_paid_cancellation on public.service_requests;
create trigger service_requests_protect_paid_cancellation
  before update of status on public.service_requests
  for each row execute function public.prevent_paid_dispatch_cancellation();
