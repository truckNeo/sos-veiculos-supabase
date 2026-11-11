const {test}=require('node:test');
const assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const read=f=>fs.readFileSync(path.join(__dirname,'../functions',f),'utf8');
const strip=s=>s.replace(/import[\s\S]*?from\s+['"][^'"]+['"];\s*/g,'');

test('CPF/CNPJ com dígitos verificadores',()=>{
 const m={exports:{}};
 vm.runInNewContext(stripTypeScriptTypes(read('_shared/document.ts').replace(/export const (\w+)/g,'exports.$1')),{exports:m.exports});
 const {isValidCpf,isValidCnpj}=m.exports;
 assert.equal(isValidCpf('52998224725'),true);
 assert.equal(isValidCpf('52998224726'),false);
 assert.equal(isValidCpf('11111111111'),false);
 assert.equal(isValidCnpj('11222333000181'),true);
 assert.equal(isValidCnpj('11222333000182'),false);
 assert.equal(isValidCnpj('00000000000000'),false);
});

function load(file,ctx){
 const module={exports:{}};
 vm.runInNewContext(stripTypeScriptTypes(strip(read(file)).replace('export default','module.exports =')),
  {module,Response,Request,console,withSupabase:(_,h)=>req=>h(req,ctx),normalizeDigits:v=>v.replace(/\D/g,''),hmacDocument:async v=>'hash:'+v});
 return body=>module.exports.fetch(new Request('https://test',{method:'POST',body:JSON.stringify(body)}));
}

test('reenvio usa signup + redirect e responde igual para qualquer e-mail',async()=>{
 const calls=[];
 const run=load('resend-confirmation/index.ts',{supabase:{auth:{async resend(i){calls.push(i);return {error:{code:'x',message:'nope'}}}}}});
 const res=await run({email:' Ana@Example.com '});
 assert.equal(res.status,200);
 assert.deepEqual(await res.json(),{accepted:true});
 assert.equal(calls[0].type,'signup');
 assert.equal(calls[0].email,'ana@example.com');
 assert.match(calls[0].options.emailRedirectTo,/confirmar-conta$/);
 assert.equal((await run({email:'sem-arroba'})).status,400);
});

test('reenvio repassa limite de envio como 429',async()=>{
 const run=load('resend-confirmation/index.ts',{supabase:{auth:{async resend(){return {error:{code:'over_email_send_rate_limit',status:429}}}}}});
 assert.equal((await run({email:'a@b.co'})).status,429);
});

test('login sem confirmar e-mail devolve código e e-mail',async()=>{
 const query={select(){return this},limit(){return this},eq(){return this},async maybeSingle(){return {data:{id:'u1'}}}};
 const run=load('sign-in-with-identifier/index.ts',{
  supabaseAdmin:{from:()=>query,auth:{admin:{async getUserById(){return {data:{user:{email:'a@b.co'}}}}}}},
  supabase:{auth:{async signInWithPassword(){return {data:{},error:{code:'email_not_confirmed',message:'Email not confirmed'}}}}}});
 const res=await run({identifier:'52998224725',password:'secret1'});
 assert.equal(res.status,403);
 const body=await res.json();
 assert.equal(body.code,'email_not_confirmed');
 assert.equal(body.email,'a@b.co');
});
