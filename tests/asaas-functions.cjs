// Node >=22.14. Executa os handlers reais, substituindo apenas auth, banco e HTTP externo.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
function load(name,ctx,fetch,sandbox=true,env={}){
  const source=fs.readFileSync(path.join(__dirname,'../functions',name,'index.ts'),'utf8')
    .replace(/^import .*;\n/gm,'').replace('export default','module.exports =');
  const module={exports:{}};
  vm.runInNewContext(stripTypeScriptTypes(source),{module,Response,encodeURIComponent,console,
    Deno:{env:{get:(key)=>env[key]}},withSupabase:(_config,handler)=>(request)=>handler(request,ctx),asaasFetch:fetch,isAsaasSandbox:()=>sandbox,normalizeDigits:(v)=>String(v).replace(/\D/g,''),hmacDocument:async()=> 'document_hash'});
  return module.exports.fetch;
}
const request=(body)=>new Request('https://local.test',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
const gateway=(body)=>Response.json(body);
function fixture(overrides={}){
  const op={id:'op-1',decision:'driver_refunded',status:'pending',amount_cents:5000,asaas_payment_id:'pay-1',wallet_id:null,sandbox:true,external_id:null,decision_note:'Reembolso autorizado.',...overrides};
  const updates=[];const calls=[];
  const chain={update(value){updates.push(value);return this;},eq(){return this;},neq(){return this;},then(resolve){resolve({error:null});}};
  const ctx={supabase:{rpc:async(name)=>{calls.push(name);return name==='is_service_dispute_admin'?{data:true}:name==='begin_asaas_dispute_settlement'?{data:[op]}:{error:null};}},supabaseAdmin:{rpc:async()=>({data:[op]}),from:()=>chain}};
  return {op,updates,calls,ctx};
}
test('não administrador não acessa o gateway',async()=>{
  const f=fixture();f.ctx.supabase.rpc=async()=>({data:false});let calls=0;
  const handler=load('decide-asaas-dispute',f.ctx,async()=>{calls++;});
  assert.equal((await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}))).status,403);
  assert.equal(calls,0);
});
test('estorno pendente não encerra a disputa nem libera saldo',async()=>{
  const f=fixture();const calls=[];
  const handler=load('decide-asaas-dispute',f.ctx,async(url,opts)=>{calls.push({url,opts});return gateway({id:'pay-1',status:opts?'REFUND_REQUESTED':'RECEIVED'});});
  const response=await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}));
  assert.equal(response.status,409);assert.equal(calls.filter(c=>c.opts).length,1);
  assert.equal(calls[1].url,'/payments/pay-1/refund');
  assert.equal(f.updates[0].status,'processing');assert.ok(!f.calls.includes('decide_service_dispute'));
});
test('nova tentativa concilia estorno confirmado sem repetir POST',async()=>{
  const f=fixture({status:'processing'});let posts=0;
  const handler=load('decide-asaas-dispute',f.ctx,async(_url,opts)=>{if(opts)posts++;return gateway({id:'pay-1',status:'REFUNDED'});});
  assert.equal((await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}))).status,200);
  assert.equal(posts,0);assert.equal(f.updates[0].status,'confirmed');assert.ok(f.calls.includes('decide_service_dispute'));
});
test('timeout de estorno exige revisão e não é reenviado',async()=>{
  const f=fixture();let posts=0;
  const handler=load('decide-asaas-dispute',f.ctx,async(_url,opts)=>{if(opts){posts++;throw new Error('timeout');}return gateway({id:'pay-1',status:'RECEIVED'});});
  assert.equal((await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}))).status,502);
  assert.equal(f.updates.at(-1).status,'manual_review');f.op.status='manual_review';
  await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}));
  assert.equal(posts,1);assert.ok(!f.calls.includes('decide_service_dispute'));
});
test('ambiente financeiro divergente impede qualquer chamada Asaas',async()=>{
  const f=fixture({sandbox:false});let calls=0;
  const handler=load('decide-asaas-dispute',f.ctx,async()=>{calls++;});
  assert.equal((await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}))).status,409);assert.equal(calls,0);
});
test('claim perdido para outro worker não duplica o estorno',async()=>{
  const f=fixture();f.ctx.supabaseAdmin.rpc=async()=>({data:[]});let posts=0;
  const handler=load('decide-asaas-dispute',f.ctx,async(_url,opts)=>{if(opts)posts++;return gateway({id:'pay-1',status:'RECEIVED'});});
  assert.equal((await handler(request({requestId:'r1',decision:'driver_refunded',note:'Reembolso autorizado.'}))).status,409);assert.equal(posts,0);
});
test('repasse em disputa envia o líquido e só finaliza em DONE',async()=>{
  const f=fixture({decision:'provider_released',wallet_id:'wallet-1',amount_cents:4500});let payload;
  const handler=load('decide-asaas-dispute',f.ctx,async(_url,opts)=>{payload=opts.body;return gateway({id:'transfer-1',status:'DONE'});});
  assert.equal((await handler(request({requestId:'r1',decision:'provider_released',note:'Repasse autorizado.'}))).status,200);
  assert.equal(payload.value,45);assert.equal(payload.walletId,'wallet-1');assert.equal(payload.externalReference,'op-1');assert.ok(f.calls.includes('decide_service_dispute'));
});
function releaseFixture(stored){
  const calls=[];const updates=[];
  const chain={select(){return this;},eq(){return this;},single:async()=>({data:stored}),update(value){updates.push(value);return this;},then(resolve){resolve({data:[{asaas_sandbox:true}],error:null});}};
  const ctx={supabase:{from:()=>chain,rpc:async()=>({data:[{transfer_id:'t1'}]})},supabaseAdmin:{from:()=>chain,rpc:async(name)=>{calls.push(name);return {data:[{provider_net_cents:4500,wallet_id:'wallet-1'}]};}}};
  return {ctx,calls,updates};
}
test('repasse comum aceito ainda não é sucesso financeiro',async()=>{
  const f=releaseFixture({id:'t1',status:'pending',asaas_transfer_id:null});
  const handler=load('release-asaas-payment',f.ctx,async()=>gateway({id:'transfer-1',status:'PENDING'}));
  assert.equal((await handler(request({requestId:'r1',rating:5,comment:null}))).status,409);
  assert.equal(f.updates[0].asaas_transfer_id,'transfer-1');assert.ok(!f.calls.includes('complete_asaas_payment_release_with_review'));
});
test('repasse comum é conciliado sem repetir transferência',async()=>{
  const f=releaseFixture({id:'t1',status:'processing',asaas_transfer_id:'transfer-1'});let posts=0;
  const handler=load('release-asaas-payment',f.ctx,async(_url,opts)=>{if(opts)posts++;return gateway({id:'transfer-1',status:'DONE'});});
  assert.equal((await handler(request({requestId:'r1',rating:5,comment:null}))).status,200);
  assert.equal(posts,0);assert.ok(f.calls.includes('complete_asaas_payment_release_with_review'));
});

