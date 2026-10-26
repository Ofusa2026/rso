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


-- ===== 2026/10/26 追加：登録支援機関ごとにデータを分ける（上のテーブルを作ったあとに実行） =====
-- 所属機関営業ボード：登録支援機関ごとにデータを分ける（マイページ対応）
-- Supabase の SQL Editor に貼り付けて「Run」で実行します。何回実行しても壊れません。

-- 1) 登録支援機関と、そこに所属する人
create table if not exists public.orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  profile     jsonb not null default '{}'::jsonb,   -- マイページの基本情報（概要書の項目）
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table if not exists public.members (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  org_id       uuid not null references public.orgs(id) on delete cascade,
  role         text not null default 'member' check (role in ('member','admin','operator')),
  display_name text default '',
  created_at   timestamptz not null default now()
);
create index if not exists members_org_idx on public.members(org_id);

-- ログイン中の人の登録支援機関（RLS から使う。members の RLS を通らないよう security definer）
create or replace function public.my_org_id() returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from public.members where user_id = auth.uid()
$$;
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where user_id = auth.uid()
$$;
revoke all on function public.my_org_id() from public, anon;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_org_id() to authenticated;
grant execute on function public.my_role() to authenticated;

-- 2) 今あるデータ（サンプル）は「サンプル登録支援機関」のものにする。今いるユーザーは運営（operator）
insert into public.orgs (id, name) values ('00000000-0000-4000-8000-000000000001', 'サンプル登録支援機関')
on conflict (id) do nothing;
insert into public.members (user_id, org_id, role)
  select id, '00000000-0000-4000-8000-000000000001', 'operator' from auth.users
on conflict (user_id) do nothing;

-- 3) 各テーブルに登録支援機関の列を足す（新しく入れる行は自動で自分の機関になる）
alter table public.leads      add column if not exists org_id uuid references public.orgs(id) on delete cascade;
alter table public.activities add column if not exists org_id uuid references public.orgs(id) on delete cascade;
alter table public.kpi_targets add column if not exists org_id uuid references public.orgs(id) on delete cascade;
update public.leads      set org_id = '00000000-0000-4000-8000-000000000001' where org_id is null;
update public.activities set org_id = '00000000-0000-4000-8000-000000000001' where org_id is null;
update public.kpi_targets set org_id = '00000000-0000-4000-8000-000000000001' where org_id is null;
alter table public.leads       alter column org_id set default public.my_org_id();
alter table public.activities  alter column org_id set default public.my_org_id();
alter table public.kpi_targets alter column org_id set default public.my_org_id();
alter table public.leads       alter column org_id set not null;
alter table public.activities  alter column org_id set not null;
alter table public.kpi_targets alter column org_id set not null;
create index if not exists leads_org_idx on public.leads(org_id);
create index if not exists activities_org_idx on public.activities(org_id);

-- KPIの目標は「機関 × 月」で1行
alter table public.kpi_targets drop constraint if exists kpi_targets_pkey;
alter table public.kpi_targets add constraint kpi_targets_pkey primary key (org_id, key);

-- 4) 見られる範囲：自分の登録支援機関のデータだけ（運営も他の機関の中身は見えない）
alter table public.orgs    enable row level security;
alter table public.members enable row level security;

drop policy if exists "signed in" on public.leads;
drop policy if exists "signed in" on public.activities;
drop policy if exists "signed in" on public.kpi_targets;
drop policy if exists "own org" on public.leads;
drop policy if exists "own org" on public.activities;
drop policy if exists "own org" on public.kpi_targets;
create policy "own org" on public.leads       for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());
create policy "own org" on public.activities  for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());
create policy "own org" on public.kpi_targets for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

drop policy if exists "read own org" on public.orgs;
drop policy if exists "admin edits own org" on public.orgs;
create policy "read own org" on public.orgs for select to authenticated using (id = public.my_org_id());
create policy "admin edits own org" on public.orgs for update to authenticated
  using (id = public.my_org_id() and public.my_role() in ('admin','operator'))
  with check (id = public.my_org_id() and public.my_role() in ('admin','operator'));

drop policy if exists "read own org members" on public.members;
create policy "read own org members" on public.members for select to authenticated using (org_id = public.my_org_id());
-- 機関とユーザーを作るのは Edge Function「org-admin」だけ（サービス権限で実行。画面から直接は作れない）
