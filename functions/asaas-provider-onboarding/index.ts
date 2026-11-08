import { withSupabase } from "npm:@supabase/server@1.4.1";
import type { AsaasDatabase } from "../_shared/asaas-database.ts";

import { hmacDocument, normalizeDigits } from "../_shared/auth.ts";
import {
  isAsaasSandbox,
  asaasFetch,
  encryptProviderApiKey,
  decryptProviderApiKey,
  parseAsaasError,
} from "../_shared/asaas.ts";

// Diferente da Iugu (upload de documentos direto pra nossa API), o Asaas só
// aceita documento de identificação/selfie pelo app dele ou por um link de
// onboarding hospedado — por isso aqui só criamos a subconta + conta
// bancária e devolvemos esse link pro app abrir numa WebView.

type OnboardingInput = {
  cnpj?: string;
  responsibleName?: string;
  responsibleCpf?: string;
  estimatedRevenue?: string;
  bank?: string;
  bankAgency?: string;
  bankAccount?: string;
  bankAccountDigit?: string;
  accountType?: "CONTA_CORRENTE" | "CONTA_POUPANCA";
};

const required = (value: string | undefined) => value?.trim() ?? "";

type AsaasAccount = {
  id?: string;
  walletId?: string;
  apiKey?: string;
  accessToken?: { apiKey?: string } | string;
};
type AsaasDocuments = { data?: Array<{ onboardingUrl?: string | null }> };

