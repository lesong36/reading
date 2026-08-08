# Supabase sync

## What syncs

- Vocabulary, favorites, reading position, quiz progress, and incorrect-answer history.
- Non-sensitive AI preferences (provider, model, base URL, voice preferences).
- The cloud AI key only as a client-side AES-GCM encrypted payload.

Article bundles and sentence analyses never sync through Supabase. They are published with the app/GitHub data packs and always remain available offline.

## Setup

1. In Supabase Auth, enable **Email** authentication. For development, disable email confirmation only if appropriate for the project; production should use confirmation.
2. Run [`supabase/schema.sql`](../supabase/schema.sql) in **SQL Editor**.
3. The app includes the project URL and publishable key. Never add a `sb_secret_*` or service-role key to any browser configuration.
4. Register with a unique username, email, and password.
5. In cloud settings, set a **sync password** before enabling AI-key sync. This password is never uploaded; losing it makes the encrypted AI key unrecoverable.

## Security model

RLS limits `profiles` and `reader_sync_state` to `auth.uid() = user_id`. The browser uses Supabase's publishable key only; it is safe to distribute when RLS is enabled. The client encrypts AI credentials before writing them to `encrypted_ai_key`.
