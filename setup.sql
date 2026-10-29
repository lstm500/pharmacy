-- 薬局比較 v1.0。SQL Editorで一度実行。生データなし。再実行可能。
begin;
-- 薬局比較アプリ専用。既存の他アプリのテーブルには触れません。
create table if not exists public.shinagawa_pharmacies (
 code text primary key,
 name text not null,
 address text not null,
 latitude double precision check (latitude between -90 and 90),
 longitude double precision check (longitude between -180 and 180),
 payload jsonb not null check (jsonb_typeof(payload) = 'object'),
 snapshot_date date not null,
 imported_at timestamptz not null default now()
);
create table if not exists public.shinagawa_fee_registrations (
 pharmacy_code text not null references public.shinagawa_pharmacies(code) on delete cascade,
 fee_name text not null,
 abbreviation text not null default '',
 start_label text not null default '',
 snapshot_date date not null,
 primary key (pharmacy_code, fee_name)
);
create table if not exists public.shinagawa_stations (
 name text primary key,
 latitude double precision not null check (latitude between -90 and 90),
 longitude double precision not null check (longitude between -180 and 180),
 lines jsonb not null check (jsonb_typeof(lines) = 'array'),
 major boolean not null default false,
 source_url text not null,
 retrieved_on date not null
);
create table if not exists public.shinagawa_fee_rates (
 fee_key text primary key,
 category text not null check (category in ('basic','regional','cooperation','digital')),
 points numeric not null check (points >= 0),
 valid_from date not null,
 source_url text not null
);
create table if not exists public.shinagawa_dataset_info (
 id text primary key check (id = 'current'),
 metadata jsonb not null check (jsonb_typeof(metadata) = 'object'),
 imported_at timestamptz not null default now()
);
alter table public.shinagawa_pharmacies enable row level security;
alter table public.shinagawa_fee_registrations enable row level security;
alter table public.shinagawa_stations enable row level security;
alter table public.shinagawa_fee_rates enable row level security;
alter table public.shinagawa_dataset_info enable row level security;
-- 読み書きはStreamlitサーバーと取込処理だけ。ブラウザ用キーには権限を与えません。
revoke all on table public.shinagawa_pharmacies, public.shinagawa_fee_registrations,
 public.shinagawa_stations, public.shinagawa_fee_rates, public.shinagawa_dataset_info from anon, authenticated;
grant select, insert, update, delete on table public.shinagawa_pharmacies,
 public.shinagawa_fee_registrations, public.shinagawa_stations, public.shinagawa_fee_rates,
 public.shinagawa_dataset_info to service_role;

