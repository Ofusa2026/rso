-- =====================================================================
-- 2026/11/05 セキュリティ：機関ごとの区切りの点検 ＋ 操作の記録
--   Supabase の SQL Editor で、このファイルを丸ごと1回実行してください（何度実行しても同じ結果になります）
-- =====================================================================

-- ---------------------------------------------------------------
-- 1. 新しく作った public のテーブルは、自動で RLS を有効にする
--    （ポリシーを書くまで、だれも読み書きできない＝設定もれで丸見えにならない）
-- ---------------------------------------------------------------
create or replace function public.rso_enable_rls_on_new_table() returns event_trigger
language plpgsql security definer set search_path to 'public','pg_catalog' as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() where command_tag in ('CREATE TABLE','CREATE TABLE AS','SELECT INTO') loop
    if r.schema_name = 'public' and r.object_type = 'table' then
      execute format('alter table %s enable row level security', r.object_identity);
      raise notice 'RLS を有効にしました：%（ポリシーを書くまでアクセスできません）', r.object_identity;
    end if;
  end loop;
end $$;
revoke all on function public.rso_enable_rls_on_new_table() from public, anon, authenticated;
drop event trigger if exists rso_enable_rls_on_new_table;
create event trigger rso_enable_rls_on_new_table on ddl_command_end
  when tag in ('CREATE TABLE','CREATE TABLE AS','SELECT INTO')
  execute function public.rso_enable_rls_on_new_table();

-- ---------------------------------------------------------------
-- 2. 区切りの点検（運営だけが実行できる）
--    問題があるテーブルを1行ずつ返す。何も返らなければ問題なし。
-- ---------------------------------------------------------------
create or replace function public.rls_audit()
returns table(table_name text, level text, problem text)
language plpgsql stable security definer set search_path to 'public','pg_catalog' as $$
declare t record; pol record; has_org boolean; n int; ok_all boolean;
begin
  if public.my_role() is distinct from 'operator' then raise exception '運営だけが使えます'; end if;
  for t in select c.oid, c.relname, c.relrowsecurity from pg_class c join pg_namespace s on s.oid=c.relnamespace
           where s.nspname='public' and c.relkind in ('r','p') order by c.relname loop
    has_org := exists(select 1 from information_schema.columns where table_schema='public' and information_schema.columns.table_name=t.relname and column_name='org_id');
    if not t.relrowsecurity then
      table_name:=t.relname; level:='危険'; problem:='RLS が無効です。ログインした人ならだれでも全機関のデータを読み書きできます'; return next; continue;
    end if;
    select count(*) into n from pg_policies p where p.schemaname='public' and p.tablename=t.relname;
    if n=0 then
      if t.relname not in ('audit_log') then
        table_name:=t.relname; level:='注意'; problem:='ポリシーがありません（だれも使えない状態）。使うテーブルならポリシーを書いてください'; return next;
      end if;
      continue;
    end if;
    -- anon（ログインしていない人）に開いているポリシー
    for pol in select * from pg_policies p where p.schemaname='public' and p.tablename=t.relname
               and (p.roles::text like '%public%' or p.roles::text like '%anon%') loop
      table_name:=t.relname; level:='危険'; problem:='ポリシー「'||pol.policyname||'」がログインしていない人にも開いています'; return next;
    end loop;
    -- 機関で区切っていないポリシー
    for pol in select * from pg_policies p where p.schemaname='public' and p.tablename=t.relname loop
      ok_all := coalesce(pol.qual,'') ~ 'my_org_id\(\)' or (pol.cmd='INSERT' and coalesce(pol.with_check,'') ~ 'my_org_id\(\)')
                or (t.relname='members' and coalesce(pol.qual,'') ~ 'my_org_id\(\)');
      if coalesce(pol.qual,'') in ('true','(true)') or coalesce(pol.with_check,'') in ('true','(true)') then
        table_name:=t.relname; level:='危険'; problem:='ポリシー「'||pol.policyname||'」が条件なし（true）で全員に開いています'; return next;
      elsif not ok_all then
        table_name:=t.relname; level:='注意'; problem:='ポリシー「'||pol.policyname||'」（'||pol.cmd||'）が my_org_id() で機関を区切っていません。意図どおりか確認してください'; return next;
      end if;
      if pol.cmd in ('INSERT','UPDATE','ALL') and pol.with_check is not null and coalesce(pol.with_check,'') !~ 'my_org_id\(\)' and t.relname<>'orgs' then
        table_name:=t.relname; level:='注意'; problem:='ポリシー「'||pol.policyname||'」の書き込み条件（with check）に機関の区切りがありません'; return next;
      end if;
    end loop;
    if not has_org and t.relname not in ('orgs','members','audit_log') then
      table_name:=t.relname; level:='注意'; problem:='org_id の列がありません。どの機関のデータか区別できません'; return next;
    end if;
    -- 操作の記録が付いていない（業務テーブル）
    if has_org and t.relname not in ('audit_log','chat_read_at') and not exists(
         select 1 from pg_trigger g where g.tgrelid=t.oid and g.tgname='rso_audit' and not g.tgisinternal) then
      table_name:=t.relname; level:='注意'; problem:='操作の記録（rso_audit）が付いていません。下の「操作の記録を付け直す」を実行してください'; return next;
    end if;
  end loop;
  -- 添付ファイルの置き場所
  if exists(select 1 from storage.buckets where id='rso-files' and public) then
    table_name:='storage: rso-files'; level:='危険'; problem:='添付ファイルの置き場所が公開になっています'; return next;
  end if;
