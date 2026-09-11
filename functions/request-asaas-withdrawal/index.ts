import {withSupabase} from 'npm:@supabase/server';

import {asaasFetch, decryptProviderApiKey, parseAsaasError} from '../_shared/asaas.ts';

// O saque é a PRÓPRIA subconta puxando o saldo dela pra fora do Asaas — por
// isso a chamada usa a apiKey da subconta (decifrada), nunca a da conta
// mestre. É o único ponto em que guardamos e usamos a chave de terceiros;
// mantenha ASAAS_PROVIDER_TOKEN_ENCRYPTION_KEY só nos secrets da função.

type AsaasCommercialInfo = {name?: string; cpfCnpj?: string};

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {amountCents} = await request.json() as {amountCents?: number};
    if (!Number.isInteger(amountCents) || !amountCents || amountCents < 500) {
      return Response.json({message: 'O saque mínimo é R$ 5,00.'}, {status: 400});
    }
    const {data: claimed, error} = await ctx.supabase.rpc('claim_asaas_withdrawal', {p_amount_cents: amountCents});
    const w = claimed?.[0] as {
      withdrawal_id?: string; asaas_account_id?: string; api_key_ciphertext?: string; api_key_iv?: string;
      bank_code?: string; bank_agency?: string; bank_account?: string; bank_account_digit?: string; bank_account_type?: string;
    } | undefined;
    if (error || !w?.withdrawal_id || !w.api_key_ciphertext || !w.api_key_iv) {
      return Response.json({message: error?.message ?? 'Não foi possível solicitar o saque.'}, {status: 409});
    }
    try {
      const subaccountKey = await decryptProviderApiKey(w.api_key_ciphertext, w.api_key_iv);
      const infoResponse = await asaasFetch('/myAccount/commercialInfo', {key: subaccountKey});
      const info = infoResponse.ok ? await infoResponse.json() as AsaasCommercialInfo : {};

      const response = await asaasFetch('/transfers', {key: subaccountKey, body: {
        value: amountCents / 100,
        operationType: 'PIX',
        description: 'Saque SOS Veículos',
        externalReference: w.withdrawal_id,
        bankAccount: {
          bank: {code: w.bank_code},
          accountName: info.name ?? 'Prestador',
          ownerName: info.name ?? 'Prestador',
          cpfCnpj: info.cpfCnpj,
          agency: w.bank_agency,
          account: w.bank_account,
          accountDigit: w.bank_account_digit,
          bankAccountType: w.bank_account_type,
        },
      }});
      if (!response.ok) {
        await ctx.supabaseAdmin.from('provider_asaas_withdrawals').update({status: 'manual_review'}).eq('id', w.withdrawal_id);
        return Response.json({message: await parseAsaasError(response) || 'O saque está em revisão.'}, {status: 502});
      }
      const result = await response.json() as {id?: string};
      await ctx.supabaseAdmin.from('provider_asaas_withdrawals').update({asaas_transfer_id: result.id ?? null, status: 'requested'}).eq('id', w.withdrawal_id);
      return Response.json({requested: true});
    } catch (err) {
      console.error('request-asaas-withdrawal:', err);
      await ctx.supabaseAdmin.from('provider_asaas_withdrawals').update({status: 'manual_review'}).eq('id', w.withdrawal_id);
      return Response.json({message: 'O saque está em revisão financeira.'}, {status: 503});
    }
  }),
};
