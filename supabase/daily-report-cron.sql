-- Run after deploying the send-daily-reports Edge Function and setting the
-- matching DAILY_REPORT_CRON_SECRET function secret.
create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault;

-- Store once per project. Replace these placeholders before execution.
select vault.create_secret('https://YOUR_PROJECT_REF.supabase.co', 'daily_report_project_url');
select vault.create_secret('REPLACE_WITH_DAILY_REPORT_CRON_SECRET', 'daily_report_cron_secret');

select cron.unschedule(jobid) from cron.job where jobname = 'send-daily-learning-reports';
select cron.schedule(
  'send-daily-learning-reports',
  '*/10 * * * *',
  $$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'daily_report_project_url') || '/functions/v1/send-daily-reports',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-daily-report-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'daily_report_cron_secret')
      ),
      body := '{}'::jsonb
    );
  $$
);
