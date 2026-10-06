-- Disposable PostgreSQL/Supabase test DB only. Requires the v2 schema and two
-- fixture auth.users IDs below; transaction rollback preserves the test DB.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$
declare r jsonb; again jsonb; operation jsonb; revision bigint;
begin
  r:=public.sync_reader_vocabulary_v2(null,'[]');
  if r->>'userID'<>'00000000-0000-0000-0000-000000000001' then raise exception 'wrong owner'; end if;
  if (r->>'conflict')::boolean then raise exception 'empty snapshot conflict'; end if;
  revision:=(r->>'revision')::bigint;
  operation:=jsonb_build_array(jsonb_build_object('operationID','fixture-add-alpha','kind','upsert','wordKey','alpha',
    'entry',jsonb_build_object('word','alpha','meaning','甲','future',jsonb_build_object('note','preserved'))));
  r:=public.sync_reader_vocabulary_v2(revision,operation);
  if (r->>'uploadedCount')::int<>1 or jsonb_array_length(r->'acknowledgedOperationIDs')<>1 then raise exception 'missing ack'; end if;
  if r->'vocabulary'->0->'future'->>'note'<>'preserved' then raise exception 'future field dropped'; end if;
  again:=public.sync_reader_vocabulary_v2(revision,operation);
  if again->>'revision'<>r->>'revision' or (again->>'uploadedCount')::int<>0 then raise exception 'duplicate operation was reapplied'; end if;
  begin
    perform public.sync_reader_vocabulary_v2((r->>'revision')::bigint,jsonb_set(operation,'{0,entry,meaning}','"wrong"'));
    raise exception 'reused operation ID accepted';
  exception when invalid_parameter_value then null; end;
  again:=public.sync_reader_vocabulary_v2(revision,'[{"operationID":"fixture-add-beta","kind":"upsert","wordKey":"beta","entry":{"word":"beta","meaning":"乙"}}]');
  if not (again->>'conflict')::boolean or jsonb_array_length(again->'vocabulary')<>1 then raise exception 'stale revision overwrote state'; end if;
  again:=public.sync_reader_vocabulary_v2((r->>'revision')::bigint,'[{"operationID":"fixture-stale-alpha","kind":"upsert","wordKey":"alpha","entry":{"word":"alpha","meaning":"wrong"}}]');
  if again->'conflictingWordKeys'<> '["alpha"]'::jsonb then raise exception 'entry conflict not protected'; end if;
  r:=public.sync_reader_vocabulary_v2((r->>'revision')::bigint,jsonb_build_array(jsonb_build_object('operationID','fixture-delete-alpha','kind','delete','wordKey','alpha','baseVersion',(r->'vocabulary'->0->>'cloudVersion')::bigint)));
  if jsonb_array_length(r->'vocabulary')<>0 or jsonb_array_length(r->'tombstones')<>1 then raise exception 'delete failed'; end if;
  again:=public.sync_reader_vocabulary_v2((r->>'revision')::bigint,jsonb_build_array(jsonb_build_object('operationID','fixture-stale-restore','kind','upsert','wordKey','alpha','baseVersion',(r->'tombstones'->0->>'version')::bigint,'entry',jsonb_build_object('word','alpha','meaning','复原'))));
  if not (again->>'conflict')::boolean then raise exception 'implicit restore accepted'; end if;
  r:=public.sync_reader_vocabulary_v2((r->>'revision')::bigint,jsonb_build_array(jsonb_build_object('operationID','fixture-explicit-restore','kind','restore','wordKey','alpha','baseVersion',(r->'tombstones'->0->>'version')::bigint,'entry',jsonb_build_object('word','alpha','meaning','复原','definitionProvider','fixture'))));
  if jsonb_array_length(r->'vocabulary')<>1 or jsonb_array_length(r->'tombstones')<>0 then raise exception 'explicit restore failed'; end if;
  begin
    update public.reader_sync_state set vocabulary='[]' where user_id=auth.uid();
    raise exception 'legacy full-array update bypassed protection';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.reader_sync_state(user_id,vocabulary) values(auth.uid(),'[]') on conflict(user_id) do update set vocabulary=excluded.vocabulary;
    raise exception 'legacy upsert bypassed protection';
  exception when insufficient_privilege then null; end;
  update public.reader_sync_state set favorites='["fixture-article"]' where user_id=auth.uid();
  if not found then raise exception 'unrelated reader updates were broken'; end if;
  insert into public.reader_sync_state(user_id,favorites,preferences,reading_positions,updated_at)
    values(auth.uid(),'["fixture-upsert"]','{"theme":"fixture"}','{}',now())
    on conflict(user_id) do update set favorites=excluded.favorites,preferences=excluded.preferences,
      reading_positions=excluded.reading_positions,updated_at=excluded.updated_at;
  if (select favorites from public.reader_sync_state where user_id=auth.uid())<>'["fixture-upsert"]'::jsonb then
    raise exception 'unrelated reader upsert was broken'; end if;
end;
$$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
do $$ declare r jsonb; begin
  r:=public.sync_reader_vocabulary_v2(null,'[]');
  if jsonb_array_length(r->'vocabulary')<>0 then raise exception 'another account data leaked'; end if;
  if exists(select 1 from public.reader_sync_state where user_id<>'00000000-0000-0000-0000-000000000002') then raise exception 'cross-account RLS leak'; end if;
end; $$;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
  begin perform public.sync_reader_vocabulary_v2(null,'[]'); raise exception 'anonymous owner accepted';
  exception when insufficient_privilege then null; end;
end; $$;
rollback;
