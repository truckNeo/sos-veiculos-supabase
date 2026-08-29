import {withSupabase} from 'npm:@supabase/server';

import {isIuguMockMode} from '../_shared/iugu.ts';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    if (!isIuguMockMode()) return Response.json({message: 'A confirmação simulada só existe no modo de homologação.'}, {status: 404});
    const {chargeId} = await request.json() as {chargeId?: string};
    if (!chargeId) return Response.json({message: 'Cobrança inválida.'}, {status: 400});
    const {data: charge, error: chargeError} = await ctx.supabase.from('service_payment_charges')
      .select('id, status, payment_provider, iugu_invoice_id').eq('id', chargeId).maybeSingle();
    if (chargeError || !charge || charge.payment_provider !== 'iugu' || !charge.iugu_invoice_id?.startsWith('IUGU_MOCK_')) {
      return Response.json({message: 'Cobrança de teste não disponível.'}, {status: 409});
    }
    if (charge.status === 'paid') return Response.json({paid: true, alreadyPaid: true});
    if (charge.status !== 'awaiting_payment') {
      return Response.json({message: 'A cobrança de teste ainda não está aguardando pagamento.'}, {status: 409});
    }
    const {error} = await ctx.supabaseAdmin.rpc('confirm_iugu_charge_payment', {
      p_iugu_invoice_id: charge.iugu_invoice_id, p_iugu_payment_id: `PAYMENT_MOCK_${charge.id.replaceAll('-', '')}`,
    });
    return error ? Response.json({message: 'Não foi possível confirmar o PIX de teste.'}, {status: 500}) : Response.json({paid: true});
  }),
};