create or replace function public.shinagawa_import_dataset(dataset jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $function$
begin
 if jsonb_typeof(dataset->'pharmacies') is distinct from 'array'
    or jsonb_typeof(dataset->'stations') is distinct from 'array'
    or jsonb_typeof(dataset->'rates') is distinct from 'array'
    or jsonb_typeof(dataset->'metadata') is distinct from 'object'
 then raise exception 'Invalid pharmacy dataset'; end if;
 insert into public.shinagawa_pharmacies(code,name,address,latitude,longitude,payload,snapshot_date)
 select p->>'code',p->>'name',p->>'address',(p->>'lat')::double precision,
   (p->>'lon')::double precision,p,(dataset->'metadata'->>'pharmacies_as_of')::date
 from jsonb_array_elements(dataset->'pharmacies') as entries(p)
 on conflict (code) do update set name=excluded.name,address=excluded.address,
   latitude=excluded.latitude,longitude=excluded.longitude,payload=excluded.payload,
   snapshot_date=excluded.snapshot_date, imported_at=now();
 -- このデータセットに含まれる薬局の届出だけを、同じトランザクション内で置き換えます。
 delete from public.shinagawa_fee_registrations
 where pharmacy_code in (select p->>'code' from jsonb_array_elements(dataset->'pharmacies') as entries(p));
 insert into public.shinagawa_fee_registrations(pharmacy_code,fee_name,abbreviation,start_label,snapshot_date)
 select p->>'code',r->>'name',coalesce(r->>'abbr',''),coalesce(r->>'start',''),
  (dataset->'metadata'->>'pharmacies_as_of')::date
 from jsonb_array_elements(dataset->'pharmacies') as entries(p)
 cross join lateral jsonb_array_elements(p->'registrations') as registrations(r)
 where coalesce(r->>'name','') <> '';
 insert into public.shinagawa_stations(name,latitude,longitude,lines,major,source_url,retrieved_on)
 select s->>'name',(s->>'lat')::double precision,(s->>'lon')::double precision,
  s->'lines',coalesce((s->>'major')::boolean,false),dataset->'metadata'->>'stations_source',
  (dataset->'metadata'->>'retrieved_on')::date
 from jsonb_array_elements(dataset->'stations') as stations(s)
 on conflict (name) do update set latitude=excluded.latitude,longitude=excluded.longitude,
  lines=excluded.lines,major=excluded.major,source_url=excluded.source_url,retrieved_on=excluded.retrieved_on;
 insert into public.shinagawa_fee_rates(fee_key,category,points,valid_from,source_url)
 select r->>'fee_key',r->>'category',(r->>'points')::numeric,
  (r->>'valid_from')::date,r->>'source_url'
 from jsonb_array_elements(dataset->'rates') as rates(r)
 on conflict (fee_key) do update set category=excluded.category,points=excluded.points,
  valid_from=excluded.valid_from,source_url=excluded.source_url;
 insert into public.shinagawa_dataset_info(id,metadata) values ('current',dataset->'metadata')
 on conflict (id) do update set metadata=excluded.metadata,imported_at=now();
 return jsonb_build_object(
  'pharmacies',(select count(*) from public.shinagawa_pharmacies),
  'registrations',(select count(*) from public.shinagawa_fee_registrations),
  'stations',(select count(*) from public.shinagawa_stations),
  'rates',(select count(*) from public.shinagawa_fee_rates));
end;
$function$;
revoke all on function public.shinagawa_import_dataset(jsonb) from public, anon, authenticated;
grant execute on function public.shinagawa_import_dataset(jsonb) to service_role;


-- 過去のデータを削除せず、変更前の内容を履歴へ保存します。
create table if not exists public.pharmacy_history (
 id text primary key,
 pharmacy_code text not null,
 old_record jsonb not null,
 changed_at timestamptz not null default now()
);
create index if not exists pharmacy_history_code_idx on public.pharmacy_history(pharmacy_code,changed_at desc);
create table if not exists public.pharmacy_update_jobs (
 id text primary key check(id='current'),
 status text not null check(status in ('queued','running','paused','failed','partial','completed')),
 state jsonb not null,
 stop_requested boolean not null default false,
 lease_owner text,
 lease_until timestamptz,
 updated_at timestamptz not null default now()
);
create table if not exists public.pharmacy_region_status (
 region text primary key,
 snapshot_date date not null,
 source_hash text not null,
 count integer not null,
 unlocated integer not null,
 station_issue text not null default '',
 checked_at timestamptz not null default now()
);
create table if not exists public.pharmacy_update_events (
 id text primary key,
 run_id text not null,
 stage text not null,
 region text not null default '',
 details jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists pharmacy_events_time_idx on public.pharmacy_update_events(created_at desc);
alter table public.pharmacy_history enable row level security;
alter table public.pharmacy_update_jobs enable row level security;
alter table public.pharmacy_region_status enable row level security;
alter table public.pharmacy_update_events enable row level security;
revoke all on public.pharmacy_history,public.pharmacy_update_jobs,public.pharmacy_region_status,public.pharmacy_update_events from public,anon,authenticated;
grant select,insert,update,delete on public.pharmacy_history,public.pharmacy_update_jobs,public.pharmacy_region_status,public.pharmacy_update_events to service_role;

create or replace function public.pharmacy_job_action(action text, owner text default '', patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare j public.pharmacy_update_jobs%rowtype;
begin
 perform pg_catalog.pg_advisory_xact_lock(734210513);
 select * into j from public.pharmacy_update_jobs where id='current' for update;
 if action='start' then
   if j.lease_until>now() then raise exception 'Collector is already running'; end if;
   if jsonb_typeof(patch->'regions') is distinct from 'array' or jsonb_array_length(patch->'regions')=0 then raise exception 'No regions'; end if;
   insert into public.pharmacy_update_jobs(id,status,state,stop_requested)
   values('current','queued',patch,false)
   on conflict(id) do update set state=excluded.state,status='queued',stop_requested=false,lease_owner=null,lease_until=null,updated_at=now();
 elsif action='stop' then
   update public.pharmacy_update_jobs set stop_requested=true,
     status=case when lease_until>now() then status else 'paused' end,updated_at=now() where id='current';
 elsif action='resume' then
   if j.lease_until>now() then raise exception 'Collector is already running'; end if;
   if j.id is null or j.status='completed' then raise exception 'No resumable job'; end if;
   update public.pharmacy_update_jobs set status='queued',stop_requested=false,lease_owner=null,lease_until=null,
     state=state-'error',updated_at=now() where id='current';
 elsif action='claim' then
   if owner='' or j.id is null or j.stop_requested or j.status not in ('queued','running') or
     (j.lease_until>now() and j.lease_owner is distinct from owner) then return null; end if;
   update public.pharmacy_update_jobs set lease_owner=owner,lease_until=now()+interval '180 seconds',status='running',updated_at=now() where id='current';
 elsif action='heartbeat' then
   if j.lease_owner is distinct from owner or j.lease_until<now() or j.status<>'running' then return null; end if;
   update public.pharmacy_update_jobs set lease_until=now()+interval '180 seconds',updated_at=now() where id='current';
 elsif action='save' then
   if j.lease_owner is distinct from owner or j.lease_until<now() then raise exception 'Collector lease expired'; end if;
   update public.pharmacy_update_jobs set state=patch->'state',status=patch->>'status',updated_at=now(),
     lease_until=case when patch->>'status'='running' then now()+interval '180 seconds' else null end,
     lease_owner=case when patch->>'status'='running' then owner else null end where id='current';
   if patch->>'status'<>'running' then
     insert into public.pharmacy_update_events(id,run_id,stage,details)
     values(gen_random_uuid()::text,coalesce(j.state->>'run_id',''),patch->>'status',patch->'state');
   end if;
 else raise exception 'Unknown action'; end if;
 select * into j from public.pharmacy_update_jobs where id='current';
 return to_jsonb(j);
end;
$fn$;

create or replace function public.pharmacy_commit_batch(owner text,items jsonb,next_state jsonb,source_meta jsonb,
 region_done text default '',source_codes jsonb default '[]'::jsonb,station_items jsonb default '[]'::jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare j public.pharmacy_update_jobs%rowtype; p jsonb; r jsonb; s jsonb; old public.shinagawa_pharmacies%rowtype;
 stats jsonb; nnew integer:=0; nupdated integer:=0; nsame integer:=0; nmissing integer:=0; nmoved integer:=0;
 saved_state jsonb; snapshot date:=(source_meta->>'pharmacies_as_of')::date; v_region text;
begin
 select * into j from public.pharmacy_update_jobs where id='current' for update;
 if j.id is null or j.lease_owner is distinct from owner or j.lease_until<now() or j.status<>'running' then raise exception 'Collector lease expired'; end if;
 if jsonb_typeof(items) is distinct from 'array' or jsonb_typeof(next_state) is distinct from 'object' or snapshot is null then raise exception 'Invalid batch'; end if;
 for p in select value from jsonb_array_elements(items) loop
   if coalesce(p->>'code','')!~'^\d{7}$' or coalesce(p->>'name','')='' or coalesce(p->>'address','')='' or jsonb_typeof(p->'registrations') is distinct from 'array' then raise exception 'Invalid pharmacy'; end if;
   v_region:=p->>'region';
   if not ((j.state->'regions') ? v_region) then raise exception 'Unexpected region'; end if;
   select * into old from public.shinagawa_pharmacies where code=p->>'code' for update;
   if old.code is not null and old.snapshot_date>snapshot then raise exception 'Older source cannot overwrite newer data'; end if;
   if (p->>'lat') is null or (p->>'lon') is null then nmissing:=nmissing+1; end if;
   if old.code is null then nnew:=nnew+1;
   elsif old.payload is distinct from p then
     nupdated:=nupdated+1;
     insert into public.pharmacy_history(id,pharmacy_code,old_record) values(gen_random_uuid()::text,old.code,to_jsonb(old));
   else nsame:=nsame+1; end if;
   insert into public.shinagawa_pharmacies(code,name,address,latitude,longitude,payload,snapshot_date)
   values(p->>'code',p->>'name',p->>'address',(p->>'lat')::double precision,(p->>'lon')::double precision,p,snapshot)
   on conflict(code) do update set name=excluded.name,address=excluded.address,latitude=excluded.latitude,
    longitude=excluded.longitude,payload=excluded.payload,snapshot_date=excluded.snapshot_date,imported_at=now();
   delete from public.shinagawa_fee_registrations where pharmacy_code=p->>'code';
   for r in select value from jsonb_array_elements(p->'registrations') loop
     if coalesce(r->>'name','')<>'' then
       insert into public.shinagawa_fee_registrations(pharmacy_code,fee_name,abbreviation,start_label,snapshot_date)
       values(p->>'code',r->>'name',coalesce(r->>'abbr',''),coalesce(r->>'start',''),snapshot);
     end if;
   end loop;
 end loop;
 for s in select value from jsonb_array_elements(station_items) loop
   insert into public.shinagawa_stations(name,latitude,longitude,lines,major,source_url,retrieved_on)
   values(s->>'name',(s->>'lat')::double precision,(s->>'lon')::double precision,s->'lines',coalesce((s->>'major')::boolean,false),source_meta->>'stations_source',(source_meta->>'retrieved_on')::date)
   on conflict(name) do update set latitude=excluded.latitude,longitude=excluded.longitude,lines=excluded.lines,major=excluded.major,source_url=excluded.source_url,retrieved_on=excluded.retrieved_on;
 end loop;
 if region_done<>'' then
   if exists(select 1 from public.shinagawa_pharmacies x where x.payload->>'region'=region_done and x.snapshot_date>snapshot) then raise exception 'Older regional snapshot'; end if;
   if jsonb_array_length(source_codes)=0 or not ((j.state->'regions') ? region_done) then raise exception 'Invalid completed region'; end if;
   -- 全地域の走査終了時のみ、元資料から消えた店を未確認扱いにする。閉店とは断定しない。
   insert into public.pharmacy_history(id,pharmacy_code,old_record)
   select gen_random_uuid()::text,x.code,to_jsonb(x) from public.shinagawa_pharmacies x
   where coalesce(x.payload->>'region',substring(x.address from '^([^都]+?[区市])'))=region_done
    and not (source_codes ? x.code) and not coalesce((x.payload->>'sourceMissing')::boolean,false);
   update public.shinagawa_pharmacies x set payload=jsonb_set(x.payload,'{sourceMissing}','true'::jsonb)
   where coalesce(x.payload->>'region',substring(x.address from '^([^都]+?[区市])'))=region_done and not (source_codes ? x.code);
   insert into public.pharmacy_region_status(region,snapshot_date,source_hash,count,unlocated,station_issue)
   select region_done,snapshot,source_meta->>'source_hash',jsonb_array_length(source_codes),
     count(*) filter(where x.latitude is null or x.longitude is null),coalesce(source_meta->>'station_issue','')
   from public.shinagawa_pharmacies x where source_codes ? x.code
   on conflict(region) do update set snapshot_date=excluded.snapshot_date,source_hash=excluded.source_hash,count=excluded.count,unlocated=excluded.unlocated,station_issue=excluded.station_issue,checked_at=now();
 end if;
 stats:=coalesce(j.state->'stats','{}'::jsonb);
 stats:=jsonb_build_object('processed',coalesce((stats->>'processed')::integer,0)+jsonb_array_length(items),
 'new',coalesce((stats->>'new')::integer,0)+nnew,'updated',coalesce((stats->>'updated')::integer,0)+nupdated,
 'unchanged',coalesce((stats->>'unchanged')::integer,0)+nsame,'unlocated',coalesce((stats->>'unlocated')::integer,0)+nmissing);
 saved_state:=jsonb_set(next_state,'{stats}',stats);
 update public.pharmacy_update_jobs set state=saved_state,lease_until=now()+interval '180 seconds',updated_at=now() where id='current';
 insert into public.shinagawa_dataset_info(id,metadata) values('current',source_meta)
 on conflict(id) do update set metadata=public.shinagawa_dataset_info.metadata||excluded.metadata,imported_at=now();
 insert into public.pharmacy_update_events(id,run_id,stage,region,details)
 values(gen_random_uuid()::text,coalesce(j.state->>'run_id',''),case when region_done<>'' then 'region_completed' else 'batch_saved' end,
 coalesce(nullif(region_done,''),items->0->>'region',''),jsonb_build_object('new',nnew,'updated',nupdated,'unchanged',nsame,'unlocated',nmissing,'offset',saved_state->'offset'));
 return jsonb_build_object('state',saved_state,'saved',jsonb_array_length(items),'new',nnew,'updated',nupdated,'unchanged',nsame);
end;
$fn$;

create or replace function public.pharmacy_save_rates(items jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare r jsonb; old jsonb;
begin
 if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)=0 then raise exception 'No rates'; end if;
 select jsonb_agg(to_jsonb(x)) into old from public.shinagawa_fee_rates x;
 for r in select value from jsonb_array_elements(items) loop
   if coalesce(r->>'source_url','')!~'^https://' or (r->>'points') is null or (r->>'valid_from') is null then raise exception 'Invalid rate source'; end if;
   insert into public.shinagawa_fee_rates(fee_key,category,points,valid_from,source_url)
   values(r->>'fee_key',r->>'category',(r->>'points')::numeric,(r->>'valid_from')::date,r->>'source_url')
   on conflict(fee_key) do update set category=excluded.category,points=excluded.points,valid_from=excluded.valid_from,source_url=excluded.source_url;
 end loop;
 insert into public.pharmacy_update_events(id,run_id,stage,details)
 values(gen_random_uuid()::text,'manual','rates_updated',jsonb_build_object('previous',old,'current',items));
 return jsonb_build_object('saved',jsonb_array_length(items));
end;
$fn$;
revoke all on function public.pharmacy_job_action(text,text,jsonb) from public,anon,authenticated;
revoke all on function public.pharmacy_commit_batch(text,jsonb,jsonb,jsonb,text,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.pharmacy_save_rates(jsonb) from public,anon,authenticated;
grant execute on function public.pharmacy_job_action(text,text,jsonb) to service_role;
grant execute on function public.pharmacy_commit_batch(text,jsonb,jsonb,jsonb,text,jsonb,jsonb) to service_role;
grant execute on function public.pharmacy_save_rates(jsonb) to service_role;
notify pgrst,'reload schema';
commit;
