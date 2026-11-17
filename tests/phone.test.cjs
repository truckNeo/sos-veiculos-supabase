// Node >=22.14. Carrega o helper real (TypeScript) sem Deno.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {stripTypeScriptTypes}=require('node:module');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const module_={exports:{}};
vm.runInNewContext(stripTypeScriptTypes(fs.readFileSync(path.join(__dirname,'../supabase/functions/_shared/phone.ts'),'utf8').replace('export function','module.exports.asaasMobilePhone=function')),{module:module_});
const {asaasMobilePhone}=module_.exports;
test('celular com +55 vira DDD + número',()=>{
  assert.equal(asaasMobilePhone('+5545999048090'),'45999048090');
  assert.equal(asaasMobilePhone('5545999048090'),'45999048090');
  assert.equal(asaasMobilePhone('(45) 99904-8090'),'45999048090');
});
test('número inválido ou fixo é recusado',()=>{
  assert.equal(asaasMobilePhone('4533221100'),null);
  assert.equal(asaasMobilePhone('45899048090'),null);
  assert.equal(asaasMobilePhone('0599048090'),null);
  assert.equal(asaasMobilePhone('123'),null);
  assert.equal(asaasMobilePhone(null),null);
  assert.equal(asaasMobilePhone(undefined),null);
});
