const {test}=require('node:test');
const assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname, '../functions/sign-in-with-identifier/index.ts'),'utf8')
 .replace(/import[\s\S]*?from\s+['"][^'"]+['"];\s*/g,'').replace('export default','module.exports =');
function fixture(){
 const calls=[];
 const query={select(){return this},limit(){return this},eq(k,v){calls.push([k,v]);return this},async maybeSingle(){return {data:{id:'provider'}}}};
 const ctx = {
   supabaseAdmin: {
     from() { return query; },
     auth: {admin: {async getUserById() { return {data: {user: {email: 'provider@example.test'}}}; }}},
   },
   supabase: {
     auth: {async signInWithPassword(input) {
       calls.push(input);
       return {data: {session: {access_token: 'test'}}};
     }},
   },
 };
 const module={exports:{}};
 vm.runInNewContext(stripTypeScriptTypes(source),{module,Response,withSupabase:(_,handler)=>req=>handler(req,ctx),normalizeDigits:v=>v.replace(/\D/g,''),hmacDocument:async v=>'hash:'+v});
 return {calls,run:body=>module.exports.fetch(new Request('https://test',{method:'POST',body:JSON.stringify(body)}))};
}
for(const [identifier,digits] of [['123.456.789-00','12345678900'],['12.345.678/0001-95','12345678000195']]){
 test('login por documento '+identifier,async()=>{const f=fixture();assert.equal((await f.run({identifier,password:'secret'})).status,200);assert.equal(f.calls[0][0],'document_hash');assert.equal(f.calls[0][1],'hash:'+digits);});
}
for(const identifier of ['5511999997777','1199997777','',null,123]){
 test('entrada inválida não consulta Auth: '+identifier,async()=>{const f=fixture();assert.equal((await f.run({identifier,password:'secret'})).status,400);assert.equal(f.calls.length,0);});
}
test('11 dígitos são consultados somente como documento, sem busca por telefone',async()=>{const f=fixture();await f.run({identifier:'11999997777',password:'secret'});assert.equal(f.calls[0][0],'document_hash');assert.equal(f.calls.some(c=>c[0]==='phone_lookup'),false);});
