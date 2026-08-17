-- Run once in Supabase Dashboard → SQL Editor.
-- The client uses only the publishable key. Never place a secret/service key
-- in this app, GitHub Pages, local-config.js, or a browser.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[A-Za-z0-9_]{3,32}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reader_sync_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  vocabulary jsonb not null default '[]'::jsonb,
  favorites jsonb not null default '[]'::jsonb,
  reading_positions jsonb not null default '{}'::jsonb,
  quiz_progress jsonb not null default '{}'::jsonb,
  completion_records jsonb not null default '{}'::jsonb,
  wrong_answers jsonb not null default '[]'::jsonb,
  vocab_master_progress jsonb not null default '{}'::jsonb,
  preferences jsonb not null default '{}'::jsonb,
  encrypted_ai_key jsonb,
  updated_at timestamptz not null default now()
);

-- Safe to rerun if the table was created by an earlier draft of this schema.
alter table public.reader_sync_state add column if not exists wrong_answers jsonb not null default '[]'::jsonb;
alter table public.reader_sync_state add column if not exists vocab_master_progress jsonb not null default '{}'::jsonb;
alter table public.reader_sync_state add column if not exists completion_records jsonb not null default '{}'::jsonb;

-- Learners submit suspected answer-key issues here. Teachers review reports in
-- the Supabase dashboard and create the approved correction below; the browser
-- only reads approved corrections and therefore cannot change answer keys.
create table if not exists public.quiz_answer_reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  article_id text not null,
  article_title text,
  question_id text not null,
  question_prompt text,
  reported_answer_index integer,
  learner_answer_index integer,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.quiz_answer_corrections (
  id bigint generated always as identity primary key,
  article_id text not null,
  question_id text not null,
  corrected_answer_index integer not null check (corrected_answer_index between 0 and 9),
  teacher_note text,
  status text not null default 'approved' check (status in ('draft', 'approved', 'rejected')),
  reviewed_at timestamptz not null default now(),
  unique (article_id, question_id)
);

alter table public.profiles enable row level security;
alter table public.reader_sync_state enable row level security;
alter table public.quiz_answer_reports enable row level security;
alter table public.quiz_answer_corrections enable row level security;

create policy "profiles are readable by their owner"
  on public.profiles for select to authenticated using (auth.uid() = id);
create policy "profiles are writable by their owner"
  on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create policy "reader state is readable by its owner"
  on public.reader_sync_state for select to authenticated using (auth.uid() = user_id);
create policy "reader state is insertable by its owner"
  on public.reader_sync_state for insert to authenticated with check (auth.uid() = user_id);
create policy "reader state is updatable by its owner"
  on public.reader_sync_state for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "learners can submit their own answer reports"
  on public.quiz_answer_reports for insert to authenticated with check (auth.uid() = reporter_id);
create policy "learners can read their own answer reports"
  on public.quiz_answer_reports for select to authenticated using (auth.uid() = reporter_id);
create policy "approved answer corrections are readable"
  on public.quiz_answer_corrections for select to authenticated using (status = 'approved');

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (new.id, lower(coalesce(new.raw_user_meta_data ->> 'username', '')));
  insert into public.reader_sync_state (user_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Keep signup metadata private; no public username/email lookup is exposed.
revoke all on function public.handle_new_user() from public;
