-- Vocabulary v2: apply after schema.sql, as the schema owner. No user data is
-- deleted. This is a reviewable SQL script, not fabricated CLI migration history.
begin;
alter table public.reader_sync_state add column if not exists vocab_revision bigint not null default 0;
alter table public.reader_sync_state add column if not exists vocab_tombstones jsonb not null default '[]'::jsonb;

-- Canonical keys follow native/browser whitespace trimming, including NBSP.
create or replace function public.vocabulary_word_key(value text) returns text
language sql immutable strict set search_path = '' as $$
  select lower(btrim(value, E' \t\n\r\f\v' || chr(133) || chr(160) || chr(5760) ||
    chr(8192)||chr(8193)||chr(8194)||chr(8195)||chr(8196)||chr(8197)||chr(8198)||chr(8199)||
    chr(8200)||chr(8201)||chr(8202)||chr(8232)||chr(8233)||chr(8239)||chr(8287)||chr(12288)));
$$;
-- Preserve a private, immutable pre-upgrade copy before normalizing old snapshots.
create table if not exists public.reader_vocabulary_upgrade_backup (
  user_id uuid primary key references auth.users(id) on delete cascade,
  vocabulary jsonb not null,
  deleted_keys jsonb not null,
  captured_at timestamptz not null default now()
);
alter table public.reader_vocabulary_upgrade_backup enable row level security;
revoke all on public.reader_vocabulary_upgrade_backup from public, anon, authenticated;
insert into public.reader_vocabulary_upgrade_backup(user_id,vocabulary,deleted_keys)
select user_id,vocabulary,coalesce(preferences->'deletedVocabKeys','[]') from public.reader_sync_state where vocab_revision=0
on conflict(user_id) do nothing;
-- Retain unknown fields; choose the newest legacy occurrence of a canonical word.
update public.reader_sync_state s set
  vocabulary = coalesce((select jsonb_agg(e || jsonb_build_object('cloudVersion',1)) from (
    select distinct on (public.vocabulary_word_key(value->>'word')) value e
    from jsonb_array_elements(s.vocabulary) vocab_entry
    where nullif(public.vocabulary_word_key(value->>'word'),'') is not null
      and not exists(select 1 from jsonb_array_elements_text(coalesce(s.preferences->'deletedVocabKeys','[]')) d
        where public.vocabulary_word_key(d)=public.vocabulary_word_key(vocab_entry.value->>'word'))
    order by public.vocabulary_word_key(value->>'word'), coalesce(value->>'updatedAt',value->>'definitionCheckedAt','') desc,
      coalesce((value->>'timestamp')::numeric,0) desc
  ) entries), '[]'),
  vocab_tombstones = coalesce((select jsonb_agg(jsonb_build_object('wordKey',k,'version',1,'deletedAt',s.updated_at))
    from (select distinct public.vocabulary_word_key(d) k from jsonb_array_elements_text(coalesce(s.preferences->'deletedVocabKeys','[]')) d
      where public.vocabulary_word_key(d)<>'') keys), '[]'),
  vocab_revision = 1
where s.vocab_revision = 0;

create table if not exists public.reader_vocabulary_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id text not null,
  operation jsonb not null,
  acknowledged_at timestamptz not null default now(),
  primary key (user_id, operation_id)
);
alter table public.reader_vocabulary_receipts enable row level security;
revoke all on public.reader_vocabulary_receipts from public, anon, authenticated;
-- Receipt reads/writes happen only within the owner-checked transaction below.

-- Old clients must never bypass revisions with PATCH/upsert. Column privileges
-- preserve reading progress/preferences writes while protecting vocabulary.
revoke insert, update on public.reader_sync_state from public, anon, authenticated;
revoke insert (vocabulary,vocab_revision,vocab_tombstones), update (vocabulary,vocab_revision,vocab_tombstones) on public.reader_sync_state from public, anon, authenticated;
do $$
declare allowed text;
begin
  select string_agg(quote_ident(column_name), ',') into allowed
  from information_schema.columns where table_schema='public' and table_name='reader_sync_state'
    and column_name not in ('vocabulary','vocab_revision','vocab_tombstones');
  execute 'grant insert (' || allowed || '), update (' || allowed || ') on public.reader_sync_state to authenticated';
  grant select on public.reader_sync_state to authenticated;
end;
$$;

-- Keep privileged implementation outside the Data API's exposed schema.
create schema if not exists reader_private;
revoke all on schema reader_private from public, anon;
grant usage on schema reader_private to authenticated;
create or replace function reader_private.sync_reader_vocabulary_v2(p_expected_revision bigint default null, p_operations jsonb default '[]')
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  owner_id uuid := auth.uid();
  state public.reader_sync_state%rowtype;
  op jsonb;
  receipt jsonb;
  entry jsonb;
  current_entry jsonb;
  current_tombstone jsonb;
  key text;
  kind text;
  op_id text;
  base_version bigint;
  current_version bigint;
  next_version bigint;
  acknowledged jsonb := '[]';
  conflicts jsonb := '[]';
  uploaded integer := 0;
  pending_count integer := 0;
