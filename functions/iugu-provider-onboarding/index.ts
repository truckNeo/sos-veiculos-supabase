import { withSupabase } from "npm:@supabase/server";

import { hmacDocument, normalizeDigits } from "../_shared/auth.ts";
import {
  isIuguMockMode,
  parseIuguError,
  requireIuguProduction,
  signedIuguFetch,
} from "../_shared/iugu.ts";

type OnboardingInput = {
  cnpj?: string;
  responsibleName?: string;
  responsibleCpf?: string;
  estimatedRevenue?: string;
  bank?: string;
  bankAgency?: string;
  bankAccount?: string;
  accountType?: "Corrente" | "Poupança" | "Pagamento";
  identificationBase64?: string;
  selfieBase64?: string;
  socialContractBase64?: string;
  addressProofBase64?: string;
};

const required = (value: string | undefined) => value?.trim() ?? "";

export default {
  fetch: withSupabase({ auth: "user" }, async (request, ctx) => {
    try {
      const input = (await request.json()) as OnboardingInput;
      if (isIuguMockMode()) {
        const { error } = await ctx.supabaseAdmin
          .from("provider_iugu_accounts")
          .upsert({
            provider_id: ctx.user.id,
            iugu_account_id: `IUGU_MOCK_${ctx.user.id.replaceAll("-", "").slice(0, 16)}`,
            status: "verified",
            verified_at: new Date().toISOString(),
            rejection_reason: null,
          });
        return error
          ? Response.json(
              {
                message: "Não foi possível criar a conta financeira de teste.",
              },
              { status: 500 },
            )
          : Response.json({ status: "verified", mock: true });
      }
      const cnpj = normalizeDigits(input.cnpj ?? "");
      const responsibleCpf = normalizeDigits(input.responsibleCpf ?? "");
      if (
        cnpj.length !== 14 ||
        responsibleCpf.length !== 11 ||
        !required(input.responsibleName) ||
        !required(input.estimatedRevenue) ||
        !required(input.bank) ||
        !required(input.bankAgency) ||
        !required(input.bankAccount) ||
        !input.accountType ||
        !input.identificationBase64 ||
        !input.selfieBase64 ||
        !input.socialContractBase64
      ) {
        return Response.json(
          {
            message:
              "Preencha os dados bancários, responsável e os documentos obrigatórios.",
          },
          { status: 400 },
        );
      }
      const [{ data: profile }, { data: business }, { data: existing }] =
        await Promise.all([
          ctx.supabase
            .from("profiles")
            .select("document_hash, phone")
            .maybeSingle(),
          ctx.supabase
            .from("provider_profiles")
            .select(
              "business_name, legal_name, postal_code, address_street, address_number, address_complement, address_neighborhood, address_city, address_state",
            )
            .maybeSingle(),
          ctx.supabaseAdmin
            .from("provider_iugu_accounts")
            .select("iugu_account_id, status")
            .eq("provider_id", ctx.user.id)
            .maybeSingle(),
        ]);
      if (
        !profile ||
        !business ||
        (await hmacDocument(cnpj)) !== profile.document_hash
      ) {
        return Response.json(
          {
            message:
              "O CNPJ deve ser o mesmo utilizado no cadastro do estabelecimento.",
          },
          { status: 400 },
        );
      }
      if (existing?.status === "verified")
        return Response.json(
          { message: "Sua conta financeira já está aprovada." },
          { status: 409 },
        );
      if (existing?.iugu_account_id)
        return Response.json(
          { message: "Seu cadastro financeiro já está em análise pela Iugu." },
          { status: 409 },
        );

      const { masterToken, privateKey } = requireIuguProduction();
      const accountName =
        business.business_name
          .replace(/[^A-Za-zÀ-ÿ ]/g, " ")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 80) || "Prestador SOS Veiculos";
      const createResponse = await signedIuguFetch(
        "/v1/marketplace/create_account",
        { name: accountName },
        masterToken,
        privateKey,
      );
      if (!createResponse.ok)
        return Response.json(
          {
            message:
              (await parseIuguError(createResponse)) ||
              "Não foi possível criar a subconta Iugu.",
          },
          { status: 502 },
        );
      const created = (await createResponse.json()) as {
        account_id?: string;
        user_token?: string;
      };
      if (!created.account_id || !created.user_token)
        return Response.json(
          { message: "A Iugu não retornou os dados da subconta." },
          { status: 502 },
        );

      const files: Record<string, string> = {
        identification: input.identificationBase64,
        selfie: input.selfieBase64,
        social_contract: input.socialContractBase64,
      };
      if (input.addressProofBase64)
        files.address_proof = input.addressProofBase64;
      const verificationResponse = await fetch(
        `https://api.iugu.com/v1/accounts/${encodeURIComponent(created.account_id)}/request_verification`,
        {
          method: "POST",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            Authorization: `Basic ${btoa(`${created.user_token}:`)}`,
          },
          body: JSON.stringify({
            data: {
              price_range: 100000,
              physical_products: true,
              business_type: "Serviços automotivos",
              person_type: "Pessoa Jurídica",
              automatic_transfer: false,
              cnpj,
              company_name: business.legal_name ?? business.business_name,
              resp_name: required(input.responsibleName),
              resp_cpf: responsibleCpf,
              street: business.address_street,
              number: business.address_number,
              complement: business.address_complement ?? undefined,
              cep: business.postal_code,
              city: business.address_city,
              district: business.address_neighborhood,
              state: business.address_state,
              telephone: profile.phone,
              estimated_revenue: Number(input.estimatedRevenue),
              bank: required(input.bank),
              bank_ag: required(input.bankAgency),
              account_type: input.accountType,
              bank_cc: required(input.bankAccount),
            },
            files,
          }),
        },
      );
      if (!verificationResponse.ok) {
        await ctx.supabaseAdmin.from("provider_iugu_accounts").upsert({
          provider_id: ctx.user.id,
          iugu_account_id: created.account_id,
          status: "error",
          rejection_reason: (await parseIuguError(verificationResponse)).slice(
            0,
            1000,
          ),
        });
        return Response.json(
          {
            message:
              "A subconta foi criada, mas a Iugu recusou os documentos. Corrija no suporte.",
          },
          { status: 422 },
        );
      }
      const { error } = await ctx.supabaseAdmin
        .from("provider_iugu_accounts")
        .upsert({
          provider_id: ctx.user.id,
          iugu_account_id: created.account_id,
          status: "verification_requested",
          verification_requested_at: new Date().toISOString(),
          rejection_reason: null,
        });
      if (error)
        return Response.json(
          {
            message: "A verificação foi enviada, mas não pôde ser registrada.",
          },
          { status: 500 },
        );
      return Response.json({ status: "verification_requested" });
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Não foi possível enviar o cadastro financeiro.";
      return Response.json({ message }, { status: 503 });
    }
  }),
};
