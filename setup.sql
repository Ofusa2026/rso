-- RSO（登録支援機関システム）（rso）のテーブル
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
-- RSO（登録支援機関システム）：登録支援機関ごとにデータを分ける（マイページ対応）
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


-- ===== 2026/11/04 追加：KMT管理システムから移植（所属機関・外国人材・支援スケジュール・社内チャット・求人チャット・求人管理・候補者管理） =====

create table if not exists public.companies (
  id uuid default gen_random_uuid() primary key,
  name text,
  name_kana text,
  name_en text,
  corp_no text,
  corp_type text,
  emp_ins_no text,
  labor_ins_no text,
  zip text,
  pref text,
  city text,
  address text,
  address_en text,
  detail_address text,
  address_code text,
  tel text,
  rep_name text,
  rep_title text,
  rep_name_en text,
  rep_title_en text,
  author_name text,
  author_title text,
  author_name_en text,
  capital text,
  sales text,
  employees text,
  foreign_employees text,
  tech_trainees text,
  jp_salary text,
  sales_y1 text,
  sales_y2 text,
  sales_y3 text,
  ordinary_pl_y1 text,
  ordinary_pl_y2 text,
  ordinary_pl_y3 text,
  net_pl_y1 text,
  net_pl_y2 text,
  net_pl_y3 text,
  net_assets_y1 text,
  net_assets_y2 text,
  net_assets_y3 text,
  industry text,
  industry_code text,
  company_category text,
  category_code text,
  occupation_code text,
  support_org_name text,
  support_org_address text,
  support_org_no text,
  support_manager_name text,
  support_manager_title text,
  support_manager_name_en text,
  support_manager_title_en text,
  support_staff text,
  ofusa_staff text,
  emp_sets jsonb default '[]'::jsonb,
  officers jsonb default '[]'::jsonb,
  jp_voluntary_quit text,
  jp_involuntary_quit text,
  fn_voluntary_quit text,
  fn_involuntary_quit text,
  jp_comp_job_desc text,
  jp_comp_age text,
  jp_comp_gender text,
  jp_comp_exp text,
  jp_comp_salary text,
  jp_comp_reason text,
  wage_regulation text,
  has_job_placement text,
  jj_name text,
  jj_corp_no_type text,
  jj_corp_no text,
  jj_emp_ins_no text,
  jj_zip text,
  jj_pref text,
  jj_city text,
  jj_address_detail text,
  jj_tel text,
  jj_permit_no text,
  jj_permit_date text,
  drive_url text,
  drive_url2 text,
  spreadsheet_url text,
  folder_no text,
  memo text,
  shortage_memo text,
  company_note text,
  last_visit date,
  extra jsonb default '{}'::jsonb,
  kmt_corp_type text,
  main_staff text,
  sub_staff text,
  fee_per_person integer,
  billing_cycle text,
  payment_method text,
  invoice_method text,
  invoice_to text,
  direct_debit_applied date,
  direct_debit_registered date,
  status text default 'active'::text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  billing_start_month text,
  workplace_name text,
  workplace_zip text,
  workplace_pref text,
  workplace_city text,
  workplace_address text,
  workplace_tel text,
  contact_name text,
  contact_tel text,
  contact_email text,
  billing_timing text,
  company_notes jsonb default '[]'::jsonb,
  workplaces_extra jsonb default '[]'::jsonb,
  other_foreign_employment text,
  other_foreign_employment_types jsonb default '[]'::jsonb,
  other_support_org_used text,
  other_support_org_detail text,
  insurance_guidance_date date,
  insurance_guidance_staff text,
  insurance_name text,
  insurance_start_date date,
  insurance_end_date date,
  insurance_procedure_by text,
  insurance_premium_by text,
  insurance_note text,
  team_staff text,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  next_main_staff text,
  contact_persons jsonb,
  contact_note text,
  industries jsonb,
  industry_note text,
  updated_by text,
  supervisor_name text,
  supervisor_title text,
  supervisor_dept text,
  needs_poa boolean default false,
  poa_done_at date,
  poa_note text,
  visa_fee_pattern text,
  visa_fee_note text,
  staff_handovers jsonb,
  tax_included boolean default false,
  initial_fee integer,
  initial_fee_log jsonb,
  contract_status jsonb,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists companies_org_idx on public.companies(org_id);
alter table public.companies enable row level security;
drop policy if exists "own org" on public.companies;
create policy "own org" on public.companies for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.workers (
  id uuid default gen_random_uuid() primary key,
  company_id uuid,
  sending_org_id uuid,
  candidate_id uuid,
  name text,
  name_kana text,
  nationality text,
  gender text,
  birthdate date,
  residence_card text,
  passport text,
  passport_expiry date,
  visa_status text,
  visa_expiry date,
  entry_date date,
  joined_date date,
  left_date date,
  contract_start date,
  contract_end date,
  applicant_field text,
  job_category text,
  salary text,
  status text default '在職中'::text,
  kmt_support text,
  staff text,
  return_home_date date,
  return_jp_date date,
  tg2_expiry date,
  tg2_status text,
  phone text,
  cel_phone text,
  email text,
  line_group_id text,
  jp_address text,
  memo text,
  extra jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  drive_url text,
  workplace_name text,
  notes text,
  apply_date date,
  apply_number text,
  request_date date,
  drive_url_kmt text,
  apply_status text,
  photo_url text,
  tokurei_date date,
  management_no text,
  five_year_expiry date,
  workplace_address text,
  apply_type text,
  desired_visa text,
  billing_start_month text,
  emergency_contact_name text,
  emergency_contact_relation text,
  emergency_contact_phone text,
  emergency_contact_whatsapp text,
  emergency_contact_address text,
  emergency_contact_sns text,
  emergency_contact_raw text,
  worker_whatsapp text,
  worker_fb text,
  worker_instagram text,
  worker_sns_other text,
  support_type_2go text,
  missing_documents text,
  residence_card_history text,
  first_tokutei_date date,
  placement_report_date date,
  retire_report_date date,
  tg2_change_report_date date,
  latest_contract_url text,
  renewal_status text,
  renewal_stage text,
  renewal_memo text,
  employment_condition text,
  lump_sum_plan text,
  transfer_out_date date,
  transfer_out_done boolean default false,
  transfer_in_date date,
  transfer_in_done boolean default false,
  renewal_check_staff text,
  expected_leave_date date,
  sub_staff text,
  residence_card_issued boolean default false,
  card_tracking_no text,
  card_mailing_address text,
  renewal_completion_chat_posted boolean default false,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  last_year_address text,
  work_start_date date,
  apply_memo text,
  shinsa_completion_chat_posted boolean default false,
  card_info_done boolean default false,
  jp_address_done boolean default false,
  updated_by text,
  apply_status_changed_at timestamptz,
  tokutei_history jsonb,
  contact_log jsonb,
  past_employment jsonb default '[]'::jsonb,
  history_verified boolean default false,
  history_verified_at timestamptz,
  history_verified_by text,
  apply_status_reset_at timestamptz,
  apply_status_reset_from text,
  apply_status_reset_expiry date,
  support_org_change_date date,
  pre_guidance_date date,
  pre_guidance_staff text,
  orientation_date date,
  orientation_staff text,
  entry_pickup_staff text,
  entry_domestic_change boolean default false,
  departure_date date,
  departure_staff text,
  jp_addresses jsonb default '[]'::jsonb,
  history_unknown boolean default false,
  history_unknown_at timestamptz,
  history_unknown_by text,
  tokutei_six_year boolean default false,
  tokutei2_history jsonb,
  shitei_verified boolean default false,
  shitei_verified_at timestamptz,
  shitei_verified_by text,
  contract_status jsonb,
  periodic_report text,
  pending_apply jsonb,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists workers_org_idx on public.workers(org_id);
alter table public.workers enable row level security;
drop policy if exists "own org" on public.workers;
create policy "own org" on public.workers for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.company_meetings (
  id uuid default gen_random_uuid() primary key,
  company_id uuid,
  meeting_date date,
  quarter text,
  contact_name text,
  memo text,
  created_by text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  fiscal_year integer default (extract(year from now()))::int,
  worker_ids jsonb default '[]'::jsonb,
  updated_by text,
  result_memo text,
  staff_name text,
  kind text default '定期面談'::text,
  kind_other text,
  event_method text,
  schedule_id uuid,
  worker_status text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists company_meetings_org_idx on public.company_meetings(org_id);
alter table public.company_meetings enable row level security;
drop policy if exists "own org" on public.company_meetings;
create policy "own org" on public.company_meetings for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.support_schedules (
  id uuid default gen_random_uuid() primary key,
  worker_id uuid,
  company_id uuid,
  event_type text,
  event_method text,
  status text default 'planned'::text,
  scheduled_at date,
  completed_at date,
  notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  updated_by text,
  all_day boolean default true,
  start_time time,
  end_time time,
  staff_names jsonb default '[]'::jsonb,
  other_label text,
  plan_ym text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists support_schedules_org_idx on public.support_schedules(org_id);
alter table public.support_schedules enable row level security;
drop policy if exists "own org" on public.support_schedules;
create policy "own org" on public.support_schedules for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.job_progress (
  id bigint generated by default as identity primary key,
  src_row bigint generated by default as identity unique,
  progress text,
  org_code text,
  kmt_flag boolean,
  sales_staff text,
  glt_staff text,
  code text,
  company_name text,
  folder_no text,
  domestic text,
  job_type text,
  industry text,
  recruit_start date,
  priority boolean,
  candidate_status text,
  unit_price numeric,
  expected_count numeric,
  amount numeric,
  comment text,
  nationalities jsonb,
  imported_at timestamptz default now(),
  company_id uuid,
  contact_phone text,
  reception_date date,
  valid_until date,
  employment_period_type text,
  employment_period_detail text,
  location text,
  jp_level_req text,
  required_license text,
  salary_type text,
  salary_amount numeric,
  dormitory_available text,
  annual_holiday_days integer,
  referral_fee numeric,
  obo_staff text,
  stock_url text,
  progress_note text,
  jinzai_comment text,
  job_description text,
  updated_at timestamptz,
  updated_by text,
  company_kind text,
  priority_level text default '普通'::text,
  forecast_status text,
  faq_answers jsonb default '{}'::jsonb,
  faq_custom jsonb default '[]'::jsonb,
  progress_changed_at timestamptz,
  company_address text,
  source text,
  line_group_name text,
  line_requested_at timestamptz,
  hearing_note text,
  hearing_by text,
  hearing_at timestamptz,
  contact_name text,
  expected_start text,
  business_content text,
  employee_count text,
  foreign_employee_count text,
  employee_nationality text,
  established text,
  capital text,
  appeal text,
  recruit_reason text,
  trial_period text,
  trial_period_detail text,
  start_time text,
  end_time text,
  work_hours text,
  break_minutes text,
  overtime text,
  overtime_detail text,
  flex_work text,
  flex_work_detail text,
  take_home text,
  allowance1_name text,
  allowance1_amount text,
  allowance1_cond text,
  allowance2_name text,
  allowance2_amount text,
  allowance2_cond text,
  bonus text,
  bonus_detail text,
  meal_cost text,
  housing_cost text,
  utility_cost text,
  other_deduction1 text,
  other_deduction2 text,
  room_capacity text,
  room_layout text,
  furniture text,
  dorm_distance text,
  wifi text,
  dorm_area text,
  gender_req text,
  age_limit text,
  experience_req text,
  ideal_candidate text,
  subsidy text,
  subsidy_detail text,
  interview_schedule text,
  interview_method text,
  interview_tool text,
  interview_count text,
  kmt_interview text,
  smoking_policy text,
  sheet_meta jsonb default '{}'::jsonb,
  photos jsonb default '[]'::jsonb,
  order_memo text,
  client_contact_name text,
  drive_url_kmt text,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  line_group_done jsonb,
  sheet_kind text,
  sheet_ext jsonb,
  prospect_count integer,
  candidate_status_rows jsonb,
  hp_title text,
  nearest_station text,
  holiday_text text,
  salary_max numeric,
  hp_features text,
  case_kind text,
  hp_status text,
  hp_status_by text,
  hp_status_at timestamptz,
  hp_wp_post_id bigint,
  hp_synced_at timestamptz,
  hp_sync_note text,
  salary_monthly text,
  hp_photos jsonb,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists job_progress_org_idx on public.job_progress(org_id);
alter table public.job_progress enable row level security;
drop policy if exists "own org" on public.job_progress;
create policy "own org" on public.job_progress for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.candidates (
  id uuid default gen_random_uuid() primary key,
  sending_org_id uuid,
  name text,
  name_kana text,
  nationality text,
  nationality_code text,
  gender text,
  birthdate date,
  birth_place text,
  age text,
  passport text,
  passport_expiry date,
  home_country_address text,
  phone text,
  cel_phone text,
  email text,
  edu_country text,
  education text,
  school_name text,
  completion_date date,
  major text,
  major_detail text,
  experience text,
  occupation text,
  skill_eval_type text,
  skill_exam_1 text,
  skill_exam_loc_1 text,
  skill_exam_code_1 text,
  skill_exam_loc_code_1 text,
  skill_exam_2 text,
  skill_exam_loc_2 text,
  skill_exam_3 text,
  skill_exam_loc_3 text,
  jp_eval_type text,
  jp_exam_1 text,
  jp_exam_loc_1 text,
  jp_exam_code_1 text,
  jp_exam_loc_code_1 text,
  jp_exam_2 text,
  jp_exam_loc_2 text,
  jp_exam_3 text,
  jp_exam_loc_3 text,
  past_entry text,
  past_entry_count text,
  past_entry_from text,
  past_entry_to text,
  past_coe text,
  past_coe_count text,
  past_coe_denied text,
  deportation text,
  deportation_count text,
  deportation_date date,
  first_entry text,
  applicant_field text,
  applicant_field_en text,
  job_category text,
  job_category_en text,
  status text default '選考中'::text,
  staff text,
  memo text,
  extra jsonb default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  name_native text,
  height_cm integer,
  weight_kg integer,
  shoe_size text,
  marital_status text,
  num_children integer,
  religion text,
  family_consent text,
  current_visa_status text,
  current_visa_expiry date,
  residence_card text,
  jp_address text,
  work_history jsonb default '[]'::jsonb,
  resignation_note text,
  jp_language_level text,
  jp_language_detail text,
  hyoka_chosho text,
  licenses jsonb default '{}'::jsonb,
  available_from date,
  completion_date_expected date,
  current_salary text,
  net_salary_base text,
  net_salary_overtime text,
  desired_salary text,
  overtime_preference text,
  temp_return_wish text,
  interview_availability text,
  motivation text,
  health_status text,
  candidate_questions text,
  terms_agreed boolean,
  staff_impression text,
  interview_memo text,
  photo_url text,
  residence_card_front_url text,
  residence_card_back_url text,
  resume_url text,
  reception_date date,
  valid_until date,
  domestic_overseas text,
  jp_eval_grade text,
  jp_eval_note text,
  desired_area text,
  desired_other text,
  company_interview_date date,
  company_interview_result text,
  updated_by text,
  resume_opts jsonb,
  resume_docs jsonb,
  interview1 jsonb,
  drive_url_kmt text,
  overseas_country text,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  dr_done jsonb,
  education_level text,
  education_status text,
  education_note text,
  night_shift_count text,
  health_note text,
  skill_exam_item text,
  cur_net_salary_base text,
  cur_net_salary_overtime text,
  lifestyle text,
  temp_return_timing text,
  temp_return_period text,
  family_consent_due text,
  ssw_remaining text,
  chronic_disease text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists candidates_org_idx on public.candidates(org_id);
alter table public.candidates enable row level security;
drop policy if exists "own org" on public.candidates;
create policy "own org" on public.candidates for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.candidate_job_progress (
  id uuid default gen_random_uuid() primary key,
  candidate_id uuid,
  job_src_row integer,
  status text default '提案中'::text,
  proposal_date date,
  note text,
  created_at timestamptz default now(),
  created_by text,
  updated_at timestamptz default now(),
  updated_by text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists candidate_job_progress_org_idx on public.candidate_job_progress(org_id);
alter table public.candidate_job_progress enable row level security;
drop policy if exists "own org" on public.candidate_job_progress;
create policy "own org" on public.candidate_job_progress for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.job_sheet_links (
  id uuid default gen_random_uuid() primary key,
  token text,
  job_src_row integer,
  created_at timestamptz default now(),
  created_by text,
  sent_to text,
  status text default 'open'::text,
  draft jsonb default '{}'::jsonb,
  draft_at timestamptz,
  answers jsonb,
  answered_at timestamptz,
  answered_by text,
  seen_at timestamptz,
  photos jsonb default '[]'::jsonb,
  by_kind text,
  by_other text,
  org_no integer,
  org_name text,
  kind text default 'job'::text,
  label text,
  sheet_kind text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists job_sheet_links_org_idx on public.job_sheet_links(org_id);
alter table public.job_sheet_links enable row level security;
drop policy if exists "own org" on public.job_sheet_links;
create policy "own org" on public.job_sheet_links for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.candidate_form_links (
  id uuid default gen_random_uuid() primary key,
  token text,
  candidate_id uuid,
  kind text default 'info'::text,
  created_at timestamptz default now(),
  created_by text,
  sent_to text,
  status text default 'open'::text,
  draft jsonb,
  draft_at timestamptz,
  answers jsonb,
  answered_at timestamptz,
  answered_by text,
  seen_at timestamptz,
  max_page integer,
  label text,
  job_src_row integer,
  is_test boolean default false,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists candidate_form_links_org_idx on public.candidate_form_links(org_id);
alter table public.candidate_form_links enable row level security;
drop policy if exists "own org" on public.candidate_form_links;
create policy "own org" on public.candidate_form_links for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.team_chat_rooms (
  id uuid default gen_random_uuid() primary key,
  name text,
  icon_emoji text,
  icon_url text,
  kind text default 'group'::text,
  is_public boolean default true,
  dm_key text,
  topic text,
  created_by text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  updated_by text,
  last_message_at timestamptz,
  last_message_text text,
  last_message_by text,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  drive_url text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists team_chat_rooms_org_idx on public.team_chat_rooms(org_id);
alter table public.team_chat_rooms enable row level security;
drop policy if exists "own org" on public.team_chat_rooms;
create policy "own org" on public.team_chat_rooms for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.team_chat_members (
  id uuid default gen_random_uuid() primary key,
  room_id uuid,
  user_id uuid,
  user_name text,
  role text default 'member'::text,
  joined_at timestamptz default now(),
  last_read_at timestamptz,
  muted boolean default false,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists team_chat_members_org_idx on public.team_chat_members(org_id);
alter table public.team_chat_members enable row level security;
drop policy if exists "own org" on public.team_chat_members;
create policy "own org" on public.team_chat_members for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.team_chat_messages (
  id uuid default gen_random_uuid() primary key,
  room_id uuid,
  sender_id uuid,
  sender_name text,
  content text,
  attachments jsonb default '[]'::jsonb,
  mentions jsonb default '[]'::jsonb,
  reply_to jsonb,
  created_at timestamptz default now(),
  edited_at timestamptz,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  is_auto boolean default false,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists team_chat_messages_org_idx on public.team_chat_messages(org_id);
alter table public.team_chat_messages enable row level security;
drop policy if exists "own org" on public.team_chat_messages;
create policy "own org" on public.team_chat_messages for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.team_chat_reactions (
  id uuid default gen_random_uuid() primary key,
  room_id uuid,
  message_id uuid,
  user_id uuid,
  user_name text,
  emoji text,
  created_at timestamptz default now(),
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists team_chat_reactions_org_idx on public.team_chat_reactions(org_id);
alter table public.team_chat_reactions enable row level security;
drop policy if exists "own org" on public.team_chat_reactions;
create policy "own org" on public.team_chat_reactions for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.chat_rooms (
  id uuid default gen_random_uuid() primary key,
  worker_id uuid,
  created_by text,
  created_at timestamptz default now(),
  status text default 'active'::text,
  completed_at timestamptz,
  updated_at timestamptz default now(),
  group_id uuid,
  company_id uuid,
  is_deleted boolean default false,
  deleted_at timestamptz,
  deleted_by text,
  job_src_row integer,
  candidate_id uuid,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists chat_rooms_org_idx on public.chat_rooms(org_id);
alter table public.chat_rooms enable row level security;
drop policy if exists "own org" on public.chat_rooms;
create policy "own org" on public.chat_rooms for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.chat_messages (
  id uuid default gen_random_uuid() primary key,
  room_id uuid,
  room_type text default 'job'::text,
  sender_id uuid,
  sender_name text,
  content text,
  file_url text,
  file_name text,
  file_type text,
  created_at timestamptz default now(),
  chat_room_id uuid,
  mentions jsonb,
  reply_to jsonb,
  thread_root_id uuid,
  edited_at timestamptz,
  deleted_at timestamptz,
  attachments jsonb,
  is_deleted boolean default false,
  deleted_by text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists chat_messages_org_idx on public.chat_messages(org_id);
alter table public.chat_messages enable row level security;
drop policy if exists "own org" on public.chat_messages;
create policy "own org" on public.chat_messages for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

create table if not exists public.chat_read_at (
  user_id uuid,
  room_id uuid,
  read_at timestamptz default now(),
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade,
  primary key (user_id, room_id)
);
create index if not exists chat_read_at_org_idx on public.chat_read_at(org_id);
alter table public.chat_read_at enable row level security;
drop policy if exists "own org" on public.chat_read_at;
create policy "own org" on public.chat_read_at for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

alter table public.workers drop constraint if exists workers_company_id_fkey;
alter table public.workers add constraint workers_company_id_fkey foreign key (company_id) references public.companies(id) on delete set null;
alter table public.workers drop constraint if exists workers_candidate_id_fkey;
alter table public.workers add constraint workers_candidate_id_fkey foreign key (candidate_id) references public.candidates(id) on delete set null;
alter table public.company_meetings drop constraint if exists company_meetings_company_id_fkey;
alter table public.company_meetings add constraint company_meetings_company_id_fkey foreign key (company_id) references public.companies(id) on delete set null;
alter table public.support_schedules drop constraint if exists support_schedules_worker_id_fkey;
alter table public.support_schedules add constraint support_schedules_worker_id_fkey foreign key (worker_id) references public.workers(id) on delete set null;
alter table public.support_schedules drop constraint if exists support_schedules_company_id_fkey;
alter table public.support_schedules add constraint support_schedules_company_id_fkey foreign key (company_id) references public.companies(id) on delete set null;
alter table public.job_progress drop constraint if exists job_progress_company_id_fkey;
alter table public.job_progress add constraint job_progress_company_id_fkey foreign key (company_id) references public.companies(id) on delete set null;
alter table public.candidate_job_progress drop constraint if exists candidate_job_progress_candidate_id_fkey;
alter table public.candidate_job_progress add constraint candidate_job_progress_candidate_id_fkey foreign key (candidate_id) references public.candidates(id) on delete set null;
alter table public.team_chat_members drop constraint if exists team_chat_members_room_id_fkey;
alter table public.team_chat_members add constraint team_chat_members_room_id_fkey foreign key (room_id) references public.team_chat_rooms(id) on delete cascade;
alter table public.team_chat_messages drop constraint if exists team_chat_messages_room_id_fkey;
alter table public.team_chat_messages add constraint team_chat_messages_room_id_fkey foreign key (room_id) references public.team_chat_rooms(id) on delete cascade;
alter table public.team_chat_reactions drop constraint if exists team_chat_reactions_room_id_fkey;
alter table public.team_chat_reactions add constraint team_chat_reactions_room_id_fkey foreign key (room_id) references public.team_chat_rooms(id) on delete cascade;
alter table public.team_chat_reactions drop constraint if exists team_chat_reactions_message_id_fkey;
alter table public.team_chat_reactions add constraint team_chat_reactions_message_id_fkey foreign key (message_id) references public.team_chat_messages(id) on delete cascade;
alter table public.chat_rooms drop constraint if exists chat_rooms_worker_id_fkey;
alter table public.chat_rooms add constraint chat_rooms_worker_id_fkey foreign key (worker_id) references public.workers(id) on delete set null;
alter table public.chat_rooms drop constraint if exists chat_rooms_company_id_fkey;
alter table public.chat_rooms add constraint chat_rooms_company_id_fkey foreign key (company_id) references public.companies(id) on delete set null;
alter table public.chat_rooms drop constraint if exists chat_rooms_candidate_id_fkey;
alter table public.chat_rooms add constraint chat_rooms_candidate_id_fkey foreign key (candidate_id) references public.candidates(id) on delete set null;
alter table public.chat_messages drop constraint if exists chat_messages_chat_room_id_fkey;
alter table public.chat_messages add constraint chat_messages_chat_room_id_fkey foreign key (chat_room_id) references public.chat_rooms(id) on delete cascade;

-- 変更履歴・業種の選択肢・チャットのピン・社内チャットの編集履歴
create table if not exists public.company_change_log (
  id uuid default gen_random_uuid() primary key,
  company_id uuid references public.companies(id) on delete cascade,
  changed_by text, changed_at timestamptz default now(),
  field_name text, field_label text, old_value text, new_value text,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create table if not exists public.industry_options (
  id uuid default gen_random_uuid() primary key,
  name text not null, sort_order integer default 0, created_by text, created_at timestamptz default now(),
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade,
  unique (org_id, name)
);
create table if not exists public.chat_pins (
  id uuid default gen_random_uuid() primary key,
  user_id uuid, room_id uuid references public.chat_rooms(id) on delete cascade, company_id uuid, pinned_at timestamptz default now(),
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create table if not exists public.team_chat_message_edits (
  id uuid default gen_random_uuid() primary key,
  message_id uuid references public.team_chat_messages(id) on delete cascade, room_id uuid,
  before_content text, after_content text, sender_name text, edited_at timestamptz default now(), edited_by text, edited_by_id uuid,
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
do $$
declare t text;
begin
  foreach t in array array['company_change_log','industry_options','chat_pins','team_chat_message_edits'] loop
    execute format('create index if not exists %I on public.%I(org_id)', t||'_org_idx', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own org" on public.%I', t);
    execute format('create policy "own org" on public.%I for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id())', t);
  end loop;
end $$;
-- 求人チャットのリアクション・添付ファイルの置き場所・チャットの即時反映
create table if not exists public.chat_reactions (
  id uuid default gen_random_uuid() primary key,
  room_id uuid references public.chat_rooms(id) on delete cascade,
  message_id uuid references public.chat_messages(id) on delete cascade,
  user_id uuid, user_name text, emoji text, created_at timestamptz default now(),
  org_id uuid not null default public.my_org_id() references public.orgs(id) on delete cascade
);
create index if not exists chat_reactions_org_idx on public.chat_reactions(org_id);
alter table public.chat_reactions enable row level security;
drop policy if exists "own org" on public.chat_reactions;
create policy "own org" on public.chat_reactions for all to authenticated using (org_id = public.my_org_id()) with check (org_id = public.my_org_id());

-- 添付ファイル：非公開の置き場所。先頭のフォルダ名が自分の登録支援機関のIDのものだけ読み書きできる
insert into storage.buckets (id, name, public, file_size_limit) values ('rso-files', 'rso-files', false, 20971520)
on conflict (id) do nothing;
drop policy if exists "rso own org read" on storage.objects;
drop policy if exists "rso own org write" on storage.objects;
drop policy if exists "rso own org delete" on storage.objects;
create policy "rso own org read" on storage.objects for select to authenticated
  using (bucket_id = 'rso-files' and (storage.foldername(name))[1] = public.my_org_id()::text);
create policy "rso own org write" on storage.objects for insert to authenticated
  with check (bucket_id = 'rso-files' and (storage.foldername(name))[1] = public.my_org_id()::text);
create policy "rso own org delete" on storage.objects for delete to authenticated
  using (bucket_id = 'rso-files' and (storage.foldername(name))[1] = public.my_org_id()::text);

-- チャットの新着を画面にすぐ出す（見える範囲は上のRLSのまま）
do $$ begin
  begin alter publication supabase_realtime add table public.chat_messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.team_chat_messages; exception when duplicate_object then null; end;
end $$;

-- ===== 2026/11/04 監査帳簿：記録欄の追加 =====
-- 支援スケジュール：帳簿④（支援実施状況）に必要な「実施場所・通訳者・種別ごとの記録」
alter table public.support_schedules add column if not exists place text;
alter table public.support_schedules add column if not exists interpreter text;
alter table public.support_schedules add column if not exists record jsonb default '{}'::jsonb;
-- 所属機関：帳簿②（支援委託契約管理簿）
alter table public.companies add column if not exists support_contract_date date;
alter table public.companies add column if not exists support_contract_end date;
alter table public.companies add column if not exists support_contract_scope text;
alter table public.companies add column if not exists support_cost_note text;
-- 外国人材：帳簿③（支援対象者管理簿）
alter table public.workers add column if not exists support_plan_date date;
alter table public.workers add column if not exists support_start_date date;
alter table public.workers add column if not exists support_end_date date;
alter table public.workers add column if not exists support_end_reason text;

-- ===== 2026/11/04 支援委託契約書（参考様式第5-10号）用 =====
alter table public.companies add column if not exists support_fee_items jsonb default '[]'::jsonb;
alter table public.companies add column if not exists support_court text;

-- ===== 2026/11/04 署名済み支援委託契約書（5-10号）の保管 =====
alter table public.workers add column if not exists support_contract_signed_date date;
alter table public.workers add column if not exists support_contract_pdf_url text;
-- 5-9・5-8・5-5・5-6 の署名済みPDFは support_schedules.record（signed_url / signed_date、r55・r56 の中）に入る

-- ===== 2026/11/04 アカウント設定（ユーザーごとの表示名・担当者との紐づけ） =====
alter table public.members add column if not exists staff_name text;
-- 書き込みは関数 update_my_member（本人）／ admin_update_member（管理者・運営）だけ。定義は Supabase のマイグレーション member_account_settings_20261104 を参照

-- ===== 2026/11/04 ユーザーの停止・削除の制限 =====
-- members.active=false のユーザーは my_org_id()/my_role() が null になり、どのデータにも触れられない（Auth側もban）
alter table public.members add column if not exists active boolean not null default true;
alter table public.members add column if not exists disabled_at timestamptz;
alter table public.members add column if not exists disabled_by text;
-- support_schedules / company_meetings / leads / activities の DELETE は管理者・運営だけ（ポリシー "admin delete"）
-- 定義は Supabase のマイグレーション member_disable_and_admin_delete_20261104 を参照

-- ===== 2026/11/05 機関ごとの区切りの点検・操作の記録 =====
-- sql/20261105_security_audit.sql を SQL Editor で実行する（何度実行しても同じ結果）

-- ===== 2026/11/05 O-Link連携 =====
-- sql/20261105_olink_links.sql → sql/20261105_security_audit.sql の順に実行（サーバー処理は supabase/functions/olink）
