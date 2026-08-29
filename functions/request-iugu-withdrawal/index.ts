import {withSupabase} from 'npm:@supabase/server';

import {isIuguMockMode, parseIuguError, requireIuguProduction, signedIuguFetch} from '../_shared/iugu.ts';

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {amountCents} = await request.json() as {amountCents?: number};
    if (!Number.isInteger(amountCents) || !amountCents || amountCents < 500) return Response.json({message: 'O saque mínimo é R$ 5,00.'}, {status: 400});
    const {data: claimed, error} = await ctx.supabase.rpc('claim_iugu_withdrawal', {p_amount_cents: amountCents});
    const withdrawal = claimed?.[0] as {withdrawal_id?: string; iugu_account_id?: string} | undefined;
    if (error || !withdrawal?.withdrawal_id || !withdrawal.iugu_account_id) return Response.json({message: error?.message ?? 'Não foi possível solicitar o saque.'}, {status: 409});
    try {
      if (isIuguMockMode()) {
        await ctx.supabaseAdmin.from('provider_iugu_withdrawals').update({iugu_withdrawal_id: `WITHDRAW_MOCK_${withdrawal.withdrawal_id.replaceAll('-', '')}`, status: 'requested'}).eq('id', withdrawal.withdrawal_id);
        return Response.json({requested: true, mock: true});
      }
      const {masterToken, privateKey} = requireIuguProduction();
      const response = await signedIuguFetch(`/v1/accounts/${encodeURIComponent(withdrawal.iugu_account_id)}/request_withdraw`, {amount: amountCents / 100}, masterToken, privateKey);
      if (!response.ok) {
        await ctx.supabaseAdmin.from('provider_iugu_withdrawals').update({status: 'manual_review'}).eq('id', withdrawal.withdrawal_id);
        return Response.json({message: await parseIuguError(response) || 'O saque está em revisão.'}, {status: 502});
      }
      const result = await response.json() as {id?: string};
      await ctx.supabaseAdmin.from('provider_iugu_withdrawals').update({iugu_withdrawal_id: result.id ?? null, status: 'requested'}).eq('id', withdrawal.withdrawal_id);
      return Response.json({requested: true});
    } catch {
      await ctx.supabaseAdmin.from('provider_iugu_withdrawals').update({status: 'manual_review'}).eq('id', withdrawal.withdrawal_id);
      return Response.json({message: 'O saque está em revisão financeira.'}, {status: 503});
    }
  }),
};
