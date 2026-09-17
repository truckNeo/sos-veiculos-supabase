// Spatial functions are stubbed: these tests do not validate PostGIS distances or Storage HTTP.
const {PGlite}=require(process.argv[2] || '@electric-sql/pglite');
const fs=require('fs');const path=require('path');
(async()=>{
const db=new PGlite();
await db.exec(`create role anon; create role authenticated; create role service_role bypassrls; alter default privileges in schema public grant select,insert,update,delete on tables to authenticated,service_role; create schema auth; create schema storage; create schema extensions;
create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth to authenticated;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner_id text); alter table storage.objects enable row level security;
create function storage.foldername(text) returns text[] language sql as $$select string_to_array($1,'/')$$;
create publication supabase_realtime;
create domain extensions.geography as text;
create function extensions.st_makepoint(double precision,double precision) returns text language sql immutable as $$select $1::text||','||$2::text$$;
create function extensions.st_setsrid(text,integer) returns text language sql immutable as $$select $1$$;
create function extensions.st_dwithin(text,text,double precision) returns boolean language sql immutable as $$select true$$;
create function extensions.st_distance(text,text) returns double precision language sql immutable as $$select 100::double precision$$;
`);
const root=process.env.SOS_TEST_MIGRATIONS || path.join(__dirname,'../migrations');
for(const name of [...new Set([...fs.readdirSync(root).filter(n=>n.endsWith('.sql')), '20260912100000_product_completion.sql'])].sort()){
 const local=path.join(__dirname,name);let sql=fs.readFileSync(fs.existsSync(local)?local:path.join(root,name),'utf8');
 // PGlite lacks PostGIS/pgcrypto; only spatial functions/indexes are substituted.
 sql=sql.replace(/create extension if not exists (pgcrypto|postgis)[^;]*;/gi,'').replaceAll('extensions.geography(Point, 4326)','extensions.geography').replace(/create index[^;]*using gist[^;]*;/gi,'');
 try {await db.exec(sql);}catch(e){console.error(name,e.message);process.exitCode=1;await db.close();return;}
}
console.log('PASS all migration DDL (spatial functions stubbed)');
if(process.env.SOS_SCHEMA_OUTPUT){const sql=fs.readFileSync(path.join(__dirname,'inspect-favorites.sql'),'utf8');fs.writeFileSync(process.env.SOS_SCHEMA_OUTPUT,JSON.stringify((await db.query(sql)).rows));}
if(process.env.SOS_SCHEMA_COLUMNS){fs.writeFileSync(process.env.SOS_SCHEMA_COLUMNS,JSON.stringify((await db.query(fs.readFileSync(path.join(__dirname,'inspect-remote.sql'),'utf8'))).rows));}
try {await require('./product-contracts.cjs')(db);} finally {await db.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
