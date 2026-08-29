const encoder = new TextEncoder();

export const isIuguMockMode = () => Deno.env.get('IUGU_MOCK_MODE') === 'true';

const stripPem = (value: string) => value
  .replace(/-----BEGIN PRIVATE KEY-----/g, '')
  .replace(/-----END PRIVATE KEY-----/g, '')
  .replace(/\s/g, '');

const base64ToBytes = (value: string) => {
  const binary = atob(value);
  return Uint8Array.from(binary, char => char.charCodeAt(0));
};

const bytesToBase64 = (value: ArrayBuffer) => {
  const bytes = new Uint8Array(value);
  let binary = '';
  bytes.forEach(byte => { binary += String.fromCharCode(byte); });
  return btoa(binary);
};

export const iuguToken = () => {
  const environment = Deno.env.get('IUGU_ENV') ?? 'test';
  const token = environment === 'production'
    ? Deno.env.get('IUGU_LIVE_API_TOKEN')
    : Deno.env.get('IUGU_TEST_API_TOKEN');
  return {environment, token};
};

export const iuguBasicAuthorization = (token: string) => `Basic ${btoa(`${token}:`)}`;

export const requireIuguProduction = () => {
  const masterToken = Deno.env.get('IUGU_MASTER_API_TOKEN');
  const privateKey = Deno.env.get('IUGU_RSA_PRIVATE_KEY');
  if (Deno.env.get('IUGU_ENV') !== 'production' || !masterToken || !privateKey) {
    throw new Error('A Iugu Marketplace de produção ainda não está configurada.');
  }
  return {masterToken, privateKey};
};

export const signedIuguFetch = async (
  path: string,
  body: Record<string, unknown>,
  token: string,
  privateKeyPem: string,
) => {
  const requestTime = new Date().toISOString();
  const rawBody = JSON.stringify({...body, api_token: token});
  const document = `POST|${path}\n${token}|${requestTime}\n${rawBody}`;
  const key = await crypto.subtle.importKey(
    'pkcs8',
    base64ToBytes(stripPem(privateKeyPem)),
    {name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256'},
    false,
    ['sign'],
  );
  const signature = bytesToBase64(await crypto.subtle.sign(
    {name: 'RSASSA-PKCS1-v1_5'}, key, encoder.encode(document)));
  return fetch(`https://api.iugu.com${path}`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: iuguBasicAuthorization(token),
      'Request-Time': requestTime,
      Signature: `signature=${signature}`,
    },
    body: rawBody,
  });
};

export const parseIuguError = async (response: Response) => {
  const text = await response.text();
  try {
    const parsed = JSON.parse(text) as {message?: string; errors?: Record<string, string[]>};
    return parsed.message ?? Object.values(parsed.errors ?? {}).flat().join(' ') ?? text;
  } catch {
    return text;
  }
};
