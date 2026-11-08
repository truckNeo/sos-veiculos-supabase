import { findTransferByReference } from "./transfer-lookup.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import { asaasFetch, isAsaasSandbox } from "./asaas.ts";

type Result = {
  state: "completed" | "processing" | "failed" | "manual_review";
  message?: string;
};
export async function reconcileDispatchTransfer(
  admin: SupabaseClient<AsaasDatabase>,
  transferId: string,
  notifiedId?: string
): Promise<Result> {
  const { data: transfer, error } = await admin
    .from("service_provider_transfers")
    .select(
      "id,request_id,provider_id,provider_net_cents,status,asaas_transfer_id,created_at"
    )
    .eq("id", transferId)
    .single();
  if (error || !transfer) throw new Error("Repasse não encontrado.");
  if (transfer.status === "completed") return { state: "completed" };
  if (transfer.status === "failed") return { state: "failed" };
  const [
    { data: account },
    { data: charges, error: chargeError },
    { data: request },
  ] = await Promise.all([
    admin
      .from("provider_asaas_accounts")
      .select("wallet_id,status,sandbox,financial_block_reason")
      .eq("provider_id", transfer.provider_id)
      .single(),
    admin
      .from("service_payment_charges")
      .select("asaas_sandbox,status,settled_at")
      .eq("request_id", transfer.request_id)
      .eq("kind", "dispatch"),
    admin
      .from("service_requests")
      .select("provider_arrival_confirmed_at")
      .eq("id", transfer.request_id)
      .single(),
  ]);
  if (
    !request?.provider_arrival_confirmed_at ||
    !account?.wallet_id ||
    account.status !== "verified" ||
    account.sandbox !== isAsaasSandbox() ||
    account.financial_block_reason ||
    chargeError ||
    !charges?.length ||
    charges.some(
      (c) => c.status !== "paid" || c.asaas_sandbox !== isAsaasSandbox()
    )
  ) {
    return {
      state: "manual_review",
      message:
        "Cadastro, confirmação ou ambiente financeiro requer conferência.",
    };
  }
  if (charges.some((c) => !c.settled_at))
    return {
      state: "processing",
      message: "Aguardando liquidação do pagamento.",
    };
  let gatewayId = transfer.asaas_transfer_id;
  let submitted = false;
  try {
    let gateway: {
      id?: string;
      status?: string;
      walletId?: string;
      value?: number;
      externalReference?: string;
    };
    if (notifiedId && gatewayId && notifiedId !== gatewayId)
      throw new Error("Referência divergente.");
    gatewayId ??= notifiedId ?? null;
    if (gatewayId) {
      const response = await asaasFetch(
        `/transfers/${encodeURIComponent(gatewayId)}`
      );
      if (!response.ok) throw new Error("Consulta indisponível.");
      gateway = await response.json();
    } else {
      if (transfer.status !== "pending") {
        const found = await findTransferByReference(
          transfer.id,
          transfer.created_at
        );
        if (!found)
          return {
            state: "manual_review",
            message:
              "Envio anterior sem referência; conciliar antes de repetir.",
          };
        return reconcileDispatchTransfer(admin, transfer.id, found);
      }
      const { data: claim, error: claimError } = await admin.rpc(
        "claim_asaas_provider_transfer",
        { p_transfer_id: transfer.id }
      );
      if (claimError || !claim?.length) return { state: "processing" };
      submitted = true;
      const response = await asaasFetch("/transfers", {
        body: {
          value: transfer.provider_net_cents / 100,
          walletId: account.wallet_id,
          externalReference: transfer.id,
        },
      });
      if (!response.ok) throw new Error("Envio requer conciliação.");
      gateway = await response.json();
    }
    if (
      !gateway.id ||
      (gatewayId && gateway.id !== gatewayId) ||
      gateway.walletId !== account.wallet_id ||
      gateway.externalReference !== transfer.id ||
      Math.round(Number(gateway.value) * 100) !== transfer.provider_net_cents
    )
      throw new Error("Resposta financeira divergente.");
    const { error: saveError } = await admin
      .from("service_provider_transfers")
      .update({ asaas_transfer_id: gateway.id })
      .eq("id", transfer.id);
    if (saveError) throw new Error("Falha ao salvar referência.");
    if (gateway.status === "DONE") {
      const { error: completeError } = await admin.rpc(
        "complete_dispatch_transfer",
        { p_transfer_id: transfer.id, p_asaas_transfer_id: gateway.id }
      );
      if (completeError) throw new Error("Conciliação pendente.");
      return { state: "completed" };
    }
    if (["FAILED", "CANCELLED"].includes(gateway.status ?? "")) {
      const { error: failError } = await admin
        .from("service_provider_transfers")
        .update({
          status: "failed",
          failure_reason: `Asaas: ${gateway.status}`,
        })
        .eq("id", transfer.id)
        .neq("status", "completed");
      if (failError) throw new Error("Falha ao registrar recusa.");
      return { state: "failed" };
    }
    return {
      state: gateway.status === "BLOCKED" ? "manual_review" : "processing",
    };
  } catch {
    if (submitted)
      await admin.rpc("mark_asaas_transfer_manual_review", {
        p_transfer_id: transfer.id,
        p_reason: "Resultado incerto; consultar o Asaas antes de novo envio.",
      });
    return {
      state: "manual_review",
      message: "Repasse em conciliação; nenhum novo envio será feito.",
    };
  }
}
