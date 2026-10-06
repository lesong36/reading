#!/usr/bin/env python3
"""Run real transaction/RLS tests in a newly created, disposable local PG cluster.
No credentials, existing database, network server, containers or new packages.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile
import time
import datetime

parser = argparse.ArgumentParser()
parser.add_argument('--pg-bin', default='/opt/homebrew/opt/postgresql@17/bin', help='Existing PostgreSQL bin directory')
parser.add_argument('--production-learning-guard', action='store_true', help='Include metadata-only production learning trigger compatibility fixture')
args = parser.parse_args()
pg = pathlib.Path(args.pg_bin)
for tool in ('initdb', 'pg_ctl', 'psql'):
    if not (pg / tool).is_file():
        parser.error(f'Existing PostgreSQL tool missing: {pg / tool}; this runner never installs dependencies')
root = pathlib.Path(__file__).resolve().parents[2]
schema = (root / 'supabase/schema.sql').read_text()
legacy_schema = schema.split('-- Vocabulary protocol upgrade (keep this bootstrap')[0]
fixture_ids = [f'00000000-0000-0000-0000-{i:012d}' for i in (1,2,3)]
with tempfile.TemporaryDirectory(prefix='vocab-v2-pg-') as directory:
    work = pathlib.Path(directory)
    data = work / 'data'
    subprocess.run([str(pg/'initdb'), '-D', str(data), '-A', 'trust', '--no-locale', '-E', 'UTF8'], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([str(pg/'pg_ctl'), '-D', str(data), '-l', str(work/'postgres.log'), '-o', f"-h '' -k {work} -p 55479", '-w', 'start'], check=True, stdout=subprocess.DEVNULL)
    base = [str(pg/'psql'), '-h', str(work), '-p', '55479', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']
    def sql(value):
        result = subprocess.run(base, input=value, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout
    def rpc(body):
        query = "set role authenticated; select set_config('request.jwt.claim.sub','%s',false); select public.sync_reader_vocabulary_v2(%s,'%s'::jsonb);" % (fixture_ids[0], body[0], json.dumps(body[1]).replace("'", "''"))
        return json.loads(next(line for line in sql(query).splitlines() if line.startswith('{')))
    try:
        sql("create role anon; create role authenticated; create schema auth; create table auth.users(id uuid primary key,raw_user_meta_data jsonb default '{}'); create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$; grant usage on schema auth to authenticated,anon;" + legacy_schema)
        if args.production_learning_guard:
            sql((root/'supabase/tests/production-learning-guard-fixture.sql').read_text())
        for i, owner in enumerate(fixture_ids):
            sql("insert into auth.users(id,raw_user_meta_data) values('%s','{\"username\":\"fixture%d\"}');" % (owner,i))
        sql("grant all on public.reader_sync_state to authenticated; update public.reader_sync_state set vocabulary='[{\"word\":\" Bank \",\"meaning\":\"old\",\"timestamp\":1},{\"word\":\"bank\",\"meaning\":\"new\",\"timestamp\":2,\"future\":{\"keep\":true}},{\"word\":\"removed\",\"meaning\":\"gone\"}]',preferences='{\"deletedVocabKeys\":[\"removed\"]}' where user_id='%s';" % fixture_ids[2])
        # Demonstrate the protection regression against the old schema first.
        baseline = subprocess.run(base, input="begin; set role authenticated; select set_config('request.jwt.claim.sub','%s',true); do $$begin update public.reader_sync_state set vocabulary='[]' where user_id=auth.uid(); raise exception 'UNSAFE_OLD_ARRAY_WRITE_ACCEPTED'; end$$; rollback;" % fixture_ids[0], text=True,capture_output=True)
        assert baseline.returncode and 'UNSAFE_OLD_ARRAY_WRITE_ACCEPTED' in baseline.stderr
        print('PASS old schema reproduced unsafe full-array write')
        sql((root/'supabase/vocabulary-sync-v2.sql').read_text())
        sql("do $$begin if (select jsonb_array_length(vocabulary) from public.reader_sync_state where user_id='%s')<>1 then raise exception 'legacy normalization failed'; end if; if (select vocabulary->0->>'meaning' from public.reader_sync_state where user_id='%s')<>'new' then raise exception 'newest legacy entry lost'; end if; if (select jsonb_array_length(vocabulary) from public.reader_vocabulary_upgrade_backup where user_id='%s')<>3 then raise exception 'original upgrade backup missing'; end if; if public.vocabulary_word_key(E'\\tBANK\\n')<>'bank' then raise exception 'canonical key mismatch'; end if; end$$;" % (fixture_ids[2],fixture_ids[2],fixture_ids[2]))
        print('PASS legacy normalization, unknown metadata and private original backup')
        sql((root/'supabase/tests/vocabulary-sync-v2.sql').read_text())
        print('PASS SQL owner isolation, RLS, idempotency, conflicts, restoration, privilege protection and unrelated reader writes')
        revision = rpc(('null',[]))['revision']
        def operation(word):
            return [{'operationID':f'parallel-{word}', 'kind':'upsert','wordKey':word,'entry':{'word':word,'meaning':word}}]
        first_query = "begin; select set_config('application_name','vocab-v2-first',true); set role authenticated; select set_config('request.jwt.claim.sub','%s',true); select public.sync_reader_vocabulary_v2(%s,'%s'); select pg_sleep(1.5); commit;" % (fixture_ids[0],revision,json.dumps(operation('alpha')))
        first = subprocess.Popen(base+['-c',first_query],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        # Observe the live server transaction rather than relying on stdout
        # flushing. The second connection must start before this lock releases.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and first.poll() is None:
            if sql("select wait_event='PgSleep' from pg_stat_activity where application_name='vocab-v2-first';").strip() == 't':
                break
            time.sleep(0.01)
        else:
            raise AssertionError('First transaction was not observed holding its lock')
        assert first.poll() is None
        second = rpc((revision,operation('beta')))
        stdout, stderr = first.communicate(timeout=10)
        assert first.returncode==0, stderr
        first_result = json.loads(next(line for line in stdout.splitlines() if line.startswith('{')))
        assert not first_result['conflict']
        assert second['conflict'] and not second['conflictingWordKeys']
        second = rpc((second['revision'],operation('beta')))
        assert not second['conflict']
        final = rpc(('null',[]))
        assert {entry['word'] for entry in final['vocabulary']}=={'alpha','beta'}
        print('PASS two real concurrent connections retain both additions after bounded revision retry')
        # Rerunning the script cannot reset revisions, tombstones or receipt history.
        sql((root/'supabase/vocabulary-sync-v2.sql').read_text())
        assert rpc(('null',[]))['revision']==final['revision']
        print('PASS repeat deployment leaves committed vocabulary/revision unchanged')
        if args.production_learning_guard:
            # These are the exact non-vocabulary columns sent by VocabMaster.
            # Replay a durable learning event against the real captured trigger.
            profile_id = 'reader_' + fixture_ids[0]
            master = {'version': 3, 'appState': {'version': 1, 'currentUserId': profile_id,
                'users': {profile_id: {'id': profile_id, 'words': [{
                    'id': 'reading_fixture', 'english_word': 'fixture', 'source': 'reading',
                    'correctCount': 0, 'incorrectCount': 0, 'consecutiveCorrect': 0}],
                    'studyEvents': [{'id': 'fixture-answer-1', 'wordId': 'reading_fixture',
                        'result': 'correct', 'durableVersion': '3',
                        'at': datetime.datetime.now(datetime.timezone.utc).isoformat()}]}}}}
            payload = json.dumps(master).replace("'", "''")
            upsert = "set role authenticated; select set_config('request.jwt.claim.sub','%s',false); insert into public.reader_sync_state(user_id,vocab_master_progress,updated_at) values('%s','%s'::jsonb,now()) on conflict(user_id) do update set vocab_master_progress=excluded.vocab_master_progress,updated_at=excluded.updated_at;" % (fixture_ids[0],fixture_ids[0],payload)
            sql(upsert)
            sql(upsert)
            sql("do $$begin if (select count(*) from public.vocab_learning_events where user_id='%s' and event_id='fixture-answer-1')<>1 then raise exception 'learning replay duplicated'; end if; if (select (vocab_master_progress #>> '{appState,users,%s,words,0,correctCount}')::int from public.reader_sync_state where user_id='%s')<>1 then raise exception 'learning counter regression'; end if; end$$;" % (fixture_ids[0],profile_id,fixture_ids[0]))
            assert rpc(('null',[]))['vocabulary'] == final['vocabulary']
            assert rpc(('null',[]))['revision'] == final['revision']
            print('PASS production learning guard: VocabMaster column upsert, durable replay and vocabulary/version preservation')
            missing_owner = '00000000-0000-0000-0000-000000000004'
            sql("insert into auth.users(id,raw_user_meta_data) values('%s','{\"username\":\"fixture4\"}'); delete from public.reader_sync_state where user_id='%s';" % (missing_owner,missing_owner))
            initialized = sql("set role authenticated; select set_config('request.jwt.claim.sub','%s',false); select public.sync_reader_vocabulary_v2(null,'[]');" % missing_owner)
            initialized = json.loads(next(line for line in initialized.splitlines() if line.startswith('{')))
            assert initialized['userID'] == missing_owner and initialized['vocabulary'] == []
            sql("do $$begin if not exists(select 1 from public.vocab_sync_metadata where user_id='%s') then raise exception 'first-row learning initialization missing'; end if; end$$;" % missing_owner)
            print('PASS production learning guard: v2 missing reader-row initialization and learning metadata coexist')
    finally:
        subprocess.run([str(pg/'pg_ctl'),'-D',str(data),'-w','stop','-m','fast'],check=True,stdout=subprocess.DEVNULL)
print('Disposable PostgreSQL cluster stopped and removed')
