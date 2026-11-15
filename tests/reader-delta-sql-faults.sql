\set ON_ERROR_STOP on
set test.uid='33333333-3333-3333-3333-333333333333';
do $$ begin
 begin perform public.reader_delta_push(null); raise exception 'accepted NULL'; exception when others then if sqlerrm='accepted NULL' then raise; end if; end;
 begin perform public.reader_delta_pull(null,null,50); raise exception 'accepted NULL'; exception when others then if sqlerrm='accepted NULL' then raise; end if; end;
end $$;
select public.reader_delta_push('[{"operationID":"f1","entityType":"favorite","entityID":"a","baseVersion":0,"payload":true}]');
select public.reader_delta_push('[{"operationID":"f2","entityType":"favorite","entityID":"a","baseVersion":1,"kind":"delete"}]');
do $$ declare r jsonb; begin
 r:=public.reader_delta_push('[{"operationID":"f3","entityType":"favorite","entityID":"a","baseVersion":2,"payload":true}]');
 if r->'acknowledgements'->0->>'status'<>'conflict' then raise exception 'implicit restore'; end if;
end $$;
select public.reader_delta_push('[{"operationID":"f4","entityType":"favorite","entityID":"a","baseVersion":2,"kind":"restore","payload":true}]');
set test.uid='44444444-4444-4444-4444-444444444444';
do $$ begin if jsonb_array_length(public.reader_delta_pull()->'changes')<>0 then raise exception 'cross-account leak'; end if; end $$;
insert into public.reader_sync_state(user_id,quiz_progress) values(auth.uid(),'{"article":{"answers":{"q":2}}}');
select public.reader_delta_activate();
select public.reader_delta_legacy_manifest();
select public.reader_delta_push('[{"operationID":"import-q","entityType":"quiz_answers","entityID":"[\"article\",\"q\"]","baseVersion":0,"payload":2},{"operationID":"import-meta","entityType":"quiz_meta","entityID":"article","baseVersion":0,"payload":{}}]');
select public.reader_delta_stage_legacy('quiz_progress','article','{"answers":{"q":2}}');
select public.reader_delta_finish_migration(public.reader_delta_legacy_manifest());
do $$ begin
 begin update public.reader_sync_state set quiz_progress='{}' where user_id=auth.uid(); raise exception 'old client accepted'; exception when others then if sqlerrm='old client accepted' then raise; end if; end;
end $$;
set test.uid='33333333-3333-3333-3333-333333333333';
do $$ declare r jsonb; begin
 r:=public.reader_delta_get('[{"entityType":"favorite","entityID":"a"}]');
 if r->'entities'->0->>'version'<>'3' or r->'entities'->0->>'deleted'<>'false' then raise exception 'targeted conflict get failed'; end if;
end $$;
set test.uid='44444444-4444-4444-4444-444444444444';
do $$ declare r jsonb; begin
 r:=public.reader_delta_get('[{"entityType":"favorite","entityID":"a"}]');
 if r->'entities'->0->>'version'<>'0' then raise exception 'targeted get leaked owner entity'; end if;
end $$;

set test.uid='66666666-6666-6666-6666-666666666666';
insert into public.reader_sync_state(user_id,encrypted_ai_key) values(auth.uid(),'{"iv":"abc","ciphertext":"opaque","salt":"salt"}');
select public.reader_delta_activate();
do $$ declare r jsonb; begin
 r:=public.reader_delta_legacy_page('encrypted_ai_key');
 if jsonb_array_length(r->'items')<>1 or r->'items'->0->>'id'<>'singleton' or r->'items'->0->'payload'->>'ciphertext'<>'opaque' then raise exception 'encrypted envelope fragmented'; end if;
 if (select value->>'count' from jsonb_array_elements(public.reader_delta_legacy_manifest()) where value->>'field'='encrypted_ai_key')<>'1' then raise exception 'encrypted envelope count wrong'; end if;
end $$;
select public.reader_delta_push('[{"operationID":"import-key","entityType":"encrypted_ai_key","entityID":"default","baseVersion":0,"payload":{"iv":"abc","ciphertext":"opaque","salt":"salt"}}]');
select public.reader_delta_stage_legacy('encrypted_ai_key','singleton','{"iv":"abc","ciphertext":"opaque","salt":"salt"}');
select public.reader_delta_finish_migration(public.reader_delta_legacy_manifest());
set test.uid='77777777-7777-7777-7777-777777777777';
insert into public.reader_sync_state(user_id,vocab_tombstones) values(auth.uid(),'[{"wordKey":"Removed","version":9,"deletedAt":"2026-11-16"}]');
select public.reader_delta_activate();
do $$ begin
 if (select value->>'count' from jsonb_array_elements(public.reader_delta_legacy_manifest()) where value->>'field'='vocab_tombstones')<>'1' then raise exception 'tombstone missing manifest'; end if;
end $$;
select public.reader_delta_push('[{"operationID":"import-delete","entityType":"vocabulary","entityID":"removed","baseVersion":0,"kind":"delete","payload":null}]');
select public.reader_delta_stage_legacy('vocab_tombstones','1','{"wordKey":"Removed","version":9,"deletedAt":"2026-11-16"}');
select public.reader_delta_finish_migration(public.reader_delta_legacy_manifest());
do $$ declare r jsonb; begin
 r:=public.reader_delta_push('[{"operationID":"stale-resurrection","entityType":"vocabulary","entityID":"removed","baseVersion":1,"kind":"upsert","payload":{"word":"removed"}}]');
 if r->'acknowledgements'->0->>'status'<>'conflict' then raise exception 'migrated tombstone resurrected'; end if;
end $$;
