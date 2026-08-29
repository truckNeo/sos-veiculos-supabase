import {withSupabase} from 'npm:@supabase/server';

import {
  hmacDocument,
  normalizeBrazilianPhone,
  normalizeDigits,
} from '../_shared/auth.ts';

const EMAIL_REDIRECT_URL = 'https://www.truckneo.com.br/confirmar-conta';

const describeError = (error: unknown) => {
  if (typeof error !== 'object' || error === null) {
    return String(error);
  }
  const value = error as {code?: unknown; details?: unknown; hint?: unknown; message?: unknown};
  return JSON.stringify({
    code: value.code,
    details: value.details,
    hint: value.hint,
    message: value.message,
  });
};

type RegistrationPayload = {
  role: 'driver' | 'provider';
  accountKind: 'individual' | 'company';
  name: string;
  document: string;
  phone: string;
  email: string;
  password: string;
  businessName?: string;
  legalName?: string;
  postalCode?: string;
  addressStreet?: string;
  addressNumber?: string;
  addressComplement?: string;
  addressNeighborhood?: string;
  addressCity?: string;
  addressState?: string;
  serviceRadiusKm?: number;
  services?: Array<'engine' | 'tire' | 'electrical' | 'suspension' | 'cooling' | 'bodywork' | 'towing' | 'other'>;
  operationalVehicleModel?: string;
  operationalVehiclePlate?: string;
};

const providerProblemTypes = new Set(['engine', 'tire', 'electrical', 'suspension', 'cooling', 'bodywork', 'towing', 'other']);

