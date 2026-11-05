-- 2026/11/05 支援費用のチェック用の列（適用済み）
alter table public.companies add column if not exists support_fee_shown_date date;   -- 契約の前に、支援業務の費用の額・内訳を所属機関に示した日
alter table public.companies add column if not exists support_no_burden_date date;   -- 支援費用を外国人に負担させないことを所属機関と確認した日
