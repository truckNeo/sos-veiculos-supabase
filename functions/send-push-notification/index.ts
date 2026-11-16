import {withSupabase} from 'npm:@supabase/server';

const encoder = new TextEncoder();
const base64Url = (bytes: Uint8Array) => {
  let binary = '';
  bytes.forEach(byte => { binary += String.fromCharCode(byte); });
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
};
const jsonBase64 = (value: unknown) => base64Url(encoder.encode(JSON.stringify(value)));
const pemBytes = (pem: string) => {
  // O segredo costuma ser colado com "\n" literais e/ou entre aspas (JSON da conta de serviço).
  const raw = pem.replace(/\\n/g, '\n').replace(/["']/g, '')
    .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const binary = atob(raw);
  return Uint8Array.from(binary, char => char.charCodeAt(0));
};
const buildFcmMessage = (token: string, title: string, message: string, data: Record<string, string>) => ({
  message: {
    token,
    notification: {title: title.trim(), body: message.trim()},
    data,
    // Prioridade alta + canal de importância alta (criado no app) = banner com
    // o app em segundo plano ou a tela apagada; no iOS, som padrão.
    android: {priority: 'HIGH', notification: {channel_id: 'sos_default', color: '#071A3A'}},
    apns: {headers: {'apns-priority': '10'}, payload: {aps: {sound: 'default'}}},
  },
});

async function getAccessToken(projectId: string, clientEmail: string, privateKey: string) {
  const now = Math.floor(Date.now() / 1000);
  const header = jsonBase64({alg: 'RS256', typ: 'JWT'});
  const claim = jsonBase64({iss: clientEmail, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600});
  const key = await crypto.subtle.importKey('pkcs8', pemBytes(privateKey), {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'}, false, ['sign']);
  const signature = base64Url(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(`${header}.${claim}`))));
  const response = await fetch('https://oauth2.googleapis.com/token', {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams({grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${header}.${claim}.${signature}`})});
  if (!response.ok) {
    const detail = await response.json().catch(() => null) as {error?: string; error_description?: string} | null;
    throw new Error(`Não foi possível autenticar no Firebase (${response.status} ${detail?.error ?? ''} ${detail?.error_description ?? ''}).`.replace(/\s+\)/, ')'));
  }
  const data = await response.json() as {access_token?: string};
  if (!data.access_token) throw new Error('Token Firebase ausente.');
  return data.access_token;
}

export default {
  fetch: withSupabase({auth: 'secret'}, async (request, ctx) => {
    const body = await request.json() as {userIds?: string[]; title?: string; message?: string; data?: Record<string, string>};
    if (!body.userIds?.length || !body.title?.trim() || !body.message?.trim()) return Response.json({message: 'Destinatários, título e mensagem são obrigatórios.'}, {status: 400});
    const projectId = Deno.env.get('FIREBASE_PROJECT_ID');
    const clientEmail = Deno.env.get('FIREBASE_CLIENT_EMAIL');
    const privateKey = Deno.env.get('FIREBASE_PRIVATE_KEY');
    if (!projectId || !clientEmail || !privateKey) return Response.json({message: 'Firebase push não configurado.'}, {status: 503});
    const {data: tokens, error} = await ctx.supabaseAdmin.from('device_push_tokens').select('id, token').in('user_id', body.userIds).is('revoked_at', null);
    if (error) return Response.json({message: 'Não foi possível carregar os dispositivos.'}, {status: 500});
    if (!tokens?.length) return Response.json({sent: 0});
    let accessToken: string;
    try {
      accessToken = await getAccessToken(projectId, clientEmail, privateKey);
    } catch (error) {
      return Response.json({message: error instanceof Error ? error.message : 'Falha ao autenticar no Firebase.'}, {status: 502});
    }
    let sent = 0;
    const failures: {token: string; status: number; code: string | null; message: string | null}[] = [];
    for (const token of tokens) {
      const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {method: 'POST', headers: {Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json'}, body: JSON.stringify(buildFcmMessage(token.token, body.title, body.message, body.data ?? {}))});
      if (response.ok) { sent += 1; continue; }
      const detail = await response.json().catch(() => null) as {error?: {message?: string; status?: string; details?: {errorCode?: string}[]}} | null;
      const code = detail?.error?.details?.find(item => item.errorCode)?.errorCode ?? detail?.error?.status ?? null;
      failures.push({token: token.token.slice(0, 8), status: response.status, code, message: detail?.error?.message ?? null});
      // Só token realmente inválido é revogado; erro de payload ou de credencial não pode apagar dispositivos.
      if (code === 'UNREGISTERED' || (response.status === 404 && code !== 'NOT_FOUND_PROJECT')) await ctx.supabaseAdmin.from('device_push_tokens').update({revoked_at: new Date().toISOString()}).eq('id', token.id);
    }
    return Response.json({sent, attempted: tokens.length, failures});
  }),
};