export default {
  fetch: withSupabase({auth: 'publishable'}, async (request, ctx) => {
    let stage = 'parse-input';
    try {
      const input = (await request.json()) as RegistrationPayload;
      const document = normalizeDigits(input.document ?? '');
      const phone = normalizeBrazilianPhone(input.phone ?? '');
      const email = input.email?.trim().toLowerCase();
      const name = input.name?.trim();
      const isDriverCompany = input.role === 'driver' && input.accountKind === 'company';
      const isDriverIndividual = input.role === 'driver' && input.accountKind === 'individual';
      const expectedDocumentLength = input.role === 'provider' || isDriverCompany ? 14 : 11;
      const isValidDocument = document.length === expectedDocumentLength;

      if (!name || !phone || !email?.includes('@') || !isValidDocument || input.password?.length < 6 || (!isDriverCompany && !isDriverIndividual && input.role === 'driver')) {
        return Response.json({message: 'Confira os dados do cadastro.'}, {status: 400});
      }
      if (input.role !== 'driver' && input.role !== 'provider') {
        return Response.json({message: 'Perfil de acesso inválido.'}, {status: 400});
      }

      const providerServices = [...new Set((input.services ?? []).filter(
        (service): service is 'engine' | 'tire' | 'electrical' | 'suspension' | 'cooling' | 'bodywork' | 'towing' | 'other' => providerProblemTypes.has(service),
      ))];
      const providerBusinessName = input.businessName?.trim();
      const providerLegalName = input.legalName?.trim();
      const providerPostalCode = normalizeDigits(input.postalCode ?? '');
      const providerStreet = input.addressStreet?.trim();
      const providerNumber = input.addressNumber?.trim();
      const providerComplement = input.addressComplement?.trim() || null;
      const providerNeighborhood = input.addressNeighborhood?.trim();
      const providerCity = input.addressCity?.trim();
      const providerState = input.addressState?.trim().toUpperCase();
      const providerRadius = Number(input.serviceRadiusKm);
      const operationalVehicleModel = input.operationalVehicleModel?.trim();
      const operationalVehiclePlate = (input.operationalVehiclePlate ?? '').replace(/[^A-Za-z0-9]/g, '').toUpperCase();
      if (input.role === 'provider' && (
        document.length !== 14
        || !providerBusinessName
        || !providerLegalName
        || providerPostalCode.length !== 8
        || !providerStreet
        || !providerNumber
        || !providerNeighborhood
        || !providerCity
        || !/^[A-Z]{2}$/.test(providerState ?? '')
        || !Number.isInteger(providerRadius)
        || providerRadius < 1
        || providerRadius > 500
        || providerServices.length === 0
      )) {
        return Response.json({message: 'Complete os dados da empresa, endereço, raio e especialidades do prestador.'}, {status: 400});
      }
      if (input.role === 'provider' && providerServices.includes('towing') && (!operationalVehicleModel || operationalVehiclePlate.length < 7 || operationalVehiclePlate.length > 10)) {
        return Response.json({message: 'Informe o modelo e a placa do veículo operacional do guincho.'}, {status: 400});
      }

      console.info('register-account: validated input', {
        role: input.role,
        accountKind: input.accountKind,
      });

      stage = 'hash-document';
      const accountKind = input.role === 'provider' ? 'company' : input.accountKind;
    const documentHash = await hmacDocument(document);
    const phoneLookup = normalizeDigits(phone);
    stage = 'lookup-profile';
    const {data: existingProfile, error: lookupError} = await ctx.supabaseAdmin
      .from('profiles')
      .select('id')
      .or(`document_hash.eq.${documentHash},phone_lookup.eq.${phoneLookup}`)
      .maybeSingle();
    if (lookupError) {
      throw lookupError;
    }
    if (existingProfile) {
      return Response.json({message: 'Já existe uma conta com este documento ou telefone.'}, {status: 409});
    }

    stage = 'create-auth-user';
    const {data: signUpData, error: signUpError} = await ctx.supabase.auth.signUp({
      email,
      password: input.password,
      options: {emailRedirectTo: EMAIL_REDIRECT_URL},
    });
    if (signUpError || !signUpData.user) {
      return Response.json({message: signUpError?.message ?? 'Não foi possível criar a conta.'}, {status: 400});
    }

    // Supabase returns identities: [] when email already exists (security measure)
    if (!signUpData.user.identities || signUpData.user.identities.length === 0) {
      return Response.json({message: 'Já existe uma conta com este e-mail.'}, {status: 409});
    }

    const userId = signUpData.user.id;
    stage = 'verify-auth-user';
    let authUser: {id: string} | null = null;
    for (let attempt = 0; attempt < 10; attempt += 1) {
      const {data: userResult} = await ctx.supabaseAdmin.auth.admin.getUserById(userId);
      if (userResult.user) {
        authUser = {id: userResult.user.id};
        break;
      }
      await new Promise(resolve => setTimeout(resolve, 500));
    }
    if (!authUser) {
      throw new Error('O usuário foi retornado pelo Auth, mas ainda não está disponível para o perfil.');
    }

    stage = 'create-profile';
    const {error: profileError} = await ctx.supabaseAdmin.from('profiles').insert({
      id: userId,
      role: input.role,
      account_kind: accountKind,
      full_name: name,
      phone,
      phone_lookup: phoneLookup,
      document_hash: documentHash,
      document_last4: document.slice(-4),
    });
    if (profileError) {
      await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
      throw profileError;
    }

    if (input.role === 'provider') {
      stage = 'create-provider-profile';
      const {error} = await ctx.supabaseAdmin.from('provider_profiles').insert({
        provider_id: userId,
        business_name: providerBusinessName,
        legal_name: providerLegalName,
        postal_code: providerPostalCode,
        address_street: providerStreet,
        address_number: providerNumber,
        address_complement: providerComplement,
        address_neighborhood: providerNeighborhood,
        address_city: providerCity,
        address_state: providerState,
        service_radius_km: providerRadius,
        is_available: true,
      });
      if (error) {
        await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
        throw error;
      }

      stage = 'create-provider-services';
      const {error: servicesError} = await ctx.supabaseAdmin.from('provider_services').insert(
        providerServices.map(problemType => ({provider_id: userId, problem_type: problemType})),
      );
      if (servicesError) {
        await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
        throw servicesError;
      }
      if (providerServices.includes('towing')) {
        stage = 'create-provider-towing-vehicle';
        const {error: vehicleError} = await ctx.supabaseAdmin.from('provider_vehicles').insert({
          provider_id: userId,
          vehicle_type: 'towing',
          model: operationalVehicleModel,
          plate: operationalVehiclePlate,
        });
        if (vehicleError) {
          await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
          throw vehicleError;
        }
      }
    }

    if (input.role === 'driver' && accountKind === 'company') {
      stage = 'create-organization';
      const {error} = await ctx.supabaseAdmin.from('organizations').insert({
        owner_id: userId,
        legal_name: name,
        cnpj_hash: documentHash,
        cnpj_last4: document.slice(-4),
      });
      if (error) {
        await ctx.supabaseAdmin.auth.admin.deleteUser(userId);
        throw error;
      }
    }

      return Response.json({email, requiresEmailConfirmation: !signUpData.session}, {status: 201});
    } catch (error) {
      console.error('register-account failed', {
        stage,
        message: describeError(error),
      });
      return Response.json(
        {message: 'Não foi possível concluir o cadastro no momento. Tente novamente em instantes.', code: 'registration_failed'},
        {status: 500},
      );
    }
  }),
};