end $$;
revoke all on function public.rls_audit() from public, anon;
grant execute on function public.rls_audit() to authenticated;

-- ---------------------------------------------------------------
-- 3. 操作の記録（だれが・いつ・何を追加／変更／削除したか）
--    書き込みはトリガーだけ。画面からは管理者・運営が自分の機関の分を読むだけ（変更・削除はできない）
-- ---------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid,
  at          timestamptz not null default now(),
  user_id     uuid,
  user_name   text,
  action      text not null,          -- INSERT / UPDATE / DELETE
  table_name  text not null,
  row_id      text,
  label       text,                   -- 一覧で分かる名前（氏名・会社名など）
  changes     jsonb                   -- UPDATE は変わった項目だけ {項目:{old,new}}、INSERT/DELETE は行全体
);
create index if not exists audit_log_org_at_idx on public.audit_log(org_id, at desc);
create index if not exists audit_log_row_idx on public.audit_log(table_name, row_id);
alter table public.audit_log enable row level security;
drop policy if exists "admin read own org" on public.audit_log;
create policy "admin read own org" on public.audit_log for select to authenticated
  using (org_id = public.my_org_id() and public.my_role() in ('admin','operator'));
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;   -- 読めるのは上のポリシー（自分の機関・管理者／運営）の分だけ

create or replace function public.rso_audit_trigger() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare o jsonb; n jsonb; d jsonb := '{}'::jsonb; k text; v_org uuid; v_id text; v_label text; v_uid uuid := auth.uid(); v_name text;
  skip constant text[] := array['updated_at','updated_by','created_at','last_message_at','last_message_text','last_message_by','progress_changed_at','apply_status_changed_at'];
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k = any(skip) then continue; end if;
      if (o->k) is distinct from (n->k) then d := d || jsonb_build_object(k, jsonb_build_object('old', o->k, 'new', n->k)); end if;
    end loop;
    if d = '{}'::jsonb then return new; end if;     -- 更新日時だけの変更は記録しない
  else
    d := coalesce(n, o);
  end if;
  v_org := coalesce((coalesce(n,o)->>'org_id')::uuid, case when tg_table_name='orgs' then (coalesce(n,o)->>'id')::uuid end);
  v_id  := coalesce(coalesce(n,o)->>'id', coalesce(n,o)->>'user_id', coalesce(n,o)->>'src_row');
  v_label := left(coalesce(coalesce(n,o)->>'name', coalesce(n,o)->>'company_name', coalesce(n,o)->>'display_name',
                           coalesce(n,o)->>'meeting_date', coalesce(n,o)->>'scheduled_at', coalesce(n,o)->>'content', ''), 120);
  if v_uid is not null then select display_name into v_name from public.members where user_id = v_uid; end if;
  insert into public.audit_log(org_id, user_id, user_name, action, table_name, row_id, label, changes)
  values (v_org, v_uid, coalesce(nullif(v_name,''), case when v_uid is null then 'システム' end), tg_op, tg_table_name, v_id, nullif(v_label,''), d);
  return coalesce(new, old);
end $$;
revoke all on function public.rso_audit_trigger() from public, anon, authenticated;

-- 記録を付ける（業務テーブル全部。既読の記録 chat_read_at は件数が多いので除く）
create or replace function public.rso_attach_audit() returns int
language plpgsql security definer set search_path to 'public' as $$
declare t record; n int := 0;
begin
  if auth.uid() is not null and public.my_role() is distinct from 'operator' then raise exception '運営だけが使えます'; end if;
  for t in select c.relname from pg_class c join pg_namespace s on s.oid=c.relnamespace
           where s.nspname='public' and c.relkind='r'
             and (exists(select 1 from information_schema.columns x where x.table_schema='public' and x.table_name=c.relname and x.column_name='org_id') or c.relname='orgs')
             and c.relname not in ('audit_log','chat_read_at') loop
    execute format('drop trigger if exists rso_audit on public.%I', t.relname);
    execute format('create trigger rso_audit after insert or update or delete on public.%I for each row execute function public.rso_audit_trigger()', t.relname);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.rso_attach_audit() from public, anon;
grant execute on function public.rso_attach_audit() to authenticated;
select public.rso_attach_audit();
