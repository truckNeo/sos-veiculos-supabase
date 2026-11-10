import { reconcileWithdrawal } from "../_shared/withdrawal-reconciliation.ts";
import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";

import {
  asaasFetch,
  decryptProviderApiKey,
  parseAsaasError,
  isAsaasSandbox,
} from "../_shared/asaas.ts";

// O saque é a PRÓPRIA subconta puxando o saldo dela pra fora do Asaas — por
// isso a chamada usa a apiKey da subconta (decifrada), nunca a da conta
// mestre. É o único ponto em que guardamos e usamos a chave de terceiros;
// mantenha ASAAS_PROVIDER_TOKEN_ENCRYPTION_KEY só nos secrets da função.

export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    const { amountCents, commandId } = (await request.json()) as {
      amountCents?: number;
      commandId?: string;
    };
    if (
      !Number.isInteger(amountCents) ||
      !amountCents ||
      amountCents < 500 ||
      !commandId ||
      !/^[a-f0-9-]{36}$/i.test(commandId)
    )
      return Response.json(
        { message: "Informe no mínimo R$ 5,00 e uma solicitação válida." },
        { status: 400 }
      );
    const {
      data: { user },
    } = await ctx.supabase.auth.getUser();
    if (!user)
      return Response.json({ message: "Entre novamente." }, { status: 401 });
    const { data: existing } = await ctx.supabaseAdmin
      .from("provider_asaas_withdrawals")
      .select("provider_id,status,amount_cents")
      .eq("id", commandId)
      .maybeSingle();
    if (existing)
      return existing.provider_id === user.id &&
        existing.amount_cents === amountCents
        ? Response.json({ requested: true, status: existing.status })
        : Response.json(
            { message: "Solicitação divergente." },
            { status: 409 }
          );
    const { data: account } = await ctx.supabaseAdmin
      .from("provider_asaas_accounts")
      .select("*")
      .eq("provider_id", user.id)
      .eq("status", "verified")
      .maybeSingle();
    if (account?.sandbox !== isAsaasSandbox() || account.financial_block_reason)
      return Response.json(
        {
          rejected: true,
          message: "Conta ou saldo exige conciliação financeira.",
        },
        { status: 409 }
      );
    if (
      !account?.api_key_ciphertext ||
      !account.api_key_iv ||
      !account.payout_pix_key ||
      !account.payout_pix_type
    )
      return Response.json(
        {
          rejected: true,
          message: "Complete a verificação e cadastre a chave Pix de saque.",
        },
        { status: 409 }
      );
    const { data: withdrawalId, error } = await ctx.supabaseAdmin.rpc(
      "reserve_pix_withdrawal",
      {
        p_provider: user.id,
        p_amount_cents: amountCents,
        p_key: account.payout_pix_key,
        p_key_type: account.payout_pix_type,
        p_command_id: commandId,
      }
    );
    if (error || !withdrawalId)
      return Response.json(
        {
          rejected:
            error?.code === "P0001" && !error.message.includes("registrada"),
          message: error?.message ?? "Saldo indisponível.",
        },
        { status: 409 }
      );
    const w = { ...account, withdrawal_id: withdrawalId };
    try {
      const subaccountKey = await decryptProviderApiKey(
        account.api_key_ciphertext,
        account.api_key_iv
      );
      const balanceResponse = await asaasFetch("/finance/balance", {
        key: subaccountKey,
      });
      const balance = balanceResponse.ok ? await balanceResponse.json() : null;
      if (
        !balance ||
        !Number.isFinite(balance.balance) ||
        Math.round(balance.balance * 100) < amountCents
      ) {
        const failed = await ctx.supabaseAdmin
          .from("provider_asaas_withdrawals")
          .update({ status: "failed" })
          .eq("id", w.withdrawal_id);
        if (failed.error) throw new Error("Falha ao liberar reserva.");
        return Response.json({ requested: true, status: "failed" });
      }
      const response = await asaasFetch("/transfers", {
        key: subaccountKey,
        body: {
          value: amountCents / 100,
          operationType: "PIX",
          description: "Saque SOS Veículos",
          externalReference: w.withdrawal_id,
          pixAddressKey: account.payout_pix_key,
          pixAddressKeyType: account.payout_pix_type,
        },
      });
      if (!response.ok) {
        await ctx.supabaseAdmin
          .from("provider_asaas_withdrawals")
          .update({ status: "manual_review" })
          .eq("id", w.withdrawal_id)
          .eq("status", "requested");
        return Response.json(
          {
            message:
              (await parseAsaasError(response)) || "O saque está em revisão.",
          },
          { status: 502 }
        );
      }
      const result = (await response.json()) as { id?: string };
      // Sem id não há como conciliar um saque que já saiu da subconta. Marcar
      // 'requested' com asaas_transfer_id nulo esconderia isso; o saque vai
      // para revisão, como no caminho de erro.
      if (!result.id) {
        await ctx.supabaseAdmin
          .from("provider_asaas_withdrawals")
          .update({ status: "manual_review" })
          .eq("id", w.withdrawal_id)
          .eq("status", "requested");
        return Response.json(
          {
            message:
              "O saque foi aceito sem identificação e está em revisão financeira.",
          },
          { status: 502 }
        );
      }
      const saved = await ctx.supabaseAdmin
        .from("provider_asaas_withdrawals")
        .update({ asaas_transfer_id: result.id, status: "requested" })
        .eq("id", w.withdrawal_id)
        .in("status", ["requested", "manual_review"]);
      if (saved.error) throw new Error("Referência pendente de conciliação.");
      const status = await reconcileWithdrawal(
        ctx.supabaseAdmin,
        w.withdrawal_id,
        result.id
      );
      return Response.json({ requested: true, status });
    } catch (err) {
      console.error("request-asaas-withdrawal:", err);
      await ctx.supabaseAdmin
        .from("provider_asaas_withdrawals")
        .update({ status: "manual_review" })
        .eq("id", w.withdrawal_id)
        .eq("status", "requested");
      return Response.json(
        { message: "O saque está em revisão financeira." },
        { status: 503 }
      );
    }
  }),
};
