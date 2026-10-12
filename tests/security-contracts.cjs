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
  const second = id(301);
  await openRequest(second, 'awaiting_driver_confirmation', 'in_service');
  await user(2);
  await q(
    `insert into reviews(request_id, reviewer_id, driver_id, provider_id, rating) values($1, $2, $3, $4, 4)`,
    [second, id(2), id(1), id(2)],
  );
  await admin();
  ok((await q('select * from reviews where request_id=$1', [second])).length === 1, 'provider review stored');

  // Limite conhecido: UNIQUE(request_id) ainda impede que os dois lados avaliem
  // o mesmo atendimento. O prestador passa pela RLS e esbarra na constraint.
  // Quando provider_id virar nullable e a unique virar (request_id, reviewer_id),
  // este caso passa a ser aceito e a asserção abaixo precisa ser invertida.
  await user(2);
  await assert.rejects(
    q(`insert into reviews(request_id, reviewer_id, driver_id, provider_id, rating) values($1, $2, $3, $4, 4)`, [
      request,
      id(2),
      id(1),
      id(2),
    ]),
    /duplicate key|unique/i,
    'bloqueio atual é da constraint, não da política',
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

  await admin();
  console.log(`PASS security contracts (${checks} checks)`);
};
