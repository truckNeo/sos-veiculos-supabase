import {withSupabase} from 'npm:@supabase/server';

import {hmacDocument, normalizeDigits} from '../_shared/auth.ts';
import {asaasFetch, isAsaasSandbox, parseAsaasError} from '../_shared/asaas.ts';

type AsaasCustomer = {id?: string};
type AsaasPayment = {id?: string; invoiceUrl?: string};
type AsaasPixQrCode = {payload?: string; encodedImage?: string; expirationDate?: string};

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {chargeId, payerDocument} = await request.json() as {chargeId?: string; payerDocument?: string};
    if (!chargeId) return Response.json({message: 'Cobrança inválida.'}, {status: 400});

    const {data: charge, error: chargeError} = await ctx.supabase
      .from('service_payment_charges')
      .select('id, request_id, provider_id, kind, amount_cents, status, asaas_payment_id, pix_ticket_url, pix_copy_paste')
      .eq('id', chargeId).maybeSingle();
    if (chargeError || !charge) return Response.json({message: 'Cobrança não encontrada ou sem permissão.'}, {status: 404});
    if (charge.status === 'awaiting_payment' && charge.asaas_payment_id) {
      return Response.json({chargeId: charge.id, paymentId: charge.asaas_payment_id, ticketUrl: charge.pix_ticket_url, copyPaste: charge.pix_copy_paste});
    }
    if (charge.status !== 'pending') return Response.json({message: 'Esta cobrança não está disponível para pagamento.'}, {status: 409});

    const {data: providerAccount} = await ctx.supabaseAdmin.from('provider_asaas_accounts')
      .select('status').eq('provider_id', charge.provider_id).maybeSingle();
    if (providerAccount?.status !== 'verified') {
      return Response.json({message: 'O cadastro financeiro do prestador ainda não foi aprovado pelo Asaas.'}, {status: 409});
    }

    const document = normalizeDigits(payerDocument ?? '');
    const {data: userResult} = await ctx.supabase.auth.getUser();
    const email = userResult.user?.email;
    const {data: profile} = await ctx.supabase.from('profiles').select('full_name, document_hash, phone, asaas_customer_id').maybeSingle();
    if (!email || !profile || ![11, 14].includes(document.length) || await hmacDocument(document) !== profile.document_hash) {
      return Response.json({message: 'Informe o CPF/CNPJ do titular cadastrado para gerar o PIX.'}, {status: 400});
    }

    // O Asaas exige um customer cadastrado (a Iugu aceitava o pagador inline na fatura).
    let customerId = profile.asaas_customer_id as string | null;
    if (!customerId) {
      const customerResponse = await asaasFetch('/customers', {body: {
        name: profile.full_name, cpfCnpj: document, email,
        mobilePhone: profile.phone ? normalizeDigits(profile.phone) : undefined,
      }});
      if (!customerResponse.ok) {
        return Response.json({message: await parseAsaasError(customerResponse) || 'Não foi possível cadastrar o pagador no Asaas.'}, {status: 502});
      }
      const customer = await customerResponse.json() as AsaasCustomer;
      if (!customer.id) return Response.json({message: 'O Asaas não retornou o id do pagador.'}, {status: 502});
      customerId = customer.id;
      await ctx.supabaseAdmin.from('profiles').update({asaas_customer_id: customerId}).eq('id', userResult.user!.id);
    }

    const description = charge.kind === 'dispatch' ? 'SOS Veículos - deslocamento' : 'SOS Veículos - orçamento final';
    const paymentResponse = await asaasFetch('/payments', {body: {
      customer: customerId, billingType: 'PIX', value: charge.amount_cents / 100,
      dueDate: new Date().toISOString().slice(0, 10), description, externalReference: charge.id,
    }});
    if (!paymentResponse.ok) {
      console.error('create-asaas-pix: payment failed', {status: paymentResponse.status});
      return Response.json({message: await parseAsaasError(paymentResponse) || 'Não foi possível gerar a cobrança PIX.'}, {status: 502});
    }
    const payment = await paymentResponse.json() as AsaasPayment;
    if (!payment.id) return Response.json({message: 'O Asaas não retornou o id da cobrança.'}, {status: 502});

    // Requer uma chave PIX cadastrada na conta mestre; sem isso o endpoint
    // devolve 400 ("Você não possui uma chave Pix cadastrada").
    const qrResponse = await asaasFetch(`/payments/${payment.id}/pixQrCode`);
    const qr = qrResponse.ok ? await qrResponse.json() as AsaasPixQrCode : {};
    if (!qr.payload) {
      console.error('create-asaas-pix: pixQrCode failed', {status: qrResponse.status});
      return Response.json({message: 'A conta Asaas não tem chave PIX cadastrada — configure em Minha Conta.'}, {status: 502});
    }

    // invoiceUrl é uma página http normal (funciona com Linking.openURL no
    // app) com QR + copia-e-cola + status ao vivo — mais robusto do que
    // tentar renderizar o PNG base64 do pixQrCode como link abrível.
    const ticketUrl = payment.invoiceUrl ?? null;
    const {error} = await ctx.supabase.rpc('mark_service_charge_asaas_checkout', {
      p_charge_id: charge.id, p_asaas_payment_id: payment.id,
      p_pix_ticket_url: ticketUrl, p_pix_copy_paste: qr.payload, p_expires_at: qr.expirationDate ?? null,
      p_asaas_sandbox: isAsaasSandbox(),
    });
    if (error) return Response.json({message: 'O PIX foi criado, mas não pôde ser registrado com segurança.'}, {status: 500});
    return Response.json({chargeId: charge.id, paymentId: payment.id, ticketUrl, copyPaste: qr.payload});
  }),
};
