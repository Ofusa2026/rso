-- =====================================================================
-- 2026/11/05 O-Link（大房の登録支援機関マイページ）との連携
--   鍵（トークン・パスワード）はサーバー処理（olink）だけが読む。画面からはだれも読めない
--   鍵が操作の記録に残らないよう、olink_links は記録の対象外
--   ※ rso_attach_audit / rls_audit も olink_links を除外する版に置きかえる（中身は sql/20261105_security_audit.sql と同じ＋除外）
-- =====================================================================
create table if not exists public.olink_links (
  org_id      uuid primary key references public.orgs(id) on delete cascade,
  token       text not null,
  pass        text,
  olink_name  text,
  linked_at   timestamptz not null default now(),
  linked_by   text
);
alter table public.olink_links enable row level security;
revoke all on public.olink_links from anon, authenticated;
drop trigger if exists rso_audit on public.olink_links;
