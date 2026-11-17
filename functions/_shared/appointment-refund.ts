import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import { asaasFetch, isAsaasSandbox } from "./asaas.ts";
import { reconcilePayment } from "./payment-reconciliation.ts";

export type RefundResult = {
  state: "refunded" | "processing" | "skipped" | "manual_review";
};

const REFUND_STATES = ["REFUNDED", "REFUND_REQUESTED", "REFUND_IN_PROGRESS"];

/**
 * Devolve ao motorista a taxa de um agendamento (reembolso integral pedido no banco).
 * Nunca estorna depois do repasse ao prestador; o Asaas confirma pelo webhook
 * (PAYMENT_REFUNDED), que também passa por aqui via reconcilePayment.
 */
export async function refundAppointmentCharge(
  admin: SupabaseClient<AsaasDatabase>,
  chargeId: string
): Promise<RefundResult> {
  const { data: charge, error } = await admin
    .from("service_payment_charges")
    .select("id,status,asaas_payment_id,asaas_sandbox,refund_requested_at,appointment_id")
    .eq("id", chargeId)
    .single();
  if (error || !charge) throw new Error("Cobrança não encontrada.");
  if (!charge.appointment_id || !charge.refund_requested_at || !charge.asaas_payment_id)
    return { state: "skipped" };
  if (charge.status === "cancelled") return { state: "refunded" };
  if (charge.status !== "paid") return { state: "skipped" };
  if (charge.asaas_sandbox !== isAsaasSandbox()) return { state: "manual_review" };

  const { data: transfer, error: transferError } = await admin
    .from("service_provider_transfers")
    .select("id")
    .eq("appointment_id", charge.appointment_id)
    .maybeSingle();
  if (transferError) throw new Error("Consulta indisponível.");
  if (transfer) return { state: "manual_review" };

  const paymentId = charge.asaas_payment_id;
  const current = await asaasFetch(`/payments/${encodeURIComponent(paymentId)}`);
  if (!current.ok) return { state: "processing" };
  const status = ((await current.json()) as { status?: string }).status ?? "";
  if (!REFUND_STATES.includes(status)) {
    if (!["CONFIRMED", "RECEIVED"].includes(status)) return { state: "manual_review" };
    const response = await asaasFetch(`/payments/${encodeURIComponent(paymentId)}/refund`, {
      body: { description: "Reembolso da taxa de deslocamento" },
    });
    if (!response.ok) {
      console.error("refund-appointment-fee: Asaas recusou o estorno", { status: response.status });
      return { state: "manual_review" };
    }
  }
  try {
    await reconcilePayment(admin, paymentId);
  } catch {
    return { state: "processing" };
  }
  const { data: after } = await admin
    .from("service_payment_charges")
    .select("status")
    .eq("id", charge.id)
    .single();
  return { state: after?.status === "cancelled" ? "refunded" : "processing" };
}
