import {withSupabase} from 'npm:@supabase/server';

import {hmacDocument, normalizeDigits} from '../_shared/auth.ts';
import {asaasFetch, encryptProviderApiKey, parseAsaasError} from '../_shared/asaas.ts';

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
  accountType?: 'CONTA_CORRENTE' | 'CONTA_POUPANCA';
};

const required = (value: string | undefined) => value?.trim() ?? '';

type AsaasAccount = {id?: string; walletId?: string; apiKey?: string; accessToken?: {apiKey?: string} | string};
type AsaasDocuments = {data?: Array<{onboardingUrl?: string | null}>};

export default {
  fetch: withSupabase({auth: 'user'}, async (request, ctx) => {
    try {
      const input = await request.json() as OnboardingInput;
      const cnpj = normalizeDigits(input.cnpj ?? '');
      const responsibleCpf = normalizeDigits(input.responsibleCpf ?? '');
      if (
        cnpj.length !== 14 || responsibleCpf.length !== 11 ||
        !required(input.responsibleName) || !required(input.estimatedRevenue) ||
        !required(input.bank) || !required(input.bankAgency) || !required(input.bankAccount) ||
        !input.accountType
      ) {
        return Response.json({message: 'Preencha o CNPJ, responsável e os dados bancários.'}, {status: 400});
      }

      const [{data: profile}, {data: business}, {data: existing}] = await Promise.all([
        ctx.supabase.from('profiles').select('document_hash, phone').maybeSingle(),
        ctx.supabase.from('provider_profiles').select(
          'business_name, legal_name, postal_code, address_street, address_number, address_complement, address_neighborhood, address_city, address_state',
        ).maybeSingle(),
        ctx.supabaseAdmin.from('provider_asaas_accounts').select('asaas_account_id, status').eq('provider_id', ctx.user.id).maybeSingle(),
      ]);
      if (!profile || !business || (await hmacDocument(cnpj)) !== profile.document_hash) {
        return Response.json({message: 'O CNPJ deve ser o mesmo utilizado no cadastro do estabelecimento.'}, {status: 400});
      }
      if (existing?.status === 'verified') return Response.json({message: 'Sua conta financeira já está aprovada.'}, {status: 409});
      if (existing?.asaas_account_id) return Response.json({message: 'Seu cadastro financeiro já está em análise pelo Asaas.'}, {status: 409});

      const {data: userResult} = await ctx.supabase.auth.getUser();
      const email = userResult.user?.email;
      if (!email) return Response.json({message: 'Sessão inválida.'}, {status: 401});
      const accountName = business.business_name.replace(/[^A-Za-zÀ-ÿ ]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80)
        || 'Prestador SOS Veículos';

      const createResponse = await asaasFetch('/accounts', {body: {
        name: accountName,
        email,
        cpfCnpj: cnpj,
        companyType: 'LIMITED',
        mobilePhone: profile.phone ? normalizeDigits(profile.phone) : undefined,
        incomeValue: Number(input.estimatedRevenue),
        address: business.address_street ?? undefined,
        addressNumber: business.address_number ?? undefined,
        complement: business.address_complement ?? undefined,
        province: business.address_neighborhood ?? undefined,
        postalCode: business.postal_code ? normalizeDigits(business.postal_code) : undefined,
      }});
      if (!createResponse.ok) {
        return Response.json({message: await parseAsaasError(createResponse) || 'Não foi possível criar a subconta Asaas.'}, {status: 502});
      }
      const account = await createResponse.json() as AsaasAccount;
      const apiKey = account.apiKey ?? (typeof account.accessToken === 'object' ? account.accessToken?.apiKey : account.accessToken);
      if (!account.id || !account.walletId || !apiKey) {
        return Response.json({message: 'O Asaas não retornou os dados da subconta.'}, {status: 502});
      }

      const bankResponse = await asaasFetch('/bankAccounts', {key: apiKey, body: {
        bank: {code: normalizeDigits(required(input.bank))},
        accountName: business.business_name,
        ownerName: required(input.responsibleName),
        cpfCnpj: responsibleCpf,
        agency: required(input.bankAgency),
        account: required(input.bankAccount),
        accountDigit: required(input.bankAccountDigit) || '0',
        bankAccountType: input.accountType,
      }});
      if (!bankResponse.ok) {
        console.error('asaas-provider-onboarding: bankAccounts failed', {status: bankResponse.status});
      }

      let onboardingUrl: string | null = null;
      const docsResponse = await asaasFetch('/myAccount/documents', {key: apiKey});
      if (docsResponse.ok) {
        const docs = await docsResponse.json() as AsaasDocuments;
        onboardingUrl = docs.data?.[0]?.onboardingUrl ?? null;
      }

      const {ciphertext, iv} = await encryptProviderApiKey(apiKey);
      const {error} = await ctx.supabaseAdmin.from('provider_asaas_accounts').upsert({
        provider_id: ctx.user.id,
        asaas_account_id: account.id,
        wallet_id: account.walletId,
        api_key_ciphertext: ciphertext,
        api_key_iv: iv,
        bank_code: normalizeDigits(required(input.bank)),
        bank_agency: required(input.bankAgency),
        bank_account: required(input.bankAccount),
        bank_account_digit: required(input.bankAccountDigit) || '0',
        bank_account_type: input.accountType,
        onboarding_url: onboardingUrl,
        status: 'verification_requested',
        verification_requested_at: new Date().toISOString(),
        rejection_reason: null,
      });
      if (error) return Response.json({message: 'A subconta foi criada, mas não pôde ser registrada com segurança.'}, {status: 500});
      return Response.json({status: 'verification_requested', onboardingUrl});
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Não foi possível enviar o cadastro financeiro.';
      return Response.json({message}, {status: 503});
    }
  }),
};
