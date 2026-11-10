const {test} = require('node:test');
const assert = require('node:assert/strict');
const {stripTypeScriptTypes} = require('node:module');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
function helper(name, dependencies) {
  const source = fs.readFileSync(path.join(__dirname, '../functions/_shared', name+'.ts'),'utf8');
  const names = [...source.matchAll(/export (?:async )?function (\w+)/g)].map(m=>m[1]);
  const module = {exports:{}};
  vm.runInNewContext(stripTypeScriptTypes(source.replace(/^import[\s\S]*?;\n/gm,'').replace(/export (async )?function /g,'$1function ')) + `\nmodule.exports={${names.join(',')}};`, {module,console,encodeURIComponent, ...dependencies});
  return module.exports;
}
function database(tables, overrides={}) {
  const updates=[],rpcs=[];
  return {updates,rpcs,from(table) {
    const chain = {select(){return this},eq(){return this},in(){return this},is(){return this},update(value){updates.push({table,value});return this},
      single:async()=>({data:tables[table],error:null}),maybeSingle:async()=>({data:tables[table],error:null}),then(resolve){resolve({data:tables[table],error:null})}};
    return chain;
  },async rpc(name,args){rpcs.push({name,args});return overrides[name]??{data:[{id:'t1'}],error:null};}};
}
function transferFixture(extra={}) {
  return database({service_provider_transfers:{id:'t1',request_id:'r1',provider_id:'p1',status:'pending',provider_net_cents:4500,asaas_transfer_id:null,created_at:'2026-11-07T12:00:00Z',...extra},
    provider_asaas_accounts:{wallet_id:'w1',status:'verified',sandbox:true},
    service_payment_charges:[{status:'paid',settled_at:'now',asaas_sandbox:true}], service_requests:{provider_arrival_confirmed_at:'now'}});
}
const actualTransfer={id:'tr1',walletId:'w1',externalReference:'t1',value:45,status:'DONE'};
const dispatch=(fetch, lookup=async()=>null)=>helper('dispatch-transfer',{asaasFetch:fetch,isAsaasSandbox:()=>true,findTransferByReference:lookup}).reconcileDispatchTransfer;
test('repasse só disponibiliza saldo após DONE com valor e destino conferidos',async()=>{
  const db=transferFixture();const payload=[];
  const state=await dispatch(async(url,options)=>{payload.push(options.body);return Response.json(actualTransfer)})(db,'t1');
  assert.equal(state.state,'completed');assert.equal(payload[0].value,45);
  assert.equal(db.rpcs.filter(r=>r.name==='complete_dispatch_transfer').length,1);
});
test('repasse pendente não chama conclusão financeira',async()=>{
  const db=transferFixture();const result=await dispatch(async()=>Response.json({...actualTransfer,status:'PENDING'}))(db,'t1');
  assert.equal(result.state,'processing');assert.ok(!db.rpcs.some(r=>r.name==='complete_dispatch_transfer'));
});
test('destino divergente nunca libera carteira',async()=>{
  const db=transferFixture();const result=await dispatch(async()=>Response.json({...actualTransfer,walletId:'other'}))(db,'t1');
  assert.equal(result.state,'manual_review');assert.ok(!db.rpcs.some(r=>r.name==='complete_dispatch_transfer'));
});
test('timeout mantém envio reservado e retentativa não faz POST',async()=>{
  let posts=0;const fn=dispatch(async(_url,opts)=>{if(opts?.body)posts++;throw Error('timeout')});
  const first=transferFixture();assert.equal((await fn(first,'t1')).state,'manual_review');
  assert.ok(first.rpcs.some(r=>r.name==='mark_asaas_transfer_manual_review'));
  const retry=transferFixture({status:'processing'});assert.equal((await fn(retry,'t1')).state,'manual_review');assert.equal(posts,1);
});
test('referência recuperada concilia envio anterior sem recriar transferência',async()=>{
  const db=transferFixture({status:'manual_review'});let posts=0;
  const result=await dispatch(async(_url,opts)=>{if(opts?.body)posts++;return Response.json(actualTransfer)},async()=> 'tr1')(db,'t1');
  assert.equal(result.state,'completed');assert.equal(posts,0);
});
test('cartão autorizado sem liquidação não libera repasse',async()=>{
  const db=transferFixture();const original=db.from;
  db.from=table=>table==='service_payment_charges'?{select(){return this},eq(){return this},then(resolve){resolve({data:[{status:'paid',settled_at:null,asaas_sandbox:true}]})}}:original(table);
  const result=await dispatch(async()=>{throw Error('Não deve acessar o gateway')})(db,'t1');
  assert.equal(result.state,'processing');assert.equal(db.rpcs.length,0);
});
for (const [state,expected] of [['CONFIRMED',false],['RECEIVED',true],['REFUNDED',false],['CHARGEBACK_REQUESTED',false]]) {
  test(`pagamento ${state} trata liquidação e reversão separadamente`,async()=>{
    const db=database({service_payment_charges:{id:'c1',amount_cents:5000,asaas_sandbox:true}});
    const {reconcilePayment}=helper('payment-reconciliation',{isAsaasSandbox:()=>true,asaasFetch:async()=>Response.json({id:'pay1',externalReference:'c1',value:50,netValue:49,status:state})});
    await reconcilePayment(db,'pay1');
    assert.equal(db.updates.some(u=>u.value.settled_at),expected);
    assert.equal(db.rpcs.some(r=>r.name==='record_payment_reversal'),['REFUNDED','CHARGEBACK_REQUESTED'].includes(state));
  });
}
test('pagamento com valor divergente não confirma',async()=>{
  const db=database({service_payment_charges:{id:'c1',amount_cents:5000,asaas_sandbox:true}});
  const {reconcilePayment}=helper('payment-reconciliation',{isAsaasSandbox:()=>true,asaasFetch:async()=>Response.json({id:'pay1',externalReference:'c1',value:5,status:'RECEIVED'})});
  await assert.rejects(reconcilePayment(db,'pay1'),/divergente/);assert.equal(db.rpcs.length,0);
});
for(const status of ['DONE','FAILED','PENDING']) {
  test(`saque ${status} confere a conta e preserva transições terminais`,async()=>{
    const db=database({provider_asaas_withdrawals:{id:'s1',provider_id:'p1',amount_cents:500,status:'manual_review',asaas_transfer_id:'tr1',payout_pix_key:'12345678901'},provider_asaas_accounts:{api_key_ciphertext:'cipher',api_key_iv:'iv',sandbox:true}});
    const {reconcileWithdrawal}=helper('withdrawal-reconciliation',{isAsaasSandbox:()=>true,decryptProviderApiKey:async()=> 'sub-key',findTransferByReference:async()=>null,
      asaasFetch:async(_url,opts)=>{assert.equal(opts.key,'sub-key');return Response.json({id:'tr1',externalReference:'s1',value:5,pixAddressKey:'12345678901',status})}});
    assert.equal(await reconcileWithdrawal(db,'s1'),status==='DONE'?'paid':status==='FAILED'?'failed':'requested');
  });
}
test('saque com chave diferente não libera reserva',async()=>{
  const db=database({provider_asaas_withdrawals:{id:'s1',provider_id:'p1',amount_cents:500,status:'requested',asaas_transfer_id:'tr1',payout_pix_key:'12345678901'},provider_asaas_accounts:{api_key_ciphertext:'cipher',api_key_iv:'iv',sandbox:true}});
  const {reconcileWithdrawal}=helper('withdrawal-reconciliation',{isAsaasSandbox:()=>true,decryptProviderApiKey:async()=> 'sub-key',asaasFetch:async()=>Response.json({id:'tr1',externalReference:'s1',value:5,pixAddressKey:'other',status:'FAILED'})});
  await assert.rejects(reconcileWithdrawal(db,'s1'),/divergente/);assert.equal(db.updates.length,0);
});
test('busca de transferência percorre páginas e filtra referência localmente',async()=>{
  const urls=[];const {findTransferByReference}=helper('transfer-lookup',{asaasFetch:async url=>{urls.push(url);return Response.json(urls.length===1?{data:[{id:'other',externalReference:'other'}],hasMore:true}:{data:[{id:'tr1',externalReference:'r1'}],hasMore:false})}});
  assert.equal(await findTransferByReference('r1','2026-11-07'),'tr1');assert.equal(urls.length,2);assert.ok(urls[1].includes('offset=100'));assert.ok(!urls[0].includes('externalReference='));
});
