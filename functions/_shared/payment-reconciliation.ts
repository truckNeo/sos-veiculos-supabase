import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import { asaasFetch, isAsaasSandbox } from "./asaas.ts";

export async function reconcilePayment(
  admin: SupabaseClient<AsaasDatabase>,
  paymentId: string
) {
  const { data: charge, error } = await admin
    .from("service_payment_charges")
    .select("id,amount_cents,asaas_sandbox")
    .eq("asaas_payment_id", paymentId)
    .maybeSingle();
  if (error) throw new Error("Consulta da cobrança indisponível.");
  if (!charge) return;
  if (charge.asaas_sandbox !== isAsaasSandbox())
    throw new Error("Ambiente financeiro divergente.");
  const response = await asaasFetch(
    `/payments/${encodeURIComponent(paymentId)}`
  );
  if (!response.ok) throw new Error("Pagamento aguarda conciliação.");
  const actual = await response.json();
  if (
    actual.id !== paymentId ||
    actual.externalReference !== charge.id ||
    Math.round(Number(actual.value) * 100) !== charge.amount_cents
  )
    throw new Error("Pagamento divergente.");
  if (
    [
      "REFUNDED",
      "REFUND_REQUESTED",
      "REFUND_IN_PROGRESS",
      "CHARGEBACK_REQUESTED",
      "CHARGEBACK_DISPUTE",
      "AWAITING_CHARGEBACK_REVERSAL",
      "DUNNING_REQUESTED",
    ].includes(actual.status)
  ) {
    const reversal = await admin.rpc("record_payment_reversal", {
      p_charge_id: charge.id,
      p_state: actual.status,
    });
    if (reversal.error) throw new Error("Estorno aguarda conciliação.");
    return;
  }
  if (!["CONFIRMED", "RECEIVED"].includes(actual.status))
    throw new Error("Pagamento não confirmado pelo provedor.");
  const confirmation = await admin.rpc("confirm_asaas_charge_payment", {
    p_asaas_payment_id: paymentId,
    p_end_to_end_id: actual.pixTransaction?.endToEndIdentifier ?? null,
  });
  if (confirmation.error) throw new Error("Confirmação pendente.");
  const details = await admin
    .from("service_payment_charges")
    .update({
      financial_status: actual.status,
      gateway_net_cents: Number.isFinite(actual.netValue)
        ? Math.round(actual.netValue * 100)
        : null,
    })
    .eq("id", charge.id);
  if (details.error) throw new Error("Dados financeiros pendentes.");
  if (actual.status === "RECEIVED") {
    const { error } = await admin
      .from("service_payment_charges")
      .update({ settled_at: new Date().toISOString() })
      .eq("id", charge.id)
      .is("settled_at", null);
    if (error) throw new Error("Liquidação pendente.");
  }
}
