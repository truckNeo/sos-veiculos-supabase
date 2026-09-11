import {withSupabase} from 'npm:@supabase/server';

import {asaasFetch, isAsaasSandbox} from '../_shared/asaas.ts';

// Simula o pagamento do cliente SÓ no sandbox do Asaas, chamando o endpoint
// real de homologação (POST /sandbox/payment/{id}/confirm) — validado no
// scripts/asaas-escrow-poc/. Diferente do "modo mock" da Iugu, isso não é
// uma simulação fabricada: processa split/escrow/eventos como um pagamento
// de verdade dentro do ambiente de testes do Asaas. Em produção este
// endpoint não existe no Asaas e a função recusa de propósito.

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    if (!isAsaasSandbox()) {
      return Response.json({message: 'Simulação de pagamento disponível apenas no ambiente sandbox.'}, {status: 404});
    }
    const {chargeId} = await request.json() as {chargeId?: string};
    if (!chargeId) return Response.json({message: 'Cobrança inválida.'}, {status: 400});

    const {data: charge} = await ctx.supabase.from('service_payment_charges')
      .select('id, status, payment_provider, asaas_payment_id').eq('id', chargeId).maybeSingle();
    if (!charge || charge.payment_provider !== 'asaas' || !charge.asaas_payment_id) {
      return Response.json({message: 'Cobrança de teste não disponível.'}, {status: 409});
    }
    if (charge.status === 'paid') return Response.json({paid: true, alreadyPaid: true});
    if (charge.status !== 'awaiting_payment') {
      return Response.json({message: 'A cobrança ainda não está aguardando pagamento.'}, {status: 409});
    }

    const response = await asaasFetch(`/sandbox/payment/${charge.asaas_payment_id}/confirm`, {body: {}});
    if (!response.ok) {
      return Response.json({message: 'Não foi possível confirmar o pagamento de sandbox.'}, {status: 502});
    }
    // O webhook PAYMENT_RECEIVED confirma de forma assíncrona; chamamos a RPC
    // aqui também pra não depender da latência do webhook durante testes.
    const {error} = await ctx.supabaseAdmin.rpc('confirm_asaas_charge_payment', {p_asaas_payment_id: charge.asaas_payment_id});
    return error
      ? Response.json({message: 'Confirmado no Asaas, mas não foi possível registrar aqui.'}, {status: 500})
      : Response.json({paid: true});
  }),
};
