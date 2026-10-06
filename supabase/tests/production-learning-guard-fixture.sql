-- Production metadata-only fixture captured 2026-10-07.
-- No user rows or credentials. Do not deploy this fixture.
create table public.vocab_admin_baseline_override (
  "user_id" uuid not null,
  "master" jsonb not null,
  "reason" text not null,
  PRIMARY KEY (user_id),
  FOREIGN KEY (user_id) REFERENCES auth.users(id)
);
create table public.vocab_learning_events (
  "user_id" uuid not null,
  "event_id" text not null,
  "epoch" uuid not null,
  "word_id" text not null,
  "occurred_at" timestamp with time zone not null,
  "result" text not null,
  "payload" jsonb not null,
  "accounted_as" text not null,
  "received_at" timestamp with time zone default clock_timestamp() not null,
  CHECK ((accounted_as = ANY (ARRAY['baseline'::text, 'answer'::text]))),
  PRIMARY KEY (user_id, event_id),
  CHECK ((result = ANY (ARRAY['correct'::text, 'incorrect'::text]))),
  FOREIGN KEY (user_id) REFERENCES auth.users(id)
);
create table public.vocab_snapshot_archive (
  "user_id" uuid not null,
  "revision" bigint not null,
  "epoch" uuid not null,
  "archived_at" timestamp with time zone default clock_timestamp() not null,
  "full_master" jsonb,
  "delta" jsonb,
  "reason" text not null,
  PRIMARY KEY (user_id, revision),
  FOREIGN KEY (user_id) REFERENCES auth.users(id)
);
create table public.vocab_sync_metadata (
  "user_id" uuid not null,
  "epoch" uuid default gen_random_uuid() not null,
  "revision" bigint default 0 not null,
  "baseline_at" timestamp with time zone default clock_timestamp() not null,
  "baseline_master" jsonb default '{}'::jsonb not null,
  PRIMARY KEY (user_id),
  FOREIGN KEY (user_id) REFERENCES auth.users(id)
);
CREATE OR REPLACE FUNCTION public.vocab_profile_v3(p_master jsonb, p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare p jsonb; n integer;
begin
  if jsonb_typeof(p_master->'appState'->'users') is distinct from 'object' then
    return '{}'::jsonb;
  end if;
  select count(*) into n from jsonb_object_keys(p_master->'appState'->'users');
  if n > 1 then raise exception 'Ambiguous learner profiles; reviewed migration required' using errcode = '22023'; end if;
  select value into p from jsonb_each(p_master->'appState'->'users');
  if p is null then return '{}'::jsonb; end if;
  if jsonb_typeof(p->'words') is distinct from 'array' or
     jsonb_typeof(coalesce(p->'studyEvents', '[]'::jsonb)) is distinct from 'array' then
    raise exception 'Invalid learning profile' using errcode = '22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p->'words') w where nullif(w->>'id','') is null) or
     (select count(*) from jsonb_array_elements(p->'words')) <>
     (select count(distinct w->>'id') from jsonb_array_elements(p->'words') w) then
    raise exception 'Missing or duplicated word IDs' using errcode = '22023';
  end if;
  return p || jsonb_build_object('id', 'reader_' || p_uid);
end $function$;

CREATE OR REPLACE FUNCTION public.vocab_guard_snapshot_v3()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  meta public.vocab_sync_metadata%rowtype;
  old_master jsonb := '{}'::jsonb; incoming jsonb; old_p jsonb; new_p jsonb; merged_p jsonb;
  override_master jsonb; override_reason text; is_baseline boolean := false;
  e jsonb; existing_event jsonb; event_time timestamptz; inserted integer;
  old_words jsonb; merged_words jsonb; word_buffer jsonb[] := '{}'::jsonb[]; merged_word_map jsonb; baseline_word_map jsonb; old_word jsonb; new_word jsonb; chosen jsonb;
  merged_events jsonb; reward jsonb; ignored jsonb; added_ids text[] := '{}'::text[];
  count_correct integer; count_incorrect integer; streak integer; cleared boolean;
  baseline_word jsonb; baseline_profile jsonb; latest_answer jsonb;
  latest_at text; changed_old_words jsonb; archive_full boolean;
begin
  -- An UPSERT executes INSERT triggers before conflict resolution. Defer all
  -- journal effects to its UPDATE trigger when the learner row already exists.
  if tg_op='INSERT' and exists(select 1 from public.reader_sync_state where user_id=new.user_id) then return new; end if;
  if tg_op = 'UPDATE' then old_master := coalesce(old.vocab_master_progress, '{}'::jsonb); end if;
  incoming := coalesce(new.vocab_master_progress, '{}'::jsonb);
  delete from public.vocab_admin_baseline_override where user_id=new.user_id
    returning master, reason into override_master, override_reason;
  if override_master is not null then incoming := override_master; is_baseline := true; end if;
  select * into meta from public.vocab_sync_metadata where user_id=new.user_id for update;
  if not found then
    insert into public.vocab_sync_metadata(user_id) values(new.user_id) returning * into meta;
    is_baseline := true;
    -- When upgrading an existing row, OLD is the trusted baseline. INSERTs
    -- start with their first supplied profile, whose history is a baseline.
    if tg_op='UPDATE' and override_master is null then incoming := old_master; end if;
  elsif override_master is not null then
    update public.vocab_sync_metadata set epoch=gen_random_uuid(), baseline_at=clock_timestamp()
      where user_id=new.user_id returning * into meta;
  end if;
  old_p := public.vocab_profile_v3(old_master,new.user_id);
  new_p := public.vocab_profile_v3(incoming,new.user_id);
  if is_baseline then
    update public.vocab_sync_metadata set baseline_master=incoming,
      baseline_at=coalesce((select max((value->>'at')::timestamptz)
        from jsonb_array_elements(coalesce(new_p->'studyEvents','[]'::jsonb))),case when new_p='{}'::jsonb then '-infinity'::timestamptz else clock_timestamp() end)
      where user_id=new.user_id returning * into meta;
    old_p := '{}'::jsonb;
  end if;
  baseline_profile := public.vocab_profile_v3(meta.baseline_master,new.user_id);
  select coalesce(jsonb_object_agg(w->>'id',w),'{}'::jsonb) into baseline_word_map
    from jsonb_array_elements(coalesce(baseline_profile->'words','[]'::jsonb)) w;

  -- Immutable IDs: replaying an ID with altered identity/result is rejected.
  -- New durable v3 answers are counted even with an older clock timestamp.
  -- Unmarked legacy events before the baseline are evidence only: existing
  -- aggregate counters may already include them, so they cannot be summed.
  for e in select value from jsonb_array_elements(coalesce(new_p->'studyEvents','[]'::jsonb)) loop
    if nullif(e->>'id','') is null or nullif(e->>'wordId','') is null or e->>'result' not in ('correct','incorrect')
       or nullif(e->>'at','') is null then
      raise exception 'Malformed study event' using errcode='22023';
    end if;
    event_time := (e->>'at')::timestamptz;
    if event_time > clock_timestamp() + interval '5 minutes' then
      raise exception 'Study event timestamp exceeds clock tolerance' using errcode='22023';
    end if;
    select payload into existing_event from public.vocab_learning_events where user_id=new.user_id and event_id=e->>'id';
    if found then
      if (existing_event->>'wordId',existing_event->>'at',existing_event->>'result') is distinct from
         (e->>'wordId',e->>'at',e->>'result') then
        raise exception 'Study event ID already identifies a different answer' using errcode='22023';
      end if;
    else
      insert into public.vocab_learning_events(user_id,event_id,epoch,word_id,occurred_at,result,payload,accounted_as)
        values(new.user_id,e->>'id',meta.epoch,e->>'wordId',event_time,e->>'result',e,
          case when is_baseline or (coalesce(e->>'durableVersion','')<>'3' and event_time <= meta.baseline_at)
            then 'baseline' else 'answer' end)
        on conflict(user_id,event_id) do nothing;
      get diagnostics inserted = row_count;
      if inserted=1 and not is_baseline and (e->>'durableVersion'='3' or event_time > meta.baseline_at) then
        added_ids := array_append(added_ids,e->>'id');
      end if;
    end if;
  end loop;

  merged_p := case when coalesce(old_p->>'updatedAt','') > coalesce(new_p->>'updatedAt','')
    then new_p || old_p else old_p || new_p end;
  select coalesce(jsonb_agg(distinct x),'[]'::jsonb) into ignored from (
    select value x from jsonb_array_elements(coalesce(old_p->'ignoredReadingWordIds','[]'::jsonb))
    union all select value from jsonb_array_elements(coalesce(new_p->'ignoredReadingWordIds','[]'::jsonb))
  ) t;
  old_words := coalesce(old_p->'words','[]'::jsonb);
  merged_words := '[]'::jsonb;
  for old_word,new_word in
    select a.value,b.value from jsonb_array_elements(old_words) with ordinality a(value,position)
      full join jsonb_array_elements(coalesce(new_p->'words','[]'::jsonb)) with ordinality b(value,position)
        on a.value->>'id'=b.value->>'id'
      order by coalesce(a.position,jsonb_array_length(old_words)+b.position)
  loop
    chosen := case when coalesce(old_word->>'vocabMasterProgressUpdatedAt','') > coalesce(new_word->>'vocabMasterProgressUpdatedAt','')
      then coalesce(new_word,'{}'::jsonb) || old_word else coalesce(old_word,'{}'::jsonb) || coalesce(new_word,'{}'::jsonb) end;
    if ignored ? (chosen->>'id') then continue; end if;
    if is_baseline then
      count_correct := greatest(0,coalesce((chosen->>'correctCount')::integer,0));
      count_incorrect := greatest(0,coalesce((chosen->>'incorrectCount')::integer,0));
      streak := greatest(0,coalesce((chosen->>'consecutiveCorrect')::integer,0));
      cleared := coalesce((chosen->>'mistakeCleared')::boolean,false);
    else
      count_correct := greatest(0,coalesce((old_word->>'correctCount')::integer,0));
      count_incorrect := greatest(0,coalesce((old_word->>'incorrectCount')::integer,0));
      streak := greatest(0,coalesce((old_word->>'consecutiveCorrect')::integer,0));
      cleared := coalesce((old_word->>'mistakeCleared')::boolean,false);
      baseline_word := baseline_word_map->(chosen->>'id');
      streak := greatest(0,coalesce((baseline_word->>'consecutiveCorrect')::integer,0));
      cleared := coalesce((baseline_word->>'mistakeCleared')::boolean,false);
      -- Recompute chronological state: a late offline incorrect answer between
      -- two correct answers must break the streak, regardless of arrival order.
      for e in select payload from public.vocab_learning_events
        where user_id=new.user_id and epoch=meta.epoch and accounted_as='answer'
        and word_id=chosen->>'id' order by occurred_at,event_id loop
        if e->>'id'=any(added_ids) then
          if e->>'result'='correct' then count_correct:=count_correct+1; else count_incorrect:=count_incorrect+1; end if;
        end if;
        if e->>'result'='incorrect' then streak:=0; cleared:=false;
        else streak:=streak+1; if count_incorrect>0 and streak>=2 then cleared:=true; end if; end if;
        if jsonb_typeof(e->'wordState')='object' then
          chosen := chosen || jsonb_strip_nulls(jsonb_build_object(
            'readingIntroducedAt',e->'wordState'->'readingIntroducedAt',
            'readingMasteredAt',e->'wordState'->'readingMasteredAt',
            'readingNextDueAt',e->'wordState'->'readingNextDueAt',
            'readingReviewStage',e->'wordState'->'readingReviewStage'));
        end if;
        chosen := chosen || jsonb_build_object('vocabMasterProgressUpdatedAt',e->>'at');
      end loop;
    end if;
    chosen := chosen || jsonb_build_object('correctCount',count_correct,'incorrectCount',count_incorrect,
      'consecutiveCorrect',streak,'mistakeCleared',cleared);
    word_buffer := array_append(word_buffer,chosen);
  end loop;
  select coalesce(jsonb_agg(w),'[]'::jsonb),coalesce(jsonb_object_agg(w->>'id',w),'{}'::jsonb)
    into merged_words,merged_word_map from unnest(word_buffer) w;
  -- An answer without its word cannot be projected safely.
  if exists(select 1 from public.vocab_learning_events e where e.user_id=new.user_id and e.event_id=any(added_ids)
    and not exists(select 1 from jsonb_array_elements(merged_words) w where w->>'id'=e.word_id)
    and not ignored ? e.word_id) then raise exception 'Answer references missing word' using errcode='22023'; end if;
  select coalesce(jsonb_agg(payload order by occurred_at,event_id),'[]'::jsonb) into merged_events
    from public.vocab_learning_events where user_id=new.user_id;
  reward := coalesce(old_p->'rewardLedger','{}'::jsonb);
  -- Reward points are tied to immutable answer IDs, not arbitrary snapshots.
  for e in select value from jsonb_array_elements(merged_events) loop
    if coalesce((e->>'rewardPoints')::integer,0) between 1 and 15 then
      reward := reward || jsonb_build_object(e->>'id',(e->>'rewardPoints')::integer);
    end if;
  end loop;
  if is_baseline then reward := reward || coalesce(new_p->'rewardLedger','{}'::jsonb); end if;
  merged_p := merged_p || jsonb_build_object('id','reader_'||new.user_id,'words',merged_words,
    'studyEvents',merged_events,'rewardLedger',reward,'ignoredReadingWordIds',ignored);
  incoming := incoming || jsonb_build_object('version',3,'appState',
    coalesce(incoming->'appState',old_master->'appState','{}'::jsonb) || jsonb_build_object('version',1,
      'currentUserId','reader_'||new.user_id,'users',jsonb_build_object('reader_'||new.user_id,merged_p)));
  -- Reading convenience projection is derived from the same authoritative words.
  incoming := incoming || jsonb_build_object('words',coalesce((select jsonb_object_agg(lower(w->>'english_word'),
    jsonb_build_object('correctCount',w->'correctCount','incorrectCount',w->'incorrectCount',
      'consecutiveCorrect',w->'consecutiveCorrect','mistakeCleared',w->'mistakeCleared',
      'flashcardKnown',coalesce(w->'flashcardKnown','false'::jsonb),
      'updatedAt',coalesce(w->'vocabMasterProgressUpdatedAt','""'::jsonb),
      'readingIntroducedAt',coalesce(w->'readingIntroducedAt','""'::jsonb),
      'readingNextDueAt',coalesce(w->'readingNextDueAt','""'::jsonb),
      'readingMasteredAt',coalesce(w->'readingMasteredAt','""'::jsonb),
      'readingReviewStage',coalesce(w->'readingReviewStage','0'::jsonb)))
    from jsonb_array_elements(merged_words) w where w->>'source'='reading'),'{}'::jsonb));
  if (incoming-'_sync') is distinct from (old_master-'_sync') or is_baseline then
    -- One daily full baseline; intermediate deltas contain the replaced old
    -- words, old profile metadata, event IDs and reward ledger for reconstruction.
    archive_full := not exists(select 1 from public.vocab_snapshot_archive where user_id=new.user_id
      and full_master is not null and (archived_at at time zone 'UTC')::date=(clock_timestamp() at time zone 'UTC')::date);
    select coalesce(jsonb_agg(w),'[]'::jsonb) into changed_old_words from jsonb_array_elements(old_words) w
      where w is distinct from merged_word_map->(w->>'id');
    insert into public.vocab_snapshot_archive(user_id,revision,epoch,full_master,delta,reason)
      values(new.user_id,meta.revision,coalesce((old_master#>>'{_sync,epoch}')::uuid,meta.epoch),case when archive_full or override_master is not null then old_master end,
        case when not archive_full and override_master is null then jsonb_build_object(
          'previousTopLevel',old_master-'appState'-'words',
          'previousAppMetadata',coalesce(old_master->'appState','{}'::jsonb)-'users',
          'previousProfileMetadata',old_p-'words'-'studyEvents'-'rewardLedger',
          'previousWords',changed_old_words,
          'previousWordIds',coalesce((select jsonb_agg(w->'id') from jsonb_array_elements(old_words) w),'[]'::jsonb),
          'previousEventIds',coalesce((select jsonb_agg(prior_event->'id') from jsonb_array_elements(coalesce(old_p->'studyEvents','[]'::jsonb)) prior_event),'[]'::jsonb),
          'previousRewardLedger',old_p->'rewardLedger') end,
        coalesce(override_reason,case when is_baseline then 'verified baseline seed' else 'atomic learning sync' end))
      on conflict(user_id,revision) do nothing;
    update public.vocab_sync_metadata set revision=revision+1 where user_id=new.user_id returning * into meta;
  end if;
  incoming := incoming || jsonb_build_object('_sync',jsonb_build_object('epoch',meta.epoch,'revision',meta.revision,'baselineAt',meta.baseline_at));
  new.vocab_master_progress := incoming;
  return new;
end $function$;
create trigger vocab_guard_snapshot_v3 before insert or update of vocab_master_progress on public.reader_sync_state for each row execute function public.vocab_guard_snapshot_v3();

