"""Run against isolated PG via PGHOST/PGPORT, never production."""
import os, subprocess, time
assert os.environ.get('READER_DELTA_ISOLATED_TEST') == '1' and os.environ.get('PGHOST','').startswith('/tmp/reader-delta-'), 'isolated test cluster required'
def run(sql):
 return subprocess.run(['psql','postgres','-v','ON_ERROR_STOP=1','-Atc',sql],capture_output=True,text=True,check=True).stdout
uid='55555555-5555-5555-5555-555555555555'
run(f"insert into reader_delta.accounts(user_id) values('{uid}') on conflict do nothing")
prefix=f"set test.uid='{uid}';"
one=prefix+'''begin; select public.reader_delta_push('[{"operationID":"concurrent-1","entityType":"answer_event","entityID":"c1","baseVersion":0,"payload":1}]'); select pg_sleep(1); commit;'''
two=prefix+'''select public.reader_delta_push('[{"operationID":"concurrent-2","entityType":"answer_event","entityID":"c2","baseVersion":0,"payload":2}]');'''
a=subprocess.Popen(['psql','postgres','-v','ON_ERROR_STOP=1','-Atc',one],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
time.sleep(.2)
t=time.monotonic(); result=run(two); elapsed=time.monotonic()-t
out,err=a.communicate(); assert a.returncode==0,err
assert elapsed>.5, 'second writer failed to wait for commit lock'
rows=run(f"select change->>'entityID' from reader_delta.changes where user_id='{uid}' order by cursor").splitlines()
assert rows==['c1','c2'],rows
print(f'Concurrent transaction lock and commit order PASS; second writer waited {elapsed:.3f}s')
