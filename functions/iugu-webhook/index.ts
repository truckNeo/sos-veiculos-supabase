import {withSupabase} from 'npm:@supabase/server';

import {iuguBasicAuthorization, iuguToken} from '../_shared/iugu.ts';

const secureEqual = (left: string, right: string) => {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference += Math.abs(left.charCodeAt(index) - right.charCodeAt(index));
  return difference === 0;
};

export default {
  fetch: withSupabase({auth: 'none'}, async (request, ctx) => {
    const secret = Deno.env.get('IUGU_WEBHOOK_BASIC_TOKEN');
    const {token} = iuguToken();
    if (!secret || !token) return Response.json({message: 'Webhook Iugu não configurado.'}, {status: 503});
    const expected = `Basic ${btoa(`${secret}:`)}`;
    if (!secureEqual(request.headers.get('authorization') ?? '', expected)) return Response.json({message: 'Não autorizado.'}, {status: 401});
    const form = await request.formData();
    const event = String(form.get('event') ?? '');
    const invoiceId = String(form.get('data[id]') ?? '');
    if (event.startsWith('referrals.')) {
      const accountId = String(form.get('data[account_id]') ?? '');
      const status = String(form.get('data[status]') ?? '').toLowerCase();
      if (accountId) {
        const update = status.includes('accept') || status.includes('verif')
          ? {status: 'verified', verified_at: new Date().toISOString(), rejection_reason: null}
          : status.includes('reject')
            ? {status: 'rejected', rejection_reason: String(form.get('data[reason]') ?? 'Documentação recusada.').slice(0, 1000)}
            : null;
        if (update) await ctx.supabaseAdmin.from('provider_iugu_accounts').update(update).eq('iugu_account_id', accountId);
      }
      return Response.json({received: true});
    }
    if (!invoiceId || !['invoice.status_changed', 'invoice.released'].includes(event)) return Response.json({received: true});
    const invoiceResponse = await fetch(`https://api.iugu.com/v1/invoices/${encodeURIComponent(invoiceId)}`, {
      headers: {Accept: 'application/json', Authorization: iuguBasicAuthorization(token)},
    });
    if (!invoiceResponse.ok) return Response.json({message: 'Não foi possível confirmar a fatura Iugu.'}, {status: 502});
    const invoice = await invoiceResponse.json() as {status?: string; id?: string; transaction_number?: string | number};
    if (invoice.status === 'paid' && invoice.id) {
      const {error} = await ctx.supabaseAdmin.rpc('confirm_iugu_charge_payment', {
        p_iugu_invoice_id: invoice.id, p_iugu_payment_id: invoice.transaction_number?.toString() ?? null,
      });
      if (error) return Response.json({message: 'Não foi possível confirmar a cobrança.'}, {status: 500});
    }
    return Response.json({received: true});
  }),
};
