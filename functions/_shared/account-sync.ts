import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import { asaasFetch, decryptProviderApiKey } from "./asaas.ts";

export type AccountSyncResult = "verified" | "rejected" | "pending" | "unavailable";

/**
 * Confere no Asaas o status geral da subconta e atualiza o banco. O webhook de conta não chega
 * para subcontas, então esta consulta é o que de fato libera (ou recusa) o cadastro financeiro.
 * O aviso ao prestador sai do gatilho do banco quando o status muda.
 */
export async function syncAsaasAccountStatus(
  admin: SupabaseClient<AsaasDatabase>,
  account: { provider_id: string; status: string; api_key_ciphertext: string | null; api_key_iv: string | null }
): Promise<AccountSyncResult> {
  if (!account.api_key_ciphertext || !account.api_key_iv) return "unavailable";
  const key = await decryptProviderApiKey(account.api_key_ciphertext, account.api_key_iv);
  const response = await asaasFetch("/myAccount/status", { key });
  if (!response.ok) return "unavailable";
  const { general } = (await response.json()) as { general?: string };
  if (general === "APPROVED") {
    if (account.status !== "verified") {
      const { error } = await admin
        .from("provider_asaas_accounts")
        .update({ status: "verified", verified_at: new Date().toISOString(), rejection_reason: null })
        .eq("provider_id", account.provider_id)
        .neq("status", "verified");
      if (error) throw new Error("Não foi possível registrar a aprovação.");
    }
    return "verified";
  }
  if (general === "REJECTED") {
    if (account.status !== "rejected") {
      const { error } = await admin
        .from("provider_asaas_accounts")
        .update({ status: "rejected", rejection_reason: "Cadastro recusado pelo Asaas — revise os documentos." })
        .eq("provider_id", account.provider_id)
        .neq("status", "rejected");
      if (error) throw new Error("Não foi possível registrar a recusa.");
    }
    return "rejected";
  }
  return "pending";
}
