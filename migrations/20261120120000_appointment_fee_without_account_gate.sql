-- Como no chamado, o prestador confirma sem conta Asaas aprovada; a trava fica no pagamento (create-asaas-pix).
create or replace function public.confirm_service_appointment(p_id uuid, p_travel_fee_cents integer default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.service_appointments; due timestamptz; charge uuid;
begin
  select * into a from public.service_appointments where id = p_id for update;
  if not found or auth.uid() is distinct from a.provider_id then raise exception 'Agendamento indisponível.' using errcode = '42501'; end if;
  if a.service_mode in ('onsite','pickup') then
    if p_travel_fee_cents is null or p_travel_fee_cents not between 100 and 1000000 then
      raise exception 'Informe a taxa de deslocamento (de R$ 1,00 a R$ 10.000,00).' using errcode = 'P0001'; end if;
    due := least(now() + interval '12 hours', a.starts_at - interval '2 hours');
    if due < now() + interval '15 minutes' then
      raise exception 'O horário está próximo demais para cobrar a taxa de deslocamento.' using errcode = 'P0001'; end if;
    update public.service_appointments set travel_fee_cents = p_travel_fee_cents where id = a.id;
  end if;
  perform public.respond_service_appointment(p_id, 'confirmed');
  if a.service_mode in ('onsite','pickup') then
    insert into public.service_payment_charges(appointment_id, provider_id, kind, amount_cents, status, payment_provider)
    values (a.id, a.provider_id, 'dispatch', p_travel_fee_cents, 'pending', 'asaas')
    on conflict (appointment_id, kind) where appointment_id is not null
    do update set amount_cents = excluded.amount_cents where service_payment_charges.status = 'pending'
    returning id into charge;
    update public.service_appointments set fee_charge_id = charge, payment_due_at = due where id = a.id;
    perform public.notify_appointment(a.requester_id, a.id, 'fee-due', 'Pague a taxa de deslocamento',
      'Pague R$ ' || replace(to_char(p_travel_fee_cents / 100.0, 'FM999999990.00'), '.', ',') || ' até '
      || to_char(due at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI') || ' para garantir o agendamento.');
  end if;
end $$;

