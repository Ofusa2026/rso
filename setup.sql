-- 所属機関営業ボード（rso）のテーブル
-- Supabase の SQL Editor に貼り付けて「Run」で実行します

create extension if not exists pgcrypto;

-- 見込み客
create table if not exists public.leads (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  pref        text default '',
  field       text default '',
  source      text default '',
  contact     text default '',
  tel         text default '',
  stage       text not null default '未接触',
  rank        text default 'B',
  staff       text default '',
  people      integer,
  fee         integer,
  next_date   date,
  next_kind   text default '',
  next_note   text default '',
  plan        text default '',
  memo        text default '',
  hearing     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 活動の記録（架電・訪問など。KPIはここから数える）
create table if not exists public.activities (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads(id) on delete cascade,
  date        date not null default current_date,
  kind        text not null,
  result      text not null,
  note        text default '',
  staff       text default '',
  people      integer,
  fee         integer,
  created_at  timestamptz not null default now()
);
create index if not exists activities_lead_idx on public.activities(lead_id);
create index if not exists activities_date_idx on public.activities(date);

-- KPIの目標（key = 'default' または 'YYYY-MM'）
create table if not exists public.kpi_targets (
  key         text primary key,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- ログインした人だけが読み書きできる（ログインしていない人は何も見えない）
alter table public.leads       enable row level security;
alter table public.activities  enable row level security;
alter table public.kpi_targets enable row level security;

drop policy if exists "signed in" on public.leads;
drop policy if exists "signed in" on public.activities;
drop policy if exists "signed in" on public.kpi_targets;
create policy "signed in" on public.leads       for all to authenticated using (true) with check (true);
create policy "signed in" on public.activities  for all to authenticated using (true) with check (true);
create policy "signed in" on public.kpi_targets for all to authenticated using (true) with check (true);

insert into public.kpi_targets (key, data) values
  ('default', '{"calls":300,"contacts":90,"appts":20,"hearings":15,"proposals":8,"wins":3,"people":10}')
on conflict (key) do nothing;
