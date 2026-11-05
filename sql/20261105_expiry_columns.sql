alter table companies add column if not exists agreement_36_expiry date, add column if not exists council_cert_expiry date;
alter table workers add column if not exists health_check_date date;