test('webhook de operação recusa token ausente',async()=>{
  const handler=load('asaas-operation-webhook',{},async()=>{throw Error('não deveria acessar');});
  assert.equal((await handler(request({type:'TRANSFER'}))).status,503);
});
test('webhook só aprova repasse registrado com valor e wallet conferidos',async()=>{
  const reference='00000000-0000-4000-8000-000000000123';
  const ctx={supabaseAdmin:{from:(table)=>{const chain={select(){return this},eq(){return this},maybeSingle:async()=>({data:table==='service_provider_transfers'?{provider_id:'p1',provider_net_cents:4500,status:'processing'}:{wallet_id:'wallet-1',status:'verified'}})};return chain;}}};
  const run=async(wallet)=>{
    const handler=load('asaas-operation-webhook',ctx,async()=>gateway({walletId:wallet,value:45,externalReference:reference}),true,{ASAAS_OPERATION_WEBHOOK_TOKEN:'test-token'});
    const req=request({type:'TRANSFER',transfer:{id:'transfer-1',externalReference:reference}});req.headers.set('asaas-access-token','test-token');
    return (await handler(req)).json();
  };
  assert.equal((await run('wallet-1')).status,'APPROVED');assert.equal((await run('other-wallet')).status,'REFUSED');
});

function pixFixture(claimed=true){
  const charge={id:'charge-1',provider_id:'provider-1',kind:'dispatch',status:'pending',amount_cents:5000,asaas_sandbox:true};
  const updates=[];const rpcCalls=[];
  const ctx={supabase:{from:()=>({select(){return this;},eq(){return this;},maybeSingle:async()=>({data:charge})}),
    auth:{getUser:async()=>({data:{user:{id:'user-1',email:'test@example.test'}}})},
    rpc:async(name,args)=>{rpcCalls.push({name,args});return {error:null};}},
    supabaseAdmin:{from:()=>({select(){return this;},eq(){return this;},update(v){updates.push(v);return this;},maybeSingle:async()=>({data:{status:'verified'}}),then(resolve){resolve({error:null});}}),
    rpc:async()=>({data:claimed})}};
  // profiles é lido com o cliente autenticado, depois da cobrança.
  let reads=0;
  ctx.supabase.from=()=>({select(){return this;},eq(){return this;},maybeSingle:async()=>({data:reads++%2===0?charge:{full_name:'Teste',document_hash:'document_hash',asaas_customer_id:'cus-1'}})});
  return {ctx,charge,updates,rpcCalls};
}
const pixPayment={id:'pay-pix',externalReference:'charge-1',customer:'cus-1',billingType:'PIX',value:50,status:'PENDING'};
const pixRequest=()=>request({chargeId:'charge-1',payerDocument:'12345678901'});
test('checkout reservado emite uma cobrança e devolve QR sem URL de fatura',async()=>{
  const f=pixFixture();const calls=[];
  const handler=load('create-asaas-pix',f.ctx,async(url,opts)=>{calls.push({url,opts});return gateway(opts?pixPayment:{payload:'pix-code',encodedImage:'base64-image'});});
  const response=await handler(pixRequest());assert.equal(response.status,200);
  assert.deepEqual(await response.json(),{chargeId:'charge-1',paymentId:'pay-pix',ticketUrl:null,copyPaste:'pix-code',qrCode:'base64-image'});
  assert.equal(calls.filter(c=>c.opts).length,1);assert.equal(f.updates[0].asaas_payment_id,'pay-pix');
});
test('checkout já reservado recupera por referência sem outro POST',async()=>{
  const f=pixFixture(false);const calls=[];
  const handler=load('create-asaas-pix',f.ctx,async(url,opts)=>{calls.push({url,opts});return gateway(url.includes('externalReference')?{data:[pixPayment]}:{payload:'pix-code'});});
  assert.equal((await handler(pixRequest())).status,200);assert.equal(calls.filter(c=>c.opts).length,0);
  assert.ok(calls[0].url.includes('externalReference=charge-1'));
});
test('reserva sem cobrança encontrada aguarda conciliação sem novo POST',async()=>{
  const f=pixFixture(false);let posts=0;
  const handler=load('create-asaas-pix',f.ctx,async(_url,opts)=>{if(opts)posts++;return gateway({data:[]});});
  assert.equal((await handler(pixRequest())).status,409);assert.equal(posts,0);assert.equal(f.rpcCalls.length,0);
});
test('timeout de emissão não conclui checkout nem desfaz a reserva',async()=>{
  const f=pixFixture();let posts=0;
  const handler=load('create-asaas-pix',f.ctx,async()=>{posts++;throw Error('timeout');});
  assert.equal((await handler(pixRequest())).status,502);assert.equal(posts,1);assert.equal(f.rpcCalls.length,0);
  assert.equal(f.updates.length,0);
});
test('conciliação com valor diferente falha sem marcar o checkout',async()=>{
  const f=pixFixture(false);const handler=load('create-asaas-pix',f.ctx,async()=>gateway({data:[{...pixPayment,value:500}]}));
  assert.equal((await handler(pixRequest())).status,409);assert.equal(f.rpcCalls.length,0);
});
test('checkout de outro ambiente é recusado antes do gateway',async()=>{
  const f=pixFixture();Object.assign(f.charge,{asaas_checkout_claimed_at:'2026-10-12',asaas_sandbox:false});
  let calls=0;const handler=load('create-asaas-pix',f.ctx,async()=>{calls++;});
  assert.equal((await handler(pixRequest())).status,409);assert.equal(calls,0);
});

test('falha de QR depois da emissão é recuperada sem duplicar cobrança',async()=>{
  const f=pixFixture();let claims=0;let posts=0;let qrs=0;
  f.ctx.supabaseAdmin.rpc=async()=>({data:claims++===0});
  const handler=load('create-asaas-pix',f.ctx,async(url,opts)=>{
    if(opts){posts++;return gateway(pixPayment);}
    if(url.includes('externalReference')) return gateway({data:[pixPayment]});
    return qrs++===0?Response.json({},{status:503}):gateway({payload:'pix-code'});
  });
  assert.equal((await handler(pixRequest())).status,502);
  assert.equal(f.updates[0].asaas_payment_id,'pay-pix');
  assert.equal((await handler(pixRequest())).status,200);
  assert.equal(posts,1);assert.equal(f.rpcCalls.length,1);
});
