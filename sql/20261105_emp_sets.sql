alter table workers add column if not exists emp_set text;
alter table companies alter column emp_sets set default '[]'::jsonb;
