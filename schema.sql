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
