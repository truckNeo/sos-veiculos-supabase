// Contratos de segurança (RLS). Complementa product-contracts.cjs.
// Usa os mesmos fixtures de usuário: 1 e 5 motoristas, 2 e 4 prestadores.
const assert = require('node:assert/strict');

module.exports = async db => {
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const q = async (sql, args = []) => (await db.query(sql, args)).rows;
  const user = async n =>
    db.exec(`reset role;set role authenticated;select set_config('request.jwt.claim.sub','${id(n)}',false);`);
  const admin = async () => db.exec('reset role');
  let checks = 0;
  const ok = (v, m) => {
    assert.ok(v, m);
    checks++;
  };
  // RLS rejeita o INSERT com erro de política, não com linhas afetadas = 0.
  const denied = async (sql, args) => {
    await assert.rejects(q(sql, args), /row-level security/i);
    checks++;
  };

  // Cria um atendimento do motorista id(1) com o prestador id(2) selecionado,
  // incluindo a proposta aceita, como acontece em produção.
  const openRequest = async (requestId, phase, status) => {
    await admin();
    await q(
      `insert into service_requests
         (id, requester_id, vehicle_id, problem_type, description, latitude, longitude,
          status, workflow_phase, selected_provider_id)
       values ($1, $2, $3, 'engine', 'Motor falhando', -23, -46, $4, $5, $6)`,
      [requestId, id(1), id(10), status, phase, id(2)],
    );
    await q(
      `insert into provider_offers(request_id, provider_id, travel_fee_cents, status)
       values($1, $2, 5000, 'accepted')`,
      [requestId, id(2)],
    );
  };

  // Atendimento concluído: motorista id(1), prestador selecionado id(2).
  const request = id(300);
  await openRequest(request, 'completed', 'completed');

  // Um terceiro não pode avaliar um atendimento do qual não participou.
  // Antes da correção isso era aceito e, por causa do UNIQUE(request_id),
  // bloqueava a avaliação legítima.
  await user(3);
  await denied(
    `insert into reviews(request_id, reviewer_id, provider_id, rating) values($1, $2, $3, 5)`,
    [request, id(3), id(2)],
  );
  await denied(
    `insert into reviews(request_id, reviewer_id, driver_id, provider_id, rating) values($1, $2, $3, $4, 1)`,
    [request, id(3), id(1), id(2)],
  );

  // O prestador não pode se passar pelo motorista, nem vice-versa.
  await user(2);
  await denied(
    `insert into reviews(request_id, reviewer_id, provider_id, rating) values($1, $2, $3, 5)`,
    [request, id(1), id(2)],
  );

  // Um prestador que não foi selecionado também não pode avaliar.
  await user(4);
  await denied(
    `insert into reviews(request_id, reviewer_id, driver_id, provider_id, rating) values($1, $2, $3, $4, 5)`,
    [request, id(4), id(1), id(2)],
  );

  // O motorista do atendimento avalia o prestador: permitido.
  await user(1);
  await q(
    `insert into reviews(request_id, reviewer_id, provider_id, rating, comment) values($1, $2, $3, 5, 'Ótimo')`,
    [request, id(1), id(2)],
  );
  await admin();
  ok((await q('select * from reviews where request_id=$1', [request])).length === 1, 'driver review stored');

  // O prestador selecionado avalia o motorista num atendimento sem avaliação.
  // provider_id fica nulo: quem está sendo avaliado é o motorista.
  const second = id(301);
  await openRequest(second, 'awaiting_driver_confirmation', 'in_service');
  await user(2);
  await q(
    `insert into reviews(request_id, reviewer_id, driver_id, rating) values($1, $2, $3, 4)`,
    [second, id(2), id(1)],
  );
  await admin();
  ok((await q('select * from reviews where request_id=$1', [second])).length === 1, 'provider review stored');

  // Os dois lados avaliam o mesmo atendimento. Antes a UNIQUE(request_id)
  // impedia: quem avaliasse primeiro travava o outro para sempre.
  await user(2);
  await q(
    `insert into reviews(request_id, reviewer_id, driver_id, rating) values($1, $2, $3, 3)`,
    [request, id(2), id(1)],
  );
  await admin();
  ok(
    (await q('select * from reviews where request_id=$1', [request])).length === 2,
    'both sides review the same request',
  );

  // O mesmo autor não avalia o mesmo atendimento duas vezes.
  await user(2);
  await assert.rejects(
    q(`insert into reviews(request_id, reviewer_id, driver_id, rating) values($1, $2, $3, 1)`, [
      request,
      id(2),
      id(1),
    ]),
    /duplicate key|unique/i,
    'uma avaliação por autor e atendimento',
  );
  checks++;

  // Uma linha avalia exatamente um lado, nunca os dois. Roda como admin para
  // isolar a constraint: sob RLS a linha já seria recusada pela política.
  await admin();
  await assert.rejects(
    q(
      `insert into reviews(request_id, reviewer_id, driver_id, provider_id, rating) values($1, $2, $3, $4, 5)`,
      [second, id(1), id(1), id(2)],
    ),
    /reviews_single_target_check|violates check/i,
    'provider_id e driver_id são mutuamente exclusivos',
  );
  checks++;
  await assert.rejects(
    q(`insert into reviews(request_id, reviewer_id, rating) values($1, $2, 5)`, [second, id(5)]),
    /reviews_single_target_check|violates check/i,
    'uma avaliação precisa ter um lado avaliado',
  );
  checks++;

  // Atendimento que ainda não chegou à conferência não aceita avaliação.
  const early = id(302);
  await openRequest(early, 'diagnosis', 'provider_en_route');
  await user(1);
  await denied(
    `insert into reviews(request_id, reviewer_id, provider_id, rating) values($1, $2, $3, 5)`,
    [early, id(1), id(2)],
  );

  // Nenhuma função viva pode depender da unique antiga de reviews. As funções
  // de liberação de pagamento gravavam a avaliação com
  // `on conflict (request_id)`; sem a unique de coluna, isso falharia em
  // runtime com "no unique or exclusion constraint matching".
  await admin();
  const staleConflict = await q(`
    select p.proname from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc ilike '%on conflict (request_id)%'
      and p.prosrc ilike '%reviews%'`);
  ok(staleConflict.length === 0, `funções com ON CONFLICT obsoleto: ${staleConflict.map(r => r.proname)}`);

  const fixedConflict = await q(`
    select p.proname from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc ilike '%on conflict (request_id, reviewer_id)%'`);
  ok(
    fixedConflict.length >= 2,
    `liberação de pagamento usa o novo alvo (${fixedConflict.length} função(ões))`,
  );

  // --- Disputa aberta pelos dois lados ---------------------------------

  // Na chegada (fase diagnosis) o motorista contesta. Antes a RPC exigia a
  // fase awaiting_driver_confirmation e este botão sempre falhava.
  await user(1);
  await q(`select open_service_dispute($1, $2)`, [early, 'O prestador não está no local informado.']);
  await admin();
  ok(
    (await q(`select workflow_phase, status from service_requests where id=$1`, [early]))[0]
      .workflow_phase === 'in_dispute',
    'driver dispute at arrival moves to in_dispute',
  );
  ok(
    (await q(`select opened_by from service_disputes where request_id=$1`, [early]))[0].opened_by === id(1),
    'dispute records who opened it',
  );

  // O prestador abre disputa na conferência. Antes a RPC só aceitava o
  // solicitante, então este botão também sempre falhava.
  const providerDispute = id(303);
  await openRequest(providerDispute, 'awaiting_driver_confirmation', 'in_service');
  await user(2);
  await q(`select open_service_dispute($1, $2)`, [
    providerDispute,
    'O motorista não confirma a conclusão do serviço.',
  ]);
  await admin();
  ok(
    (await q(`select opened_by from service_disputes where request_id=$1`, [providerDispute]))[0]
      .opened_by === id(2),
    'provider can open dispute',
  );

  // Quem não participa do atendimento continua fora.
  const outsider = id(304);
  await openRequest(outsider, 'diagnosis', 'provider_on_site');
  await user(3);
  await assert.rejects(
    q(`select open_service_dispute($1, $2)`, [outsider, 'Quero abrir uma disputa qualquer.']),
    /participantes/i,
    'terceiro não abre disputa',
  );
  checks++;

  // Fase anterior ao serviço não aceita disputa.
  const tooEarly = id(305);
  await openRequest(tooEarly, 'awaiting_dispatch_payment', 'offer_accepted');
  await user(1);
  await assert.rejects(
    q(`select open_service_dispute($1, $2)`, [tooEarly, 'Ainda nem começou, mas quero disputar.']),
    /não pode abrir disputa/i,
    'disputa exige serviço em andamento',
  );
  checks++;

  // Uma disputa por atendimento.
  await user(2);
  await assert.rejects(
    q(`select open_service_dispute($1, $2)`, [providerDispute, 'Quero abrir uma segunda disputa.']),
    /já possui uma disputa/i,
    'uma disputa por atendimento',
  );
  checks++;

  // --- Confirmação de chegada ------------------------------------------

  const arrival = id(306);
  await openRequest(arrival, 'diagnosis', 'provider_on_site');
  await user(1);
  await q(`select confirm_provider_arrival($1)`, [arrival]);
  await q(`select confirm_provider_arrival($1)`, [arrival]);
  await admin();
  ok(
    (
      await q(
        `select * from service_request_events where request_id=$1 and note='Motorista confirmou a chegada do prestador.'`,
        [arrival],
      )
    ).length === 1,
    'arrival confirmation is recorded once',
  );

  // Só o motorista do atendimento confirma.
  await user(2);
  await assert.rejects(
    q(`select confirm_provider_arrival($1)`, [arrival]),
    /motorista do atendimento/i,
    'prestador não confirma a própria chegada',
  );
  checks++;

  // Fora de provider_on_site, não há o que confirmar.
  const notArrived = id(307);
  await openRequest(notArrived, 'diagnosis', 'provider_en_route');
  await user(1);
  await assert.rejects(
    q(`select confirm_provider_arrival($1)`, [notArrived]),
    /prestador está no local/i,
    'confirmação exige prestador no local',
  );
  checks++;

  // --- Pagamento confirmado antes do deslocamento ----------------------

  const departure = id(310);
  await admin();
  await q(
    `insert into service_requests
       (id, requester_id, vehicle_id, problem_type, description, latitude, longitude,
        status, workflow_phase, selected_provider_id)
     values ($1, $2, $3, 'engine', 'Motor falhando', -23, -46, 'offer_accepted',
             'awaiting_dispatch_payment', $4)`,
    [departure, id(1), id(10), id(2)],
  );
  const offerId = (
    await q(
      `insert into provider_offers(request_id, provider_id, travel_fee_cents, status)
       values($1, $2, 5000, 'accepted') returning id`,
      [departure, id(2)],
    )
  )[0].id;

  // Só o comprovante não libera mais: era exatamente o furo do fluxo.
  await q(
    `insert into request_attachments(request_id, uploaded_by, kind, storage_path)
     values($1, $2, 'payment_receipt', 'recibos/x.jpg')`,
    [departure, id(1)],
  );
  await user(2);
  await assert.rejects(
    q(`select transition_service_request_status($1, 'provider_en_route', null)`, [departure]),
    /pagamento ainda não foi confirmado/i,
    'comprovante sozinho não libera o deslocamento',
  );
  checks++;

  // Com a cobrança paga pelo provedor, o deslocamento inicia.
  await admin();
  await q(
    `insert into service_payment_charges(request_id, offer_id, provider_id, kind, amount_cents, status)
     values($1, $2, $3, 'dispatch', 5000, 'paid')`,
    [departure, offerId, id(2)],
  );
  await user(2);
  await q(`select transition_service_request_status($1, 'provider_en_route', null)`, [departure]);
  await admin();
  ok(
    (await q(`select status from service_requests where id=$1`, [departure]))[0].status ===
      'provider_en_route',
    'pagamento confirmado libera o deslocamento',
  );

  // --- Fila de push do motorista ---------------------------------------

  await admin();
  const pushed = async (requestId, kind) =>
    (await q(`select * from driver_event_push_outbox where request_id=$1 and kind=$2`, [requestId, kind]))
      .length;

  // A proposta aceita criada em openRequest já deve ter enfileirado aviso.
  ok((await pushed(departure, 'offer_received')) === 1, 'proposta enfileira push ao motorista');

  // A transição para deslocamento também enfileirou, via gatilho de status.
  ok((await pushed(departure, 'provider_en_route')) === 1, 'deslocamento enfileira push');

  // Transição repetida não duplica o aviso.
  await q(`update service_requests set status='provider_on_site' where id=$1`, [departure]);
  await q(`update service_requests set status='provider_en_route' where id=$1`, [departure]);
  await q(`update service_requests set status='provider_on_site' where id=$1`, [departure]);
  ok((await pushed(departure, 'provider_on_site')) === 1, 'evento repetido não duplica push');

  // A conferência avisa o motorista.
  await q(
    `update service_requests set workflow_phase='awaiting_driver_confirmation' where id=$1`,
    [departure],
  );
  ok(
    (await pushed(departure, 'awaiting_driver_confirmation')) === 1,
    'conferência enfileira push',
  );

  // Disputa avisa os dois lados.
  ok(
    (await q(`select * from driver_event_push_outbox where request_id=$1 and kind='dispute_opened'`, [early]))
      .length === 2,
    'disputa avisa motorista e prestador',
  );

  // A fila é inacessível para quem não é service role: o grant foi revogado,
  // então nem chega a ser uma questão de RLS.
  await user(1);
  await assert.rejects(
    q('select * from driver_event_push_outbox'),
    /permission denied/i,
    'outbox fechado para authenticated',
  );
  checks++;
  // --- Exclusão de conta ------------------------------------------------

  // Com atendimento em andamento, a exclusão é recusada: encerrar no meio
  // deixaria a outra parte sem contato.
  await user(1);
  await assert.rejects(
    q('select request_account_deletion()'),
    /atendimentos em andamento/i,
    'exclusão recusada com atendimento aberto',
  );
  checks++;

  // Encerrados os atendimentos, os dados pessoais somem.
  await admin();
  await q(
    `update service_requests set workflow_phase='cancelled', status='cancelled'
     where requester_id=$1 and workflow_phase not in ('completed','cancelled')`,
    [id(1)],
  );
  await user(1);
  await q('select request_account_deletion()');
  await admin();
  const removed = (await q('select * from profiles where id=$1', [id(1)]))[0];
  ok(removed.full_name === 'Conta removida', 'nome anonimizado');
  ok(removed.document_last4 === '0000', 'documento anonimizado');
  ok(!removed.document_hash.includes('fixture-1'), 'hash do documento substituído');
  ok(
    (await q('select * from account_deletion_requests where user_id=$1', [id(1)])).length === 1,
    'pedido de exclusão registrado',
  );

  await admin();

  console.log(`PASS security contracts (${checks} checks)`);
};
