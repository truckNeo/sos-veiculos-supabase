const assert = require('node:assert/strict');
module.exports = async db => {
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
  const q = async (sql,args=[]) => (await db.query(sql,args)).rows;
  const user = async n => db.exec(`reset role;set role authenticated;select set_config('request.jwt.claim.sub','${id(n)}',false)`);
  const admin = async () => db.exec('reset role');
  let checks=0;const ok=(v,m)=>{assert.ok(v,m);checks++;};
  const seedArrival=async requestId=>q(`insert into service_request_locations(request_id,provider_id,latitude,longitude,accuracy_meters,captured_at,received_at,expires_at)
    values($1,$2,-23,-46,5,now()-interval '10 seconds',now()-interval '10 seconds',now()+interval '5 minutes'),
      ($1,$2,-23,-46,5,now()-interval '5 seconds',now()-interval '5 seconds',now()+interval '5 minutes'),
      ($1,$2,-23,-46,5,now(),now(),now()+interval '5 minutes')`,[requestId,id(2)]);
  await admin();
  await q("update service_requests set status='completed',workflow_phase='completed' where requester_id=$1",[id(1)]);
  await q("update provider_wallet_entries set status='paid_out' where provider_id=$1 and status='available'",[id(2)]);
  const request=id(900), charge=id(901);
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase)
    values($1,$2,$3,'engine','Teste de liberação do deslocamento',-23,-46,'open','open')`,[request,id(1),id(10)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,5001,'accepted')`,[request,id(2)]);
  await seedArrival(request);
  await q(`update service_requests set selected_provider_id=$2,status='provider_on_site',workflow_phase='diagnosis' where id=$1`,[request,id(2)]);
  const snapshot=(await q('select provider_snapshot from service_requests where id=$1',[request]))[0].provider_snapshot;
  ok(snapshot.vehicleColor && snapshot.vehicleModel && snapshot.vehiclePlate,'offer captures complete vehicle');
  await q("update provider_vehicles set color='Azul' where provider_id=$1",[id(2)]);
  ok((await q('select provider_snapshot from service_requests where id=$1',[request]))[0].provider_snapshot.vehicleColor===snapshot.vehicleColor,'changing vehicle does not rewrite request');
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status,asaas_payment_id,asaas_sandbox)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',5001,'awaiting_payment','pay_dispatch',true)`,[charge,request,id(2)]);
  await user(1);
  await assert.rejects(q('select confirm_provider_arrival($1)',[request]),/Pagamento/);checks++;
  try {await q('update service_requests set provider_arrival_confirmed_at=now() where id=$1',[request]);} catch (error) {assert.match(error.message,/confirmação|protected|permiss/i);}
  await admin();ok((await q('select provider_arrival_confirmed_at from service_requests where id=$1',[request]))[0].provider_arrival_confirmed_at===null,'REST cannot forge arrival');
  await admin();
  await q("select confirm_asaas_charge_payment('pay_dispatch',null)");
  await user(2);await assert.rejects(q('select confirm_provider_arrival($1)',[request]),/motorista/);checks++;
  await user(1);await q('select confirm_provider_arrival($1)',[request]);await q('select confirm_provider_arrival($1)',[request]);
  await admin();
  const transfers=await q('select * from service_provider_transfers where request_id=$1',[request]);
  ok(transfers.length===1 && transfers[0].provider_net_cents===4501,'arrival creates one transfer and rounds commission');
  await q("update service_requests set status='in_service',workflow_phase='awaiting_driver_confirmation' where id=$1",[request]);
  await user(1);await q('select complete_service_with_review($1,5,$2)',[request,'Atendimento concluído']);await q('select complete_service_with_review($1,5,null)',[request]);
  await admin();
  ok((await q('select * from reviews where request_id=$1',[request])).length===1,'review survives transfer processing and retries');
  ok((await q('select status from provider_wallet_entries where charge_id=$1',[charge]))[0].status==='held','review does not unlock balance');
  await q("update service_provider_transfers set asaas_transfer_id='tr_dispatch' where id=$1",[transfers[0].id]);
  await assert.rejects(q("select complete_dispatch_transfer($1,'tr_dispatch')",[transfers[0].id]),/liquidado/);checks++;
  await q('update service_payment_charges set settled_at=now() where id=$1',[charge]);
  await q("select complete_dispatch_transfer($1,'tr_dispatch')",[transfers[0].id]);await q("select complete_dispatch_transfer($1,'tr_dispatch')",[transfers[0].id]);
  await user(2);let balance=(await q('select * from my_wallet_summary()'))[0];
  ok(Number(balance.available_cents)===4501,'only verified completion releases net amount');
  await assert.rejects(q("select reserve_pix_withdrawal($1,500,'12345678901','CPF',$2)",[id(2),id(902)]),/permission denied/);checks++;
  await admin();
  await q("select reserve_pix_withdrawal($1,1500,'12345678901','CPF',$2)",[id(2),id(902)]);
  await assert.rejects(q("select reserve_pix_withdrawal($1,3500,'12345678901','CPF',$2)",[id(2),id(903)]),/insuficiente/);checks++;
  await assert.rejects(q("select reserve_pix_withdrawal($1,1500,'12345678901','CPF',$2)",[id(2),id(902)]),/registrada/);checks++;
  await user(2);balance=(await q('select * from my_wallet_summary()'))[0];
  ok(Number(balance.available_cents)===3001 && Number(balance.processing_cents)===1500,'partial withdrawal atomically reserves only requested amount');
  await admin();await q("update provider_asaas_withdrawals set status='failed' where id=$1",[id(902)]);
  await user(2);ok(Number((await q('select * from my_wallet_summary()'))[0].available_cents)===4501,'definitive failure returns reservation');
  await admin();await q("select reserve_pix_withdrawal($1,500,'12345678901','CPF',$2)",[id(2),id(904)]);
  await q("update provider_asaas_withdrawals set status='paid' where id=$1",[id(904)]);
  await user(2);balance=(await q('select * from my_wallet_summary()'))[0];
  ok(Number(balance.available_cents)===4001 && Number(balance.processing_cents)===0,'paid withdrawal stays deducted');
  await user(4);ok(Number((await q('select * from my_wallet_summary()'))[0].available_cents)===0,'wallet cannot see another provider');
  await assert.rejects(q('select * from payment_customer_profiles'),/permission denied/);checks++;
  await assert.rejects(q('select claim_asaas_withdrawal(500)'),/permission denied/);checks++;
  await admin();await q("select record_payment_reversal($1,'CHARGEBACK_REQUESTED')",[charge]);
  await assert.rejects(q("select reserve_pix_withdrawal($1,500,'12345678901','CPF',$2)",[id(2),id(905)]),/verificação/);checks++;
  // A nota do deslocamento não conclui o reparo nem duplica o repasse.
  const ratedRequest=id(910), ratedCharge=id(911);
  await admin();
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase)
    values($1,$2,$3,'engine','Avaliação separada do deslocamento',-23,-46,'open','open')`,[ratedRequest,id(1),id(10)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,4000,'accepted')`,[ratedRequest,id(2)]);
  await seedArrival(ratedRequest);
  await q(`update service_requests set selected_provider_id=$2,status='provider_on_site',workflow_phase='diagnosis' where id=$1`,[ratedRequest,id(2)]);
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status,asaas_payment_id,asaas_sandbox)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',4000,'paid','pay_rated',true)`,[ratedCharge,ratedRequest,id(2)]);
  await q(`insert into provider_wallet_entries(provider_id,request_id,charge_id,gross_amount_cents,status)
    values($1,$2,$3,4000,'held')`,[id(2),ratedRequest,ratedCharge]);
  await user(1);
  await q('select confirm_dispatch_arrival_with_review($1,5,$2)',[ratedRequest,'Chegou ao local']);
  await q('select confirm_dispatch_arrival_with_review($1,5,$2)',[ratedRequest,'Chegou ao local']);
  await admin();
  ok((await q('select count(*)::int as n from dispatch_reviews where request_id=$1',[ratedRequest]))[0].n===1,'dispatch review is idempotent');
  ok((await q('select workflow_phase from service_requests where id=$1',[ratedRequest]))[0].workflow_phase==='diagnosis','repair remains open after arrival review');
  ok((await q('select count(*)::int as n from service_provider_transfers where request_id=$1',[ratedRequest]))[0].n===1,'arrival review queues one transfer');
  // Sem resposta do motorista, somente evidência persistida suficiente libera após 24h.
  const autoRequest=id(920), autoCharge=id(921);
  await admin();
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase)
    values($1,$2,$3,'engine','Liberação automática do deslocamento',-23,-46,'open','open')`,[autoRequest,id(1),id(10)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,4000,'accepted')`,[autoRequest,id(2)]);
  await seedArrival(autoRequest);
  await q(`update service_requests set selected_provider_id=$2,status='provider_on_site',workflow_phase='diagnosis' where id=$1`,[autoRequest,id(2)]);
  await q(`update dispatch_arrival_evidence set arrived_at=now()-interval '25 hours',sample_count=5,closest_meters=20,qualified_sample_count=3,geofence_verified=true where request_id=$1`,[autoRequest]);
  await q(`insert into service_request_events(request_id,actor_id,status,note,created_at) values($1,$2,'provider_on_site','Prestador chegou',now()-interval '25 hours')`,[autoRequest,id(2)]);
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status,asaas_payment_id,asaas_sandbox)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',4000,'paid','pay_auto',true)`,[autoCharge,autoRequest,id(2)]);
  await q(`insert into provider_wallet_entries(provider_id,request_id,charge_id,gross_amount_cents,status)
    values($1,$2,$3,4000,'held')`,[id(2),autoRequest,autoCharge]);
  await db.exec("set role service_role;select set_config('request.jwt.claim.role','service_role',false)");
  await q('select * from process_overdue_dispatch_arrivals()');
  await q('select * from process_overdue_dispatch_arrivals()');
  await admin();
  ok((await q('select count(*)::int as n from service_provider_transfers where request_id=$1',[autoRequest]))[0].n===1,'24h fallback creates one transfer');
  ok((await q('select count(*)::int as n from dispatch_reviews where request_id=$1',[autoRequest]))[0].n===0,'fallback never invents a rating');
  // A transição de chegada exige posições recentes do próprio prestador.
  await admin();
  await q("update service_requests set status='completed',workflow_phase='completed' where requester_id=$1",[id(1)]);
  const geoRequest=id(930),geoCharge=id(931);
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase,selected_provider_id)
    values($1,$2,$3,'engine','Geofence de chegada',-23,-46,'offer_accepted','awaiting_dispatch_payment',$4)`,[geoRequest,id(1),id(10),id(2)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,4000,'accepted')`,[geoRequest,id(2)]);
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',4000,'paid')`,[geoCharge,geoRequest,id(2)]);
  await q(`insert into provider_wallet_entries(provider_id,request_id,charge_id,gross_amount_cents,status) values($1,$2,$3,4000,'held')`,[id(2),geoRequest,geoCharge]);
  await user(2);
  await q("select transition_service_request_status($1,'provider_en_route')",[geoRequest]);
  await assert.rejects(q("select transition_service_request_status($1,'provider_on_site')",[geoRequest]),/Chegada não verificada/);checks++;
  await assert.rejects(q("select record_service_request_location($1,-23,-46,5)",[geoRequest]),/permission denied/);checks++;
  await admin();
  await q(`insert into service_request_locations(request_id,provider_id,latitude,longitude,accuracy_meters,captured_at,received_at,expires_at)
    values($1,$2,-23.01,-46,5,now()-interval '10 seconds',now()-interval '10 seconds',now()+interval '5 minutes'),
      ($1,$2,-23.01,-46,5,now()-interval '5 seconds',now()-interval '5 seconds',now()+interval '5 minutes'),
      ($1,$2,-23,-46,5,now()-interval '4 seconds',now()-interval '4 seconds',now()+interval '5 minutes')`,[geoRequest,id(2)]);
  await user(2);
  await assert.rejects(q("select transition_service_request_status($1,'provider_on_site')",[geoRequest]),/Chegada não verificada/);checks++;
  await admin();
  await q(`insert into service_request_locations(request_id,provider_id,latitude,longitude,accuracy_meters,captured_at,received_at,expires_at)
    values($1,$2,-23,-46,5,now(),now(),now()+interval '5 minutes')`,[geoRequest,id(2)]);
  await user(2);
  await q("select transition_service_request_status($1,'provider_on_site')",[geoRequest]);
  await admin();
  const geoEvidence=(await q('select * from dispatch_arrival_evidence where request_id=$1',[geoRequest]))[0];
  ok(geoEvidence.geofence_verified && geoEvidence.qualified_sample_count===2,'two fresh nearby samples validate arrival; far samples do not qualify');
  await q(`update dispatch_arrival_evidence set arrived_at=now()-interval '25 hours' where request_id=$1`,[geoRequest]);
  await q(`update service_request_events set created_at=now()-interval '25 hours' where request_id=$1 and status='provider_on_site'`,[geoRequest]);
  await db.exec("set role service_role;select set_config('request.jwt.claim.role','service_role',false)");
  await q('select * from process_overdue_dispatch_arrivals()');
  await admin();
  ok((await q('select count(*)::int n from service_provider_transfers where request_id=$1',[geoRequest]))[0].n===0,'two near and two far positions cannot trigger automatic payout');
  ok((await q('select count(*)::int n from dispatch_arrival_manual_reviews where request_id=$1',[geoRequest]))[0].n===1,'insufficient GPS goes to human review');

  await q("update service_requests set status='completed',workflow_phase='completed' where id=$1",[geoRequest]);
  const manualRequest=id(940),manualCharge=id(941);
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase,selected_provider_id)
    values($1,$2,$3,'engine','Chegada manual sem GPS',-23,-46,'offer_accepted','awaiting_dispatch_payment',$4)`,[manualRequest,id(1),id(10),id(2)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,4000,'accepted')`,[manualRequest,id(2)]);
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',4000,'paid')`,[manualCharge,manualRequest,id(2)]);
  await q(`insert into provider_wallet_entries(provider_id,request_id,charge_id,gross_amount_cents,status) values($1,$2,$3,4000,'held')`,[id(2),manualRequest,manualCharge]);
  await user(2);
  await q("select transition_service_request_status($1,'provider_en_route')",[manualRequest]);
  await q('select request_manual_provider_arrival($1,$2)',[manualRequest,'GPS sem sinal perto do motorista']);
  await q('select request_manual_provider_arrival($1,$2)',[manualRequest,'GPS sem sinal perto do motorista']);
  await user(1);
  await q('select confirm_manual_provider_arrival_with_review($1,5,$2)',[manualRequest,'Confirmado presencialmente']);
  await admin();
  ok((await q('select status,provider_arrival_confirmed_at from service_requests where id=$1',[manualRequest]))[0].provider_arrival_confirmed_at!==null,'driver can confirm manual arrival');
  ok(!(await q('select geofence_verified from dispatch_arrival_evidence where request_id=$1',[manualRequest]))[0].geofence_verified,'manual arrival is never GPS verified');
  ok((await q('select count(*)::int n from service_provider_transfers where request_id=$1',[manualRequest]))[0].n===1,'manual arrival still needs driver review before payout');
  await q("update service_requests set status='completed',workflow_phase='completed' where id=$1",[manualRequest]);
  const disputedManual=id(950),disputedCharge=id(951);
  await q(`insert into service_requests(id,requester_id,vehicle_id,problem_type,description,latitude,longitude,status,workflow_phase,selected_provider_id)
    values($1,$2,$3,'engine','Chegada manual contestada',-23,-46,'offer_accepted','awaiting_dispatch_payment',$4)`,[disputedManual,id(1),id(10),id(2)]);
  await q(`insert into provider_offers(request_id,provider_id,travel_fee_cents,status) values($1,$2,4000,'accepted')`,[disputedManual,id(2)]);
  await q(`insert into service_payment_charges(id,request_id,offer_id,provider_id,kind,amount_cents,status)
    values($1,$2,(select id from provider_offers where request_id=$2),$3,'dispatch',4000,'paid')`,[disputedCharge,disputedManual,id(2)]);
  await user(2);
  await q("select transition_service_request_status($1,'provider_en_route')",[disputedManual]);
  await q('select request_manual_provider_arrival($1,$2)',[disputedManual,'Localização do celular indisponível']);
  await assert.rejects(q(`update dispatch_manual_arrival_requests set status='confirmed' where request_id=$1`,[disputedManual]),/permission denied/);checks++;
  await user(1);
  await q('select open_manual_provider_arrival_dispute($1,$2)',[disputedManual,'O prestador não chegou ao endereço informado.']);
  await admin();
  ok((await q('select status,workflow_phase from service_requests where id=$1',[disputedManual]))[0].workflow_phase==='in_dispute','driver can dispute unverified manual arrival');
  ok((await q('select count(*)::int n from service_provider_transfers where request_id=$1',[disputedManual]))[0].n===0,'manual arrival dispute cannot queue payout');
  console.log(`PASS dispatch / wallet contracts (${checks} checks)`);
};