begin
  if owner_id is null then raise insufficient_privilege using message='Authentication required'; end if;
  if jsonb_typeof(p_operations) is distinct from 'array' or jsonb_array_length(p_operations)>500
    or octet_length(p_operations::text)>2097152 then
    raise invalid_parameter_value using message='Invalid or oversized vocabulary operations';
  end if;
  if p_expected_revision is not null and p_expected_revision<0 then
    raise invalid_parameter_value using message='Invalid vocabulary revision';
  end if;
  insert into public.reader_sync_state(user_id) values(owner_id) on conflict(user_id) do nothing;
  select * into strict state from public.reader_sync_state where user_id=owner_id for update;
  if jsonb_typeof(state.vocabulary)<>'array' or jsonb_typeof(state.vocab_tombstones)<>'array' then
    raise data_exception using message='Vocabulary state requires repair';
  end if;
  -- Validate the entire batch before any changes; same word is coalesced by clients.
  if (select count(*) from jsonb_array_elements(p_operations)) <>
    (select count(distinct value->>'wordKey') from jsonb_array_elements(p_operations))
    or (select count(*) from jsonb_array_elements(p_operations)) <>
    (select count(distinct value->>'operationID') from jsonb_array_elements(p_operations)) then
    raise invalid_parameter_value using message='Coalesce multiple mutations for the same word';
  end if;
  for op in select value from jsonb_array_elements(p_operations) loop
    key := op->>'wordKey'; kind := op->>'kind'; op_id := op->>'operationID';
    if key is null or key='' or key<>public.vocabulary_word_key(key) or length(key)>1000
      or op_id is null or length(op_id) not between 1 and 128
      or kind is null or kind not in ('upsert','restore','delete') then
      raise invalid_parameter_value using message='Invalid vocabulary mutation';
    end if;
    select operation into receipt from public.reader_vocabulary_receipts where user_id=owner_id and operation_id=op_id;
    if found then
      if receipt<>op then raise invalid_parameter_value using message='Operation ID was reused with different contents'; end if;
      acknowledged := acknowledged || jsonb_build_array(op_id);
      continue;
    end if;
    pending_count := pending_count+1;
    select value into current_entry from jsonb_array_elements(state.vocabulary) where public.vocabulary_word_key(value->>'word')=key;
    select value into current_tombstone from jsonb_array_elements(state.vocab_tombstones) where value->>'wordKey'=key;
    current_version := coalesce((current_tombstone->>'version')::bigint,(current_entry->>'cloudVersion')::bigint,0);
    base_version := coalesce((op->>'baseVersion')::bigint,0);
    if base_version<>current_version or (current_tombstone is not null and kind='upsert')
      or (kind='restore' and current_tombstone is null) then
      conflicts := conflicts || jsonb_build_array(key);
    end if;
    if kind<>'delete' and (jsonb_typeof(op->'entry') is distinct from 'object'
      or public.vocabulary_word_key(op->'entry'->>'word') is distinct from key
      or nullif(btrim(op->'entry'->>'meaning'),'') is null) then
      raise invalid_parameter_value using message='Invalid vocabulary entry';
    end if;
  end loop;
  if pending_count>0 and (p_expected_revision is null or p_expected_revision<>state.vocab_revision or jsonb_array_length(conflicts)>0) then
    return jsonb_build_object('userID',owner_id,'vocabulary',state.vocabulary,'revision',state.vocab_revision,
      'acknowledgedOperationIDs',acknowledged,'tombstones',state.vocab_tombstones,
      'uploadedCount',0,'conflict',true,'conflictingWordKeys',conflicts);
  end if;
  if pending_count>0 then
    next_version := state.vocab_revision+1;
    for op in select value from jsonb_array_elements(p_operations) loop
      op_id:=op->>'operationID'; key:=op->>'wordKey'; kind:=op->>'kind';
      if exists(select 1 from public.reader_vocabulary_receipts where user_id=owner_id and operation_id=op_id) then continue; end if;
      state.vocabulary:=coalesce((select jsonb_agg(value) from jsonb_array_elements(state.vocabulary)
        where public.vocabulary_word_key(value->>'word')<>key),'[]');
      state.vocab_tombstones:=coalesce((select jsonb_agg(value) from jsonb_array_elements(state.vocab_tombstones)
        where value->>'wordKey'<>key),'[]');
      if kind='delete' then
        state.vocab_tombstones:=state.vocab_tombstones || jsonb_build_array(jsonb_build_object('wordKey',key,'version',next_version,'deletedAt',now()));
      else
        -- Retain future fields and browser definition provenance unchanged.
        entry:=op->'entry' || jsonb_build_object('cloudVersion',next_version);
        state.vocabulary:=state.vocabulary || jsonb_build_array(entry);
        uploaded:=uploaded+1;
      end if;
      insert into public.reader_vocabulary_receipts(user_id,operation_id,operation) values(owner_id,op_id,op);
      acknowledged:=acknowledged || jsonb_build_array(op_id);
    end loop;
    update public.reader_sync_state set vocabulary=state.vocabulary,vocab_tombstones=state.vocab_tombstones,
      vocab_revision=next_version,updated_at=now() where user_id=owner_id returning * into strict state;
  end if;
  return jsonb_build_object('userID',owner_id,'vocabulary',state.vocabulary,'revision',state.vocab_revision,
    'acknowledgedOperationIDs',acknowledged,'tombstones',state.vocab_tombstones,
    'uploadedCount',uploaded,'conflict',false,'conflictingWordKeys','[]'::jsonb);
end;
$$;
revoke all on function reader_private.sync_reader_vocabulary_v2(bigint,jsonb) from public, anon;
grant execute on function reader_private.sync_reader_vocabulary_v2(bigint,jsonb) to authenticated;
create or replace function public.sync_reader_vocabulary_v2(p_expected_revision bigint default null,p_operations jsonb default '[]')
returns jsonb language sql security invoker set search_path = '' as $$
  select reader_private.sync_reader_vocabulary_v2(p_expected_revision,p_operations);
$$;
revoke all on function public.sync_reader_vocabulary_v2(bigint,jsonb) from public, anon;
grant execute on function public.sync_reader_vocabulary_v2(bigint,jsonb) to authenticated;
commit;
