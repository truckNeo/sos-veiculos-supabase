import {reconcilePayment} from '../_shared/payment-reconciliation.ts';
import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";

import { ensurePaymentCustomer } from "../_shared/payment-customer.ts";
import { asaasFetch, isAsaasSandbox } from "../_shared/asaas.ts";

type AsaasPayment = {
  id?: string;
  invoiceUrl?: string;
  externalReference?: string;
  customer?: string;
  value?: number;
  billingType?: string;
  status?: string;
};
type AsaasPixQrCode = {
  payload?: string;
  encodedImage?: string;
  expirationDate?: string;
};

export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST")
      return Response.json({ message: "Método inválido." }, { status: 405 });
    const {
      chargeId,
      payerDocument,
      paymentMethod = "PIX",
    } = (await request.json()) as {
      chargeId?: string;
      payerDocument?: string;
      paymentMethod?: string;
    };
    if (!["PIX", "CREDIT_CARD", "DEBIT_CARD"].includes(paymentMethod))
      return Response.json(
        { message: "Forma de pagamento inválida." },
        { status: 400 }
      );
    if (!chargeId)
      return Response.json({ message: "Cobrança inválida." }, { status: 400 });

    const { data: charge, error: chargeError } = await ctx.supabase
      .from("service_payment_charges")
      .select(
        "id, request_id, provider_id, kind, amount_cents, status, asaas_payment_id, pix_ticket_url, pix_copy_paste, asaas_checkout_claimed_at, asaas_sandbox, billing_method"
      )
      .eq("id", chargeId)
      .maybeSingle();
    if (chargeError || !charge)
      return Response.json(
        { message: "Cobrança não encontrada ou sem permissão." },
        { status: 404 }
      );
    if (
      (charge.status === "awaiting_payment" ||
        charge.asaas_checkout_claimed_at) &&
      charge.asaas_sandbox !== isAsaasSandbox()
    ) {
      return Response.json(
        { message: "Esta cobrança pertence a outro ambiente financeiro." },
        { status: 409 }
      );
    }
    if (charge.asaas_payment_id && charge.billing_method !== paymentMethod)
      return Response.json(
        {
          message:
            "Já existe uma cobrança com outra forma de pagamento para este deslocamento.",
        },
        { status: 409 }
      );
    if (
      charge.status === "awaiting_payment" &&
      charge.asaas_payment_id &&
      charge.billing_method !== "PIX"
    )
      return Response.json({
        chargeId: charge.id,
        paymentId: charge.asaas_payment_id,
        ticketUrl: charge.pix_ticket_url,
        copyPaste: null,
        qrCode: null,
      });
    if (charge.status === "awaiting_payment" && charge.asaas_payment_id) {
      const response = await asaasFetch(
        `/payments/${charge.asaas_payment_id}/pixQrCode`
      );
      const qr = response.ok ? ((await response.json()) as AsaasPixQrCode) : {};
      return Response.json({
        chargeId: charge.id,
        paymentId: charge.asaas_payment_id,
        ticketUrl: charge.pix_ticket_url,
        copyPaste: charge.pix_copy_paste ?? qr.payload ?? null,
        qrCode: qr.encodedImage ?? null,
      });
    }
    if (charge.kind !== "dispatch")
      return Response.json(
        { message: "Somente deslocamento está disponível para pagamento." },
        { status: 409 }
      );
    if (charge.status !== "pending")
      return Response.json(
        { message: "Esta cobrança não está disponível para pagamento." },
        { status: 409 }
      );

    const { data: providerAccount } = await ctx.supabaseAdmin
      .from("provider_asaas_accounts")
      .select("status,sandbox")
      .eq("provider_id", charge.provider_id)
      .maybeSingle();
    if (providerAccount?.status !== "verified" || providerAccount.sandbox !== isAsaasSandbox()) {
      return Response.json(
        {
          message:
            "O cadastro financeiro do prestador ainda não foi aprovado pelo Asaas.",
        },
        { status: 409 }
      );
    }

    const { data: userResult } = await ctx.supabase.auth.getUser();
    if (!userResult.user?.email)
      return Response.json({ message: "Sessão inválida." }, { status: 401 });
    let customerId: string;
    try {
      customerId = await ensurePaymentCustomer(
        ctx.supabaseAdmin,
        userResult.user.id,
        userResult.user.email,
        payerDocument
      );
    } catch (error) {
      return Response.json(
        {
          message:
            error instanceof Error
              ? error.message
              : "Cadastro financeiro indisponível.",
        },
        { status: 409 }
      );
    }
    const billingType =
      paymentMethod === "DEBIT_CARD" ? "UNDEFINED" : paymentMethod;
    const { data: claimed, error: claimError } = await ctx.supabaseAdmin.rpc(
      "claim_asaas_charge_checkout",
      {
        p_charge_id: charge.id,
        p_requester_id: userResult.user!.id,
        p_sandbox: isAsaasSandbox(),
      }
    );
    if (claimError)
      return Response.json(
        { message: "Não foi possível reservar esta cobrança para emissão." },
        { status: 409 }
      );
    let payment: AsaasPayment;
    try {
      if (claimed === true) {
        const response = await asaasFetch("/payments", {
          body: {
            customer: customerId,
            billingType,
            value: charge.amount_cents / 100,
            dueDate: new Date().toISOString().slice(0, 10),
            description: "SOS Veículos - deslocamento",
            externalReference: charge.id,
          },
        });
        if (!response.ok)
          return Response.json(
            {
              message:
                "A emissão não foi confirmada. Consulte o suporte antes de tentar emitir outra cobrança.",
            },
            { status: 502 }
          );
        payment = (await response.json()) as AsaasPayment;
      } else {
        const response = await asaasFetch(
          `/payments?externalReference=${encodeURIComponent(charge.id)}&limit=2`
        );
        const matches = response.ok
          ? ((await response.json()) as {
              data?: AsaasPayment[];
              hasMore?: boolean;
            })
          : {};
        if (matches.hasMore || matches.data?.length !== 1) {
          return Response.json(
            {
              message:
                "A emissão anterior precisa de conciliação. Aguarde e consulte novamente ou procure o suporte.",
            },
            { status: 409 }
          );
        }
        payment = matches.data[0];
        if (
          payment.externalReference !== charge.id ||
          payment.customer !== customerId ||
          payment.billingType !== billingType ||
          Math.round(Number(payment.value) * 100) !== charge.amount_cents ||
          !["PENDING", "OVERDUE", "CONFIRMED", "RECEIVED"].includes(payment.status ?? "")
        ) {
          return Response.json(
            {
              message:
                "A cobrança encontrada exige conferência financeira pelo suporte.",
            },
            { status: 409 }
          );
        }
      }
      if (!payment.id)
        return Response.json(
          {
            message:
              "A emissão não retornou identificação. Solicite conciliação ao suporte.",
          },
          { status: 502 }
        );
      // Guarda o id antes de buscar QR; falhas nessa consulta não recriam a cobrança.
      const { error: saveError } = await ctx.supabaseAdmin
        .from("service_payment_charges")
        .update({
          asaas_payment_id: payment.id,
          payment_provider: "asaas",
          billing_method: paymentMethod,
        })
        .eq("id", charge.id)
        .eq("status", "pending");
      if (saveError)
        return Response.json(
          {
            message:
              "O PIX foi emitido, mas precisa de conciliação. Consulte novamente.",
          },
          { status: 500 }
        );
    } catch {
      return Response.json(
        {
          message:
            "Não foi possível confirmar a emissão. Consulte novamente; nenhuma nova cobrança será enviada automaticamente.",
        },
        { status: 502 }
      );
    }

    if (["CONFIRMED", "RECEIVED"].includes(payment.status ?? "")) {
      const saved=await ctx.supabaseAdmin.from('service_payment_charges').update({status:'awaiting_payment'}).eq('id',charge.id).eq('status','pending');
      if(saved.error)return Response.json({message:'Pagamento aguarda conciliação.'},{status:503});
      try {await reconcilePayment(ctx.supabaseAdmin,payment.id!);}catch{return Response.json({message:'Pagamento aguarda conciliação.'},{status:503});}
      return Response.json({chargeId:charge.id,paymentId:payment.id,paid:true,ticketUrl:payment.invoiceUrl??null,copyPaste:null,qrCode:null});
    }

    if (paymentMethod !== "PIX") {
      if (!payment.invoiceUrl)
        return Response.json(
          { message: "Checkout criado; aguarde a conciliação do link." },
          { status: 503 }
        );
      const { error } = await ctx.supabaseAdmin.rpc(
        "mark_service_charge_checkout",
        {
          p_charge_id: charge.id,
          p_payment_id: payment.id!,
          p_method: paymentMethod,
          p_url: payment.invoiceUrl,
          p_sandbox: isAsaasSandbox(),
        }
      );
      return error
        ? Response.json(
            { message: "Checkout aguarda conciliação." },
            { status: 503 }
          )
        : Response.json({
            chargeId: charge.id,
            paymentId: payment.id,
            ticketUrl: payment.invoiceUrl,
            copyPaste: null,
            qrCode: null,
          });
    }
    // Requer uma chave PIX cadastrada na conta mestre; sem isso o endpoint
    // devolve 400 ("Você não possui uma chave Pix cadastrada").
    const qrResponse = await asaasFetch(`/payments/${payment.id}/pixQrCode`);
    const qr = qrResponse.ok
      ? ((await qrResponse.json()) as AsaasPixQrCode)
      : {};
    if (!qr.payload) {
      console.error("create-asaas-pix: pixQrCode failed", {
        status: qrResponse.status,
      });
      return Response.json(
        {
          message:
            "O PIX foi emitido, mas o código ainda não está disponível. Consulte novamente ou procure o suporte.",
        },
        { status: 502 }
      );
    }

    // A fatura é opcional: QR e código ficam disponíveis diretamente no app.
    const ticketUrl = payment.invoiceUrl ?? null;
    const { error } = await ctx.supabase.rpc(
      "mark_service_charge_asaas_checkout",
      {
        p_charge_id: charge.id,
        p_asaas_payment_id: payment.id,
        p_pix_ticket_url: ticketUrl,
        p_pix_copy_paste: qr.payload,
        p_expires_at: qr.expirationDate ?? null,
        p_asaas_sandbox: isAsaasSandbox(),
      }
    );
    if (error)
      return Response.json(
        {
          message:
            "O PIX foi criado, mas não pôde ser registrado com segurança.",
        },
        { status: 500 }
      );
    return Response.json({
      chargeId: charge.id,
      paymentId: payment.id,
      ticketUrl,
      copyPaste: qr.payload,
      qrCode: qr.encodedImage ?? null,
    });
  }),
};
