import { findTransferByReference } from "./transfer-lookup.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import { asaasFetch, decryptProviderApiKey, isAsaasSandbox } from "./asaas.ts";

export async function reconcileWithdrawal(
  admin: SupabaseClient<AsaasDatabase>,
  id: string,
  notifiedId?: string
) {
  const { data: withdrawal, error } = await admin
    .from("provider_asaas_withdrawals")
    .select("*")
    .eq("id", id)
    .single();
  if (error || !withdrawal) throw new Error("Saque não encontrado.");
  if (["paid", "failed"].includes(withdrawal.status)) return withdrawal.status;
  const { data: account } = await admin
    .from("provider_asaas_accounts")
    .select("api_key_ciphertext,api_key_iv,sandbox")
    .eq("provider_id", withdrawal.provider_id)
    .single();
  if (
    !account?.api_key_ciphertext ||
    !account.api_key_iv ||
    account.sandbox !== isAsaasSandbox()
  )
    throw new Error("Conta ou ambiente divergente.");
  const key = await decryptProviderApiKey(
    account.api_key_ciphertext,
    account.api_key_iv
  );
  if (
    notifiedId &&
    withdrawal.asaas_transfer_id &&
    notifiedId !== withdrawal.asaas_transfer_id
  )
    throw new Error("Referência divergente.");
  const gatewayId = withdrawal.asaas_transfer_id ?? notifiedId;
  let actual;
  if (gatewayId) {
    const response = await asaasFetch(
      `/transfers/${encodeURIComponent(gatewayId)}`,
      { key }
    );
    if (!response.ok) throw new Error("Saque aguarda conciliação.");
    actual = await response.json();
  } else {
    const found = await findTransferByReference(id, withdrawal.created_at, key);
    if (!found) return "manual_review";
    return reconcileWithdrawal(admin, id, found);
  }
  if (
    !actual.id ||
    (gatewayId && actual.id !== gatewayId) ||
    actual.externalReference !== id ||
    Math.round(Number(actual.value) * 100) !== withdrawal.amount_cents ||
    actual.pixAddressKey !== withdrawal.payout_pix_key
  )
    throw new Error("Valor ou destino divergente.");
  const status =
    actual.status === "DONE"
      ? "paid"
      : ["FAILED", "CANCELLED"].includes(actual.status)
      ? "failed"
      : "requested";
  const saved = await admin
    .from("provider_asaas_withdrawals")
    .update({ asaas_transfer_id: actual.id, status })
    .eq("id", id)
    .in("status", ["requested", "manual_review"]);
  if (saved.error) throw new Error("Baixa do saque pendente.");
  return status;
}
