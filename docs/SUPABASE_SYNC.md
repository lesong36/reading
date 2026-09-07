# Supabase sync

## What syncs

- Vocabulary, favorites, reading position, quiz progress, and incorrect-answer history.
- Vocabulary can be imported by VocabMaster as a separate, recognition-only “阅读生词本” after signing in with the same account.
- VocabMaster stores its full learner state (including unit progress, mistake-book state, and recognition progress) in `vocab_master_progress`; run the latest `supabase/schema.sql` once before using cross-device progress sync.
- Non-sensitive AI preferences (provider, model, base URL, voice preferences).
- The cloud AI key only as a client-side AES-GCM encrypted payload.

Article bundles and sentence analyses never sync through Supabase. They are published with the app/GitHub data packs and always remain available offline.

## Setup

1. In Supabase Auth, enable **Email** authentication. In **Authentication → URL Configuration**, set Site URL to `https://lesong36.github.io/reading/` and add the same address under Redirect URLs. For development, disable email confirmation only if appropriate for the project; production should use confirmation.
2. Run [`supabase/schema.sql`](../supabase/schema.sql) in **SQL Editor**.
3. The app includes the project URL and publishable key. Never add a `sb_secret_*` or service-role key to any browser configuration.
4. Register with a unique username, email, and password.
5. In cloud settings, set a **sync password** before enabling AI-key sync. This password is never uploaded; losing it makes the encrypted AI key unrecoverable.

## Security model

RLS limits `profiles` and `reader_sync_state` to `auth.uid() = user_id`. The browser uses Supabase's publishable key only; it is safe to distribute when RLS is enabled. The client encrypts AI credentials before writing them to `encrypted_ai_key`.

## Daily report email

Daily email is opt-in from the cloud-sync settings. It is sent to the verified Supabase Auth email, not an email entered in the browser. The client records minimal learning events; a scheduled Edge Function composes and sends the report when the user-selected local time arrives.

1. Run the latest [`supabase/schema.sql`](../supabase/schema.sql).
2. Deploy `supabase/functions/send-daily-reports` (its `config.toml` intentionally disables JWT verification because Cron is the caller; the function rejects every request without `DAILY_REPORT_CRON_SECRET`).
3. Set Edge Function secrets: `RESEND_API_KEY`, `DAILY_REPORT_FROM`, `DAILY_REPORT_CRON_SECRET`, and optionally `DAILY_REPORT_APP_URL`. Do not place these values in `local-config.js`.
4. Run [`supabase/daily-report-cron.sql`](../supabase/daily-report-cron.sql) after replacing its two placeholders. It invokes the function every 10 minutes with `x-daily-report-secret` from Vault. The function uses each learner's configured timezone and delivery time, and `daily_report_deliveries` prevents duplicate reports per local date.

The function intentionally skips a day with no learning events. Delivery status is stored server-side and can be surfaced in the app without exposing email-provider credentials.

## Teacher review console

Teachers review answer-key disputes in the app, not in the Supabase table editor. A project administrator only needs to grant the teacher account once after it has registered:

```sql
insert into public.teacher_accounts (user_id)
select id from auth.users where email = 'teacher@example.com';
```

After signing in, that account sees **教师审核** in the top navigation. The workbench lists only pending reports and shows the question, learner choice, proposed answer, locator sentence, learner note, and AI evidence. **批准并更新答案** creates or updates the approved correction; **驳回** keeps the current official answer. RLS prevents non-teacher accounts from viewing or changing any report or correction.
