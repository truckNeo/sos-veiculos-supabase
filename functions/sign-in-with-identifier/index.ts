import {withSupabase} from 'npm:@supabase/server';

import {
  hmacDocument,
  normalizeBrazilianPhone,
  normalizeDigits,
} from '../_shared/auth.ts';

export default {
  fetch: withSupabase({auth: 'publishable'}, async (request, ctx) => {
    const {identifier, password} = await request.json();
    const digits = normalizeDigits(identifier ?? '');
    if (!password || !digits) {
      return Response.json({message: 'Informe seu CPF ou telefone e a senha.'}, {status: 400});
    }

    let profileQuery = ctx.supabaseAdmin.from('profiles').select('id').limit(1);
    if (digits.length === 11 || digits.length === 14) {
      profileQuery = profileQuery.eq('document_hash', await hmacDocument(digits));
    } else {
      const phone = normalizeBrazilianPhone(identifier);
      if (!phone) {
        return Response.json({message: 'CPF ou telefone inválido.'}, {status: 400});
      }
      profileQuery = profileQuery.eq('phone_lookup', normalizeDigits(phone));
    }

    const {data: profile, error: profileError} = await profileQuery.maybeSingle();
    if (profileError) {
      throw profileError;
    }
    if (!profile) {
      return Response.json({message: 'Credenciais inválidas.'}, {status: 401});
    }

    const {data: userData, error: userError} = await ctx.supabaseAdmin.auth.admin.getUserById(profile.id);
    if (userError || !userData.user?.email) {
      throw userError ?? new Error('Usuário não encontrado.');
    }

    const {data: sessionData, error: signInError} = await ctx.supabase.auth.signInWithPassword({
      email: userData.user.email,
      password,
    });
    if (signInError || !sessionData.session) {
      return Response.json({message: signInError?.message ?? 'Credenciais inválidas.'}, {status: 401});
    }

    return Response.json({session: sessionData.session});
  }),
};
