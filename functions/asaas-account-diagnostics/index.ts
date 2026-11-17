import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";
import { asaasFetch, decryptProviderApiKey, isAsaasSandbox } from "../_shared/asaas.ts";

const safeEqual = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

type StatusBody = Record<string, unknown>;
type DocumentItem = {
  status?: string;
  type?: string;
  title?: string;
  description?: string;
  rejectReasons?: unknown;
  onboardingUrl?: string | null;
};

/**
 * Diagnóstico somente de leitura do cadastro financeiro: compara o status do banco com o que o
 * Asaas informa para cada subconta e lista os documentos pendentes. Nunca devolve chaves nem links.
 * Chamada pelo pg_net (x-cron-secret) ou com a chave secreta; publicar com --no-verify-jwt.
 */
export default {
  fetch: withSupabase<AsaasDatabase>({ auth: ["secret", "none"] }, async (request, ctx) => {
    if (request.method !== "POST") return new Response(null, { status: 405 });
    if (ctx.authMode === "none") {
      const expected = Deno.env.get("CRON_SECRET") ?? "";
      if (!expected || !safeEqual(request.headers.get("x-cron-secret") ?? "", expected))
        return Response.json({ message: "Não autorizado." }, { status: 401 });
    }
    let providerId: string | undefined;
    try {
      providerId = ((await request.json()) as { providerId?: string }).providerId;
    } catch {
      providerId = undefined;
    }
    const query = ctx.supabaseAdmin
      .from("provider_asaas_accounts")
      .select("provider_id,status,sandbox,asaas_account_id,api_key_ciphertext,api_key_iv,verification_requested_at,rejection_reason");
    const { data: accounts, error } = await (providerId
      ? query.eq("provider_id", providerId)
      : query.neq("status", "verified"));
    if (error) return Response.json({ message: "Consulta indisponível." }, { status: 503 });

    const report = [];
    for (const account of accounts ?? []) {
      const entry: Record<string, unknown> = {
        providerId: account.provider_id,
        dbStatus: account.status,
        dbSandbox: account.sandbox,
        envSandbox: isAsaasSandbox(),
        requestedAt: account.verification_requested_at,
        dbRejectionReason: account.rejection_reason,
        hasAsaasAccountId: !!account.asaas_account_id,
        hasApiKey: !!(account.api_key_ciphertext && account.api_key_iv),
      };
      if (account.api_key_ciphertext && account.api_key_iv) {
        try {
          const key = await decryptProviderApiKey(account.api_key_ciphertext, account.api_key_iv);
          const status = await asaasFetch("/myAccount/status", { key });
          entry.statusHttp = status.status;
          if (status.ok) entry.asaasStatus = (await status.json()) as StatusBody;
          const docs = await asaasFetch("/myAccount/documents", { key });
          entry.documentsHttp = docs.status;
          if (docs.ok) {
            const body = (await docs.json()) as { data?: DocumentItem[] };
            entry.documents = (body.data ?? []).map((d) => ({
              type: d.type,
              status: d.status,
              title: d.title,
              description: d.description,
              rejectReasons: d.rejectReasons ?? null,
              hasOnboardingLink: !!d.onboardingUrl,
            }));
          }
        } catch {
          entry.error = "Não foi possível consultar o Asaas com a chave desta subconta.";
        }
      }
      report.push(entry);
    }
    return Response.json({ accounts: report });
  }),
};