export default {
  fetch: withSupabase<AsaasDatabase>({ auth: "user" }, async (request, ctx) => {
    try {
      if (request.method !== "POST") return new Response(null, { status: 405 });
      const input = (await request.json()) as OnboardingInput;
      const cnpj = normalizeDigits(input.cnpj ?? "");
      const responsibleCpf = normalizeDigits(input.responsibleCpf ?? "");
      // O contexto expõe userClaims; `ctx.user` nunca existiu em nenhuma versão
      // do @supabase/server, então ler `.id` dele lançava TypeError e o catch
      // abaixo devolvia 503 — o onboarding falhava sempre.
      const providerId = ctx.userClaims?.id;
      if (!providerId)
        return Response.json({ message: "Sessão inválida." }, { status: 401 });

      const [{ data: profile }, { data: business }, { data: existing }] =
        await Promise.all([
          ctx.supabase
            .from("profiles")
            .select("document_hash, phone")
            .maybeSingle(),
          ctx.supabase
            .from("provider_profiles")
            .select(
              "business_name, legal_name, postal_code, address_street, address_number, address_complement, address_neighborhood, address_city, address_state"
            )
            .maybeSingle(),
          ctx.supabaseAdmin
            .from("provider_asaas_accounts")
            .select(
              "asaas_account_id,status,sandbox,api_key_ciphertext,api_key_iv,onboarding_url"
            )
            .eq("provider_id", providerId)
            .maybeSingle(),
        ]);
      if (!profile || !business) {
        return Response.json(
          {
            message:
              "O CNPJ deve ser o mesmo utilizado no cadastro do estabelecimento.",
          },
          { status: 400 }
        );
      }
      if (existing?.asaas_account_id) {
        if (existing.sandbox !== isAsaasSandbox())
          return Response.json(
            {
              message: "Conta pertence a outro ambiente; solicite conciliação.",
            },
            { status: 409 }
          );
        let onboardingUrl = existing.onboarding_url;
        if (existing.api_key_ciphertext && existing.api_key_iv) {
          const key = await decryptProviderApiKey(
            existing.api_key_ciphertext,
            existing.api_key_iv
          );
          const response = await asaasFetch("/myAccount/documents", { key });
          if (response.ok) {
            const docs = (await response.json()) as AsaasDocuments;
            onboardingUrl =
              docs.data?.find((d) => d.onboardingUrl)?.onboardingUrl ??
              onboardingUrl;
          }
          const saved = await ctx.supabaseAdmin
            .from("provider_asaas_accounts")
            .update({ onboarding_url: onboardingUrl })
            .eq("provider_id", providerId);
          if (saved.error)
            return Response.json(
              { message: "Link de verificação aguarda atualização." },
              { status: 503 }
            );
        }
        return Response.json({ status: existing.status, onboardingUrl });
      }

      if (
        cnpj.length !== 14 ||
        responsibleCpf.length !== 11 ||
        !required(input.responsibleName) ||
        !required(input.estimatedRevenue) ||
        !required(input.bank) ||
        !required(input.bankAgency) ||
        !required(input.bankAccount) ||
        !input.accountType
      ) {
        return Response.json(
          { message: "Preencha o CNPJ, responsável e os dados bancários." },
          { status: 400 }
        );
      }

      if ((await hmacDocument(cnpj)) !== profile.document_hash)
        return Response.json(
          { message: "Informe o CNPJ do cadastro." },
          { status: 400 }
        );
      const { data: userResult } = await ctx.supabase.auth.getUser();
      const email = userResult.user?.email;
      if (!email)
        return Response.json({ message: "Sessão inválida." }, { status: 401 });
      const accountName =
        business.business_name
          .replace(/[^A-Za-zÀ-ÿ ]/g, " ")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 80) || "Prestador SOS Veículos";

      // Valida a cifra antes de criar uma conta externa.
      await encryptProviderApiKey("preflight");
      const reserved = await ctx.supabaseAdmin
        .from("provider_onboarding_attempts")
        .insert({ provider_id: providerId, sandbox: isAsaasSandbox() });
      if (reserved.error)
        return Response.json(
          {
            message:
              "Cadastro financeiro já solicitado. Aguarde a conciliação; não será criada outra subconta.",
          },
          { status: 409 }
        );
      const createResponse = await asaasFetch("/accounts", {
        body: {
          name: accountName,
          email,
          cpfCnpj: cnpj,
          companyType: "LIMITED",
          mobilePhone: profile.phone
            ? normalizeDigits(profile.phone)
            : undefined,
          incomeValue: Number(input.estimatedRevenue),
          address: business.address_street ?? undefined,
          addressNumber: business.address_number ?? undefined,
          complement: business.address_complement ?? undefined,
          province: business.address_neighborhood ?? undefined,
          postalCode: business.postal_code
            ? normalizeDigits(business.postal_code)
            : undefined,
        },
      });
      if (!createResponse.ok) {
        return Response.json(
          {
            message:
              (await parseAsaasError(createResponse)) ||
              "Não foi possível criar a subconta Asaas.",
          },
          { status: 502 }
        );
      }
      const account = (await createResponse.json()) as AsaasAccount;
      const apiKey =
        account.apiKey ??
        (typeof account.accessToken === "object"
          ? account.accessToken?.apiKey
          : account.accessToken);
      if (!account.id || !account.walletId || !apiKey) {
        return Response.json(
          { message: "O Asaas não retornou os dados da subconta." },
          { status: 502 }
        );
      }

      let onboardingUrl: string | null = null;
      const { ciphertext, iv } = await encryptProviderApiKey(apiKey);
      const { error } = await ctx.supabaseAdmin
        .from("provider_asaas_accounts")
        .upsert({
          provider_id: providerId,
          sandbox: isAsaasSandbox(),
          asaas_account_id: account.id,
          wallet_id: account.walletId,
          api_key_ciphertext: ciphertext,
          api_key_iv: iv,
          bank_code: normalizeDigits(required(input.bank)),
          bank_agency: required(input.bankAgency),
          bank_account: required(input.bankAccount),
          bank_account_digit: required(input.bankAccountDigit) || "0",
          bank_account_type: input.accountType,
          onboarding_url: onboardingUrl,
          status: "verification_requested",
          verification_requested_at: new Date().toISOString(),
          rejection_reason: null,
        });
      if (error)
        return Response.json(
          {
            message:
              "A subconta foi criada, mas não pôde ser registrada com segurança.",
          },
          { status: 500 }
        );
      // O ID e a chave cifrada já estão salvos; uma falha de documentos não recria a conta.
      const docsResponse = await asaasFetch("/myAccount/documents", {
        key: apiKey,
      });
      if (docsResponse.ok) {
        const docs = (await docsResponse.json()) as AsaasDocuments;
        onboardingUrl =
          docs.data?.find((d) => d.onboardingUrl)?.onboardingUrl ?? null;
        const saved = await ctx.supabaseAdmin
          .from("provider_asaas_accounts")
          .update({ onboarding_url: onboardingUrl })
          .eq("provider_id", providerId);
        if (saved.error)
          return Response.json(
            {
              message: "Conta criada; link de documentos aguarda conciliação.",
            },
            { status: 503 }
          );
      }
      return Response.json({ status: "verification_requested", onboardingUrl });
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Não foi possível enviar o cadastro financeiro.";
      return Response.json({ message }, { status: 503 });
    }
  }),
};
