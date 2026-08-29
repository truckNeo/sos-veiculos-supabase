import {withSupabase} from 'npm:@supabase/server';

import {hmacDocument, normalizeDigits} from '../_shared/auth.ts';
import {isIuguMockMode, iuguBasicAuthorization, iuguToken, parseIuguError} from '../_shared/iugu.ts';

type IuguInvoice = {
  id?: string;
  pix?: {qrcode?: string; qrcode_text?: string};
  expired_at_iso?: string | null;
};

const dueDate = () => new Date().toISOString().slice(0, 10);

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    const {chargeId, payerDocument} = await request.json() as {chargeId?: string; payerDocument?: string};
    const {token} = iuguToken();
    if (!token && !isIuguMockMode()) return Response.json({message: 'O PIX Iugu ainda não está configurado para este ambiente.'}, {status: 503});
    if (!chargeId) return Response.json({message: 'Cobrança inválida.'}, {status: 400});

    const {data: charge, error: chargeError} = await ctx.supabase
      .from('service_payment_charges')
      .select('id, request_id, provider_id, kind, amount_cents, status, iugu_invoice_id, pix_ticket_url, pix_copy_paste')
      .eq('id', chargeId).maybeSingle();
    if (chargeError || !charge) return Response.json({message: 'Cobrança não encontrada ou sem permissão.'}, {status: 404});
    if (charge.status === 'awaiting_payment' && charge.iugu_invoice_id) {
      return Response.json({chargeId: charge.id, invoiceId: charge.iugu_invoice_id, ticketUrl: charge.pix_ticket_url, copyPaste: charge.pix_copy_paste});
    }
    if (charge.status !== 'pending') return Response.json({message: 'Esta cobrança não está disponível para pagamento.'}, {status: 409});

    if (isIuguMockMode()) {
      const invoiceId = `IUGU_MOCK_${charge.id.replaceAll('-', '')}`;
      const copyPaste = `PIX DE TESTE SOS VEICULOS ${charge.amount_cents} CENTAVOS`;
      const {error} = await ctx.supabase.rpc('mark_service_charge_iugu_checkout', {
        p_charge_id: charge.id, p_iugu_invoice_id: invoiceId, p_pix_ticket_url: null,
        p_pix_copy_paste: copyPaste, p_expires_at: null,
      });
      return error
        ? Response.json({message: 'Não foi possível criar a cobrança de teste.'}, {status: 500})
        : Response.json({chargeId: charge.id, invoiceId, ticketUrl: null, copyPaste, mock: true});
    }
    if (!token) return Response.json({message: 'O PIX Iugu ainda não está configurado para este ambiente.'}, {status: 503});

    const document = normalizeDigits(payerDocument ?? '');
    const {data: userResult} = await ctx.supabase.auth.getUser();
    const email = userResult.user?.email;
    const {data: profile} = await ctx.supabase.from('profiles').select('full_name, document_hash').maybeSingle();
    if (!email || !profile || ![11, 14].includes(document.length) || await hmacDocument(document) !== profile.document_hash) {
      return Response.json({message: 'Informe o CPF/CNPJ do titular cadastrado para gerar o PIX.'}, {status: 400});
    }
    const {data: iuguAccount} = await ctx.supabaseAdmin.from('provider_iugu_accounts')
      .select('status').eq('provider_id', charge.provider_id).maybeSingle();
    if (iuguAccount?.status !== 'verified') {
      return Response.json({message: 'O cadastro financeiro do prestador ainda não foi aprovado pela Iugu.'}, {status: 409});
    }

    const webhookUrl = Deno.env.get('IUGU_WEBHOOK_URL')
      ?? `${Deno.env.get('SUPABASE_URL')}/functions/v1/iugu-webhook`;
    const description = charge.kind === 'dispatch' ? 'SOS Veículos - deslocamento' : 'SOS Veículos - orçamento final';
    const response = await fetch('https://api.iugu.com/v1/invoices', {
      method: 'POST',
      headers: {Accept: 'application/json', 'Content-Type': 'application/json', Authorization: iuguBasicAuthorization(token)},
      body: JSON.stringify({
        email, due_date: dueDate(), expires_in: '1', payable_with: ['pix'],
        items: [{description, quantity: 1, price_cents: charge.amount_cents}],
        payer: {name: profile.full_name, cpf_cnpj: document},
        external_reference: charge.id, notification_url: webhookUrl, ignore_due_email: true,
      }),
    });
    if (!response.ok) {
      console.error('create-iugu-pix: invoice failed', {status: response.status});
      return Response.json({message: await parseIuguError(response) || 'Não foi possível gerar o PIX Iugu.'}, {status: 502});
    }
    const invoice = await response.json() as IuguInvoice;
    if (!invoice.id || !invoice.pix?.qrcode_text) return Response.json({message: 'A Iugu não retornou um QR Code PIX válido.'}, {status: 502});
    const {error} = await ctx.supabase.rpc('mark_service_charge_iugu_checkout', {
      p_charge_id: charge.id, p_iugu_invoice_id: invoice.id, p_pix_ticket_url: invoice.pix.qrcode ?? null,
      p_pix_copy_paste: invoice.pix.qrcode_text, p_expires_at: invoice.expired_at_iso ?? null,
    });
    if (error) return Response.json({message: 'O PIX foi criado, mas não pôde ser registrado com segurança.'}, {status: 500});
    return Response.json({chargeId: charge.id, invoiceId: invoice.id, ticketUrl: invoice.pix.qrcode ?? null, copyPaste: invoice.pix.qrcode_text});
  }),
};
