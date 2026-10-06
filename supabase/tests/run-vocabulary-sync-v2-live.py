#!/usr/bin/env python3
"""Explicit live acceptance using two pre-created, dedicated synthetic users.

Never creates/deletes users, reads real user data, or deploys schema. Credentials
must be in a mode-600 temporary file outside the repository. API headers and
passwords go to curl through stdin, never its argv or printed output.
"""
import argparse
import concurrent.futures
import datetime
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = 'https://faeixgpjhnwpfzfkgjsu.supabase.co'


def save_private(path, value):
    fd, name = tempfile.mkstemp(prefix='vocab-live-private-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(value, file)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=pathlib.Path, required=True)
    parser.add_argument('--proxy', default='http://127.0.0.1:7897')
    parser.add_argument('--auth-only', action='store_true')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    secret_file = args.credentials.resolve()
    if ROOT in secret_file.parents or stat.S_IMODE(secret_file.stat().st_mode) & 0o077:
        parser.error('Credentials require an outside-repository mode-600 file')
    context = json.loads(secret_file.read_text())
    accounts = context['accounts']
    run_id = context['runID']
    assert re.fullmatch(r'vocab-audit-20261007-[a-z0-9]+', run_id)
    assert len(accounts) == 2 and len({item['id'] for item in accounts}) == 2
    assert all(item['email'].startswith(run_id + '-') and item['email'].endswith('@example.com') for item in accounts)
    source = (ROOT/'mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift').read_text()
    key = re.search(r'sb_publishable_[A-Za-z0-9_-]+', source).group()
    evidence = []

    def request(method, path, body=None, token=None, headers=None):
        config = ['header = ' + json.dumps('apikey: ' + key)]
        if token:
            config.append('header = ' + json.dumps('Authorization: Bearer ' + token))
        if body is not None:
            config += ['header = "Content-Type: application/json"',
                       'data = ' + json.dumps(json.dumps(body, ensure_ascii=True))]
        for name, value in (headers or {}).items():
            config.append('header = ' + json.dumps(name + ': ' + value))
        result = subprocess.run(['curl', '-sS', '--max-time', '30', '--proxy', args.proxy,
                                 '--config', '-', '-X', method, '-w', '\n%{http_code}', BASE + path],
                                input='\n'.join(config) + '\n', text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError('Live transport failed (curl exit %s)' % result.returncode)
        raw, status = result.stdout.rsplit('\n', 1)
        try:
            data = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            raise RuntimeError('Live endpoint returned invalid JSON (HTTP %s)' % status) from None
        return int(status), data

    def passed(name):
        evidence.append({'check': name, 'status': 'passed'})
        print('PASS ' + name, flush=True)

    # Actual GoTrue password grants: credentials are never mocked JWT claims.
    for account in accounts:
        status, response = request('POST', '/auth/v1/token?grant_type=password',
                                   {'email': account['email'], 'password': account['password']})
        if status != 200:
            raise RuntimeError('Synthetic password sign-in failed: HTTP %s code %s' %
                               (status, response.get('error_code') if isinstance(response, dict) else None))
        assert response['user']['id'] == account['id']
        account['session'] = response
    save_private(secret_file, context)
    passed('Two dedicated synthetic users authenticate through real GoTrue password grants')
    if args.auth_only:
        if args.output:
            args.output.write_text(json.dumps({'runID': run_id, 'checks': evidence}, indent=2))
        return

    a, b = accounts
    token_a, token_b = a['session']['access_token'], b['session']['access_token']

    def rpc(token, owner, revision=None, operations=None):
        status, result = request('POST', '/rest/v1/rpc/sync_reader_vocabulary_v2',
                                 {'p_expected_revision': revision, 'p_operations': operations or []}, token)
        if status != 200:
            raise RuntimeError('v2 RPC failed: HTTP %s code %s' %
                               (status, result.get('code') if isinstance(result, dict) else None))
        assert isinstance(result, dict) and result['userID'] == owner
        assert isinstance(result['revision'], int) and result['revision'] >= 0
        assert isinstance(result['vocabulary'], list) and isinstance(result['tombstones'], list)
        assert isinstance(result['acknowledgedOperationIDs'], list)
        assert len(set(result['acknowledgedOperationIDs'])) == len(result['acknowledgedOperationIDs'])
        return result

    def operation(word, kind='upsert', base=0, meaning='公开合成验收词', extra=None):
        value = {'operationID': str(uuid.uuid4()), 'kind': kind, 'wordKey': word, 'baseVersion': base}
        if kind != 'delete':
            value['entry'] = {'word': word, 'meaning': meaning, 'addedAt': '2026-10-07T00:00:00Z',
                              'future': {'runID': run_id, 'preserved': True}}
            value['entry'].update(extra or {})
        return value

    snap_a = rpc(token_a, a['id'])
    snap_b = rpc(token_b, b['id'])
    assert snap_a['vocabulary'] == [] and snap_b['vocabulary'] == []
    passed('Real RPC initializes/reads both fixture owners and validates response structure')

    # Concurrent callers use the same original global revision. The losing
    # caller retries that exact immutable operation against the returned revision.
    words = [run_id + '-alpha', run_id + '-beta']
    ops = [operation(word) for word in words]
    barrier = threading.Barrier(2)
    def simultaneous(op):
        barrier.wait(timeout=10)
        return rpc(token_a, a['id'], snap_a['revision'], [op])
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(simultaneous, ops))
    assert sum(not item['conflict'] for item in results) == 1
    assert sum(item['conflict'] for item in results) == 1
    for op, result in zip(ops, results):
        if result['conflict']:
            assert result['conflictingWordKeys'] == []
            result = rpc(token_a, a['id'], result['revision'], [op])
        assert not result['conflict'] and result['acknowledgedOperationIDs'] == [op['operationID']]
    snap_a = rpc(token_a, a['id'])
    assert {item['word'] for item in snap_a['vocabulary']} == set(words)
    passed('Two real concurrent REST callers retain both additions after revision conflict retry')

    # Lost acknowledgement: repeat an operation after the simulated client
    # discards a committed response. Receipt identity prevents another mutation.
    duplicate = rpc(token_a, a['id'], 0, [ops[0]])
    assert duplicate['revision'] == snap_a['revision'] and duplicate['uploadedCount'] == 0
    assert duplicate['acknowledgedOperationIDs'] == [ops[0]['operationID']]
    passed('Lost-ack replay keeps immutable operation ID, revision and exact acknowledgement')

    alpha = next(item for item in snap_a['vocabulary'] if item['word'] == words[0])
    edited = operation(words[0], base=alpha['cloudVersion'], meaning='网页校正合成释义',
                       extra={'definitionProvider': 'public-fixture-web', 'definitionCheckedAt': '2026-10-07T00:00:01Z'})
    fresh = rpc(token_a, a['id'], snap_a['revision'], [edited])
    assert not fresh['conflict']
    stale = operation(words[0], base=alpha['cloudVersion'], meaning='旧释义禁止覆盖')
    rejected = rpc(token_a, a['id'], fresh['revision'], [stale])
    assert rejected['conflict'] and rejected['conflictingWordKeys'] == [words[0]]
    restored_alpha = next(item for item in rejected['vocabulary'] if item['word'] == words[0])
    assert restored_alpha['meaning'] == '网页校正合成释义'
    assert restored_alpha['definitionProvider'] == 'public-fixture-web' and restored_alpha['future']['preserved']
    passed('Cross-client definition edit preserves metadata and rejects stale same-word overwrite')

    removed = operation(words[0], 'delete', restored_alpha['cloudVersion'])
    deleted = rpc(token_a, a['id'], fresh['revision'], [removed])
    assert not deleted['conflict'] and all(item['word'] != words[0] for item in deleted['vocabulary'])
    tombstone = next(item for item in deleted['tombstones'] if item['wordKey'] == words[0])
    implicit = rpc(token_a, a['id'], deleted['revision'], [operation(words[0], base=tombstone['version'])])
    assert implicit['conflict']
    restore = rpc(token_a, a['id'], deleted['revision'], [operation(words[0], 'restore', tombstone['version'])])
    assert not restore['conflict'] and not restore['tombstones']
    assert any(item['word'] == words[0] for item in restore['vocabulary'])
    passed('Versioned tombstone blocks implicit resurrection and permits explicit restore')

    assert rpc(token_b, b['id'])['vocabulary'] == []
    status, visible = request('GET', '/rest/v1/reader_sync_state?select=user_id,vocabulary&user_id=eq.' + a['id'], token=token_b)
    assert status == 200 and visible == []
    status, changed = request('PATCH', '/rest/v1/reader_sync_state?user_id=eq.' + a['id'],
                              {'favorites': ['cross-owner-denied']}, token_b,
                              {'Prefer': 'return=representation'})
    assert status == 200 and changed == []
    status, denied = request('POST', '/rest/v1/rpc/sync_reader_vocabulary_v2',
                             {'p_expected_revision': None, 'p_operations': []})
    assert status in (401, 403)
    passed('Two real JWT owners cannot read/update each other; anonymous RPC is denied')

    # Legacy writes target only the current synthetic account.
    status, result = request('PATCH', '/rest/v1/reader_sync_state?user_id=eq.' + a['id'],
                             {'vocabulary': []}, token_a)
    assert status in (401, 403) and result['code'] == '42501'
    status, result = request('POST', '/rest/v1/reader_sync_state?on_conflict=user_id',
                             {'user_id': a['id'], 'vocabulary': []}, token_a,
                             {'Prefer': 'resolution=merge-duplicates,return=representation'})
    assert status in (401, 403) and result['code'] == '42501'
    passed('Actual Data API blocks legacy full-array PATCH and upsert')

    status, result = request('GET', '/rest/v1/reader_sync_state?select=user_id&limit=0',
                             token=token_a, headers={'Accept-Profile': 'reader_private'})
    assert status == 406 and result['code'] == 'PGRST106'
    status, result = request('GET', '/rest/v1/reader_vocabulary_receipts?select=operation_id&limit=0', token=token_a)
    assert status in (401, 403) and result['code'] == '42501'
    status, result = request('GET', '/rest/v1/reader_vocabulary_upgrade_backup?select=user_id&limit=0', token=token_a)
    assert status in (401, 403) and result['code'] == '42501'
    passed('Actual REST excludes private schema and prevents receipt/backup reads')

    # Exact VocabMaster non-vocabulary payload against the existing production
    # learning guard. The event is synthetic; no API vault fields are fetched.
    profile_id = 'reader_' + a['id']
    master = {'version': 3, 'appState': {'version': 1, 'currentUserId': profile_id,
              'users': {profile_id: {'id': profile_id, 'words': [{'id': run_id + '-learning',
                  'english_word': 'fixture', 'source': 'reading', 'correctCount': 0,
                  'incorrectCount': 0, 'consecutiveCorrect': 0}],
                  'studyEvents': [{'id': run_id + '-answer', 'wordId': run_id + '-learning',
                      'result': 'correct', 'durableVersion': '3',
                      'at': datetime.datetime.now(datetime.timezone.utc).isoformat()}]}}}}
    payload = {'user_id': a['id'], 'vocab_master_progress': master,
               'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    for _ in range(2):
        status, result = request('POST', '/rest/v1/reader_sync_state?on_conflict=user_id&select=user_id,vocab_master_progress', payload,
                                 token_a, {'Prefer': 'resolution=merge-duplicates,return=representation'})
        assert status == 200
        profile = result[0]['vocab_master_progress']['appState']['users'][profile_id]
        assert profile['words'][0]['correctCount'] == 1
        assert len(profile['studyEvents']) == 1
    after_progress = rpc(token_a, a['id'])
    assert after_progress['vocabulary'] == restore['vocabulary'] and after_progress['revision'] == restore['revision']
    passed('Real VocabMaster non-vocabulary upsert coexists with learning event replay guard and v2 vocabulary')

    # Persistent outbox simulation at the transport boundary: persist original
    # operations while offline, start a separate process to reload the file,
    # then deliver/replay unchanged IDs to the real RPC. Native persistence/UI
    # is a separate required acceptance lane, not proven by this check alone.
    queued = operation(run_id + '-offline')
    fd, queue_name = tempfile.mkstemp(prefix='vocab-live-outbox-', dir=secret_file.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump({'revision': after_progress['revision'], 'operations': [queued]}, file)
        loaded = subprocess.check_output(['python3', '-c',
            'import json,sys; q=json.load(open(sys.argv[1])); print(json.dumps(q))', queue_name], text=True)
        queue = json.loads(loaded)
        delivered = rpc(token_a, a['id'], queue['revision'], queue['operations'])
        assert not delivered['conflict'] and delivered['acknowledgedOperationIDs'] == [queued['operationID']]
        replayed = rpc(token_a, a['id'], queue['revision'], queue['operations'])
        assert replayed['revision'] == delivered['revision'] and replayed['uploadedCount'] == 0
        passed('Restarted transport outbox delivers and replays the same durable operation to real RPC')
    finally:
        os.unlink(queue_name)

    summary = {'runID': run_id, 'project': 'faeixgpjhnwpfzfkgjsu', 'checks': evidence,
               'fixture_account_ids': [a['id'], b['id']], 'production_mutations': 'dedicated fixture records only'}
    if args.output:
        args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
