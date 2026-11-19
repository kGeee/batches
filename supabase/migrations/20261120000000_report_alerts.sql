-- Email alerts for new reports.
--
--   new row in reports
--     -> private.queue_report_alert (trigger) posts {id} to the `report-alert` edge function with
--        pg_net, which sends only after the inserting transaction commits
--     -> the function reads the report as service_role and emails it via Resend
--
-- As with push, nothing here can make filing a report fail: without the vault secret, or if
-- pg_net errors, the report is still stored and shows in the dashboard.
--
-- Setup, once per project (the shared secret is push_webhook_secret, already in the vault):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/report-alert', 'report_alert_url');

create or replace function private.queue_report_alert() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  url text;
  secret text;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'report_alert_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if url is null or secret is null then
    return null;
  end if;
  perform net.http_post(
    url := url,
    body := jsonb_build_object('id', new.id),
    headers := jsonb_build_object('content-type', 'application/json', 'authorization', 'Bearer ' || secret),
    timeout_milliseconds := 5000);
  return null;
exception when others then
  raise warning 'queue_report_alert %: %', new.id, sqlerrm;
  return null;
end $$;
revoke execute on function private.queue_report_alert() from public, anon, authenticated;

create trigger reports_alert after insert on reports
  for each row execute function private.queue_report_alert();
