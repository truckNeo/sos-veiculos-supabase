import {withSupabase} from 'npm:@supabase/server@1.4.1';
import type {ProductDatabase} from '../_shared/product-database.ts';

/** No signed URL: authorization is rechecked for every read and after download. */
export default {
  fetch: withSupabase<ProductDatabase>({auth: 'user'}, async (request, ctx) => {
    if (request.method !== 'POST') return new Response(null, {status: 405});
    let attachmentId: unknown;
    try { ({attachmentId} = await request.json()); } catch { return new Response(null, {status: 400}); }
    if (typeof attachmentId !== 'string' || !/^[0-9a-f-]{36}$/i.test(attachmentId)) return new Response(null, {status: 400});
    const authorize = () => ctx.supabase.rpc('authorize_shared_attachment', {p_attachment_id: attachmentId});
    const {data: path, error} = await authorize();
    if (error || typeof path !== 'string') return new Response(null, {status: 404});
    const {data: file, error: downloadError} = await ctx.supabaseAdmin.storage.from('request-attachments').download(path);
    if (downloadError || !file) return new Response(null, {status: 404});
    const second = await authorize();
    if (second.error || second.data !== path) return new Response(null, {status: 404});
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/heic'].includes(file.type)) return new Response(null, {status: 415});
    return new Response(file, {headers: {'Content-Type': 'application/octet-stream', 'X-File-Type': file.type, 'Cache-Control': 'no-store, private', 'X-Content-Type-Options': 'nosniff'}});
  }),
};
