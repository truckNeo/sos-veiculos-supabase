import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AsaasDatabase } from "./asaas-database.ts";
import {
  asaasFetch,
  isAsaasSandbox,
  decryptProviderApiKey,
  encryptProviderApiKey,
} from "./asaas.ts";
import { hmacDocument, normalizeDigits } from "./auth.ts";

// Provisionamento por referência estável. Chamada incerta não cria outro customer.
export async function ensurePaymentCustomer(
  admin: SupabaseClient<AsaasDatabase>,
  userId: string,
  email: string,
  payerDocument?: string
): Promise<string> {
  const { data: profile } = await admin
    .from("profiles")
    .select("full_name,phone,document_hash,asaas_customer_id")
    .eq("id", userId)
    .single();
  if (!profile) throw new Error("Perfil não encontrado.");
  let { data: stored } = await admin
    .from("payment_customer_profiles")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();
  if (stored?.customer_id && stored.sandbox === isAsaasSandbox())
    return stored.customer_id;
  // Contas antigas: o ID só é reutilizado após confirmar que existe no ambiente atual.
  if (profile.asaas_customer_id) {
    const existing = await asaasFetch(
      `/customers/${encodeURIComponent(profile.asaas_customer_id)}`
    );
    if (existing.ok) {
      const customer = await existing.json();
      if (customer.id === profile.asaas_customer_id && !customer.deleted)
        return customer.id;
    }
  }
  if (!stored) {
    const document = normalizeDigits(payerDocument ?? "");
    if (
      ![11, 14].includes(document.length) ||
      (await hmacDocument(document)) !== profile.document_hash
    )
      throw new Error("Complete seu CPF/CNPJ de pagamento uma única vez.");
    const encrypted = await encryptProviderApiKey(document);
    const { error } = await admin
      .from("payment_customer_profiles")
      .upsert(
        {
          user_id: userId,
          document_ciphertext: encrypted.ciphertext,
          document_iv: encrypted.iv,
        },
        { onConflict: "user_id", ignoreDuplicates: true }
      );
    if (error)
      throw new Error("Não foi possível registrar os dados financeiros.");
    const result = await admin
      .from("payment_customer_profiles")
      .select("*")
      .eq("user_id", userId)
      .single();
    stored = result.data;
  }
  if (!stored) throw new Error("Dados financeiros indisponíveis.");
  const reference = `sos-payer-${userId}`;
  const lookup = await asaasFetch(
    `/customers?externalReference=${encodeURIComponent(reference)}&limit=2`
  );
  if (!lookup.ok)
    throw new Error("Não foi possível consultar o cadastro financeiro.");
  const matches = await lookup.json();
  if (matches.hasMore || matches.data?.length > 1)
    throw new Error("Cadastro financeiro requer conciliação.");
  let customerId = matches.data?.[0]?.id;
  if (!customerId) {
    const { data: claimed, error } = await admin
      .from("payment_customer_profiles")
      .update({ provisioning_at: new Date().toISOString() })
      .eq("user_id", userId)
      .is("provisioning_at", null)
      .select("user_id");
    if (error || !claimed?.length)
      throw new Error(
        "Cadastro financeiro em processamento. Tente novamente em instantes."
      );
    const document = await decryptProviderApiKey(
      stored.document_ciphertext,
      stored.document_iv
    );
    const response = await asaasFetch("/customers", {
      body: {
        name: profile.full_name,
        cpfCnpj: document,
        email,
        mobilePhone: profile.phone ? normalizeDigits(profile.phone) : undefined,
        externalReference: reference,
        notificationDisabled: true,
      },
    });
    if (!response.ok)
      throw new Error(
        "Cadastro financeiro requer conferência. Nenhum cadastro será duplicado."
      );
    customerId = (await response.json()).id;
  }
  if (!customerId) throw new Error("Cadastro financeiro sem identificador.");
  const { error } = await admin
    .from("payment_customer_profiles")
    .update({ customer_id: customerId, sandbox: isAsaasSandbox() })
    .eq("user_id", userId);
  if (error) throw new Error("Cadastro criado; conciliação pendente.");
  await admin
    .from("profiles")
    .update({ asaas_customer_id: customerId })
    .eq("id", userId);
  return customerId;
}
