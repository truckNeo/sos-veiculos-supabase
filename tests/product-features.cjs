/* Isolated PostgreSQL contract tests. Uses PGlite; never connects to remote data.
 * Usage: node tests/product-features.cjs [absolute path to @electric-sql/pglite]
 * The minimal fixture models existing platform tables; full migration-history
 * testing against Supabase local remains a separate release check.
 */
const {PGlite} = require(process.argv[2] || '@electric-sql/pglite');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const db = new PGlite();
  const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  await db.exec(`
    create role authenticated; create role service_role bypassrls;
    create schema auth;
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    grant usage on schema auth to authenticated;
    create table public.profiles(id uuid primary key, role text);
    create table auth.users(id uuid primary key, email text, email_confirmed_at timestamptz);
    create table public.organizations(id uuid primary key, owner_id uuid);
    create table public.vehicles(id uuid primary key, owner_profile_id uuid, organization_id uuid, plate text, model text, year integer);
    create table public.provider_profiles(provider_id uuid primary key, is_available boolean);
    create function public.can_manage_vehicle(target uuid) returns boolean language sql stable security definer set search_path=public as $$
      select exists(select 1 from vehicles where id=target and owner_profile_id=auth.uid()) $$;
    alter table public.vehicles enable row level security;
    grant select on public.vehicles to authenticated;
    create policy owner_vehicle on public.vehicles for select to authenticated using(owner_profile_id=auth.uid());
    insert into profiles values ('${id(1)}','driver'),('${id(2)}','provider'),('${id(3)}','driver');
    insert into auth.users values ('${id(1)}','owner@example.com',now()),('${id(2)}','provider@example.com',now()),('${id(3)}','collaborator@example.com',now());
    insert into provider_profiles values ('${id(2)}',true);
    insert into vehicles values ('${id(4)}','${id(1)}',null,'ABC1D23','Scania',2022);
  `);
  for (const file of ['20260906010000_mvp_product_features.sql', '20260906011000_product_notification_delivery.sql']) {
    await db.exec(readFileSync(join(__dirname, '../migrations', file), 'utf8'));
  }
  const asUser = async n => db.exec(`reset role; set role authenticated; select set_config('request.jwt.claim.sub','${id(n)}',false);`);
  const query = async (sql, params = []) => (await db.query(sql, params)).rows;
  await asUser(1);
  const [{id: plan}] = await query(`insert into vehicle_maintenance_plans(vehicle_id,title,due_date,interval_days) values($1,'Revisão de freios',current_date,180) returning id`, [id(4)]);
  const [{due_date: due}] = await query('select due_date::text from vehicle_maintenance_plans where id=$1', [plan]);
  await query('select complete_vehicle_maintenance($1,$2,null)', [plan, due]);
  await assert.rejects(query('select complete_vehicle_maintenance($1,$2,null)', [plan, due]), /já atualizado/);
  const args = [id(4), id(2), new Date(Date.now()+86400000).toISOString(), 60, 'Revisão programada'];
  const [{id: appointment}] = await query('select create_service_appointment($1,$2,$3,$4,$5) as id', args);
  await assert.rejects(query('select create_service_appointment($1,$2,$3,$4,$5)', args), /Horário indisponível/);
  await assert.rejects(query("select respond_service_appointment($1,'confirmed')", [appointment]), /Somente o prestador/);
  const [{id: invite}] = await query('select create_vehicle_share_invite($1,$2) as id', [id(4), 'collaborator@example.com']);
  await asUser(2);
  await query("select respond_service_appointment($1,'confirmed')", [appointment]);
  await query("select respond_service_appointment($1,'confirmed')", [appointment]);
  await assert.rejects(query('select respond_vehicle_share_invite($1,true)', [invite]), /indisponível/);
  await asUser(3);
  assert.equal((await query('select * from service_appointments')).length, 0);
  assert.equal((await query('select * from vehicle_maintenance_plans')).length, 0);
  await assert.rejects(query('select create_service_appointment($1,$2,$3,$4,$5)', args), /sem permissão/);
  await query('select respond_vehicle_share_invite($1,true)', [invite]);
  assert.equal((await query('select * from list_shared_vehicles()')).length, 1);
  assert.equal((await query('select * from list_shared_vehicle_maintenance($1)', [id(4)])).length, 1);
  assert.equal((await query('select * from vehicles')).length, 0, 'Share must not expand existing vehicle RLS');
  await assert.rejects(query('select complete_vehicle_maintenance($1,$2,null)', [plan, due]), /sem permissão/);
  await assert.rejects(query('select revoke_vehicle_share_invite($1)', [invite]), /indisponível/);
  await asUser(1);
  await query('select revoke_vehicle_share_invite($1)', [invite]);
  await asUser(3);
  assert.equal((await query('select * from list_shared_vehicles()')).length, 0);
  assert.equal((await query('select * from list_shared_vehicle_maintenance($1)', [id(4)])).length, 0);
  await assert.rejects(query('select enqueue_product_reminders()'), /permission denied/);
  await db.exec('reset role');
  await query('select enqueue_product_reminders()');
  const before = (await query('select count(*)::integer as n from product_notifications'))[0].n;
  await query('select enqueue_product_reminders()');
  assert.equal((await query('select count(*)::integer as n from product_notifications'))[0].n, before);
  assert.ok((await query('select * from claim_product_notifications()')).length > 0);
  assert.equal((await query('select * from claim_product_notifications()')).length, 0);
  await db.close();
  console.log('PASS: migrations, maintenance, appointment conflicts/permissions, sharing/RLS/revocation, reminder dedupe and delivery leases.');
})().catch(error => {console.error(error); process.exitCode = 1;});
