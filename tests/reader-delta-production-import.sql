\set ON_ERROR_STOP on
set test.uid='77777777-7777-4777-8777-777777777777';
set reader_migration.owner_id='77777777-7777-4777-8777-777777777777';
insert into public.reader_sync_state(user_id,quiz_progress,encrypted_ai_key,vocab_tombstones,vocabulary,favorites,reading_positions,completion_records,preferences) values(auth.uid(),'{"article":{"answers":{"q1":2},"submitted":false}}','{"iv":"original","ciphertext":"encrypted","salt":"salt"}','[{"wordKey":"gone","version":1}]','[{"word":"live"}]','["article"]','{"article":{"sentenceId":"s1"}}','{"article":{"completed":true}}','{"voiceProvider":"edge"}');
\i supabase/reader-delta-production-import.sql
\i supabase/reader-delta-production-import.sql
DO $$ begin
 if not exists(select 1 from reader_delta.accounts where user_id=auth.uid() and migration_verified) then raise exception 'migration not verified'; end if;
 if not exists(select 1 from reader_delta.entities where user_id=auth.uid() and entity_type='vocabulary' and entity_id='gone' and deleted) then raise exception 'missing tombstone'; end if;
 if (select count(*) from reader_delta.legacy_backup where user_id=auth.uid())<>1 then raise exception 'backup missing'; end if;
 if (select count(*) from reader_delta.migration_audit where user_id=auth.uid())<>8 then raise exception 'audit fields missing'; end if;
END $$;
