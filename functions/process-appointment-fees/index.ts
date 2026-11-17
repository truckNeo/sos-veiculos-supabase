import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { refundAppointmentCharge } from "../_shared/appointment-refund.ts";
import { reconcileDispatchTransfer } from "../_shared/dispatch-transfer.ts";
import { reconcilePayment } from "../_shared/payment-reconciliation.ts";

const safeEqual = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

// Conciliação só das taxas de agendamento: pagamentos, reembolsos e repasses.
// Chamada pelo pg_cron (x-cron-secret) quando há trabalho; publicar com --no-verify-jwt.
export default {
  fetch: withSupabase<AsaasDatabase>({ auth: ["secret", "none"] }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    if (ctx.authMode === "none") {
      const expected = Deno.env.get("CRON_SECRET") ?? "";
      if (!expected || !safeEqual(request.headers.get("x-cron-secret") ?? "", expected))
        return Response.json({ message: "Não autorizado." }, { status: 401 });
    }
    const admin = ctx.supabaseAdmin;
    const results = { payments: 0, refunds: 0, transfers: 0 };

    const refunds = await admin
      .from("service_payment_charges")
      .select("id")
      .not("appointment_id", "is", null)
      .not("refund_requested_at", "is", null)
      .eq("status", "paid")
      .order("updated_at")
      .limit(10);
    for (const row of refunds.data ?? []) {
      try {
        await admin.from("service_payment_charges").update({ updated_at: new Date().toISOString() }).eq("id", row.id);
        await refundAppointmentCharge(admin, row.id);
        results.refunds++;
      } catch { /* a próxima rodada tenta de novo */ }
    }

    const pending = await admin
      .from("service_payment_charges")
      .select("id,asaas_payment_id")
      .not("appointment_id", "is", null)
      .in("status", ["awaiting_payment", "paid"])
      .is("settled_at", null)
      .not("asaas_payment_id", "is", null)
      .lt("updated_at", new Date(Date.now() - 2 * 60_000).toISOString())
      .order("updated_at")
      .limit(10);
    for (const row of pending.data ?? []) {
      try {
        await admin.from("service_payment_charges").update({ updated_at: new Date().toISOString() }).eq("id", row.id);
        await reconcilePayment(admin, row.asaas_payment_id!);
        results.payments++;
      } catch { /* ainda pendente */ }
    }

    const transfers = await admin
      .from("service_provider_transfers")
      .select("id")
      .not("appointment_id", "is", null)
      .in("status", ["pending", "processing"])
      .order("updated_at")
      .limit(10);
    for (const row of transfers.data ?? []) {
      try {
        await admin.from("service_provider_transfers").update({ updated_at: new Date().toISOString() }).eq("id", row.id);
        await reconcileDispatchTransfer(admin, row.id);
        results.transfers++;
      } catch { /* fica em conciliação */ }
    }
    return Response.json(results);
  }),
};
