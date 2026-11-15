"""Create and destroy an isolated PostgreSQL cluster; no production connections."""
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
bin_dir = pathlib.Path(os.environ.get('PG_BIN', '/opt/homebrew/opt/postgresql@17/bin'))
if not (bin_dir / 'initdb').exists():
    raise SystemExit('Set PG_BIN to a PostgreSQL bin directory containing initdb and pg_ctl')
work = pathlib.Path(tempfile.mkdtemp(prefix='reader-delta-', dir='/tmp'))
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
env = dict(os.environ, PGHOST=str(work), PGPORT=str(port), PGDATABASE='postgres', READER_DELTA_ISOLATED_TEST='1')
log_dir = root / 'work' / 'reader-delta-postgres-evidence'
log_dir.mkdir(parents=True, exist_ok=True)
started = False

def run(args, log, **kwargs):
    completed = subprocess.run([str(x) for x in args], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    log.write(completed.stdout)
    log.flush()
    if completed.returncode:
        raise RuntimeError(completed.stdout)

try:
    with (log_dir / 'setup.log').open('w') as log:
        run([bin_dir/'initdb','-D',work/'data','-A','trust'],log)
        run([bin_dir/'pg_ctl','-D',work/'data','-o',f'-p {port} -k {work} -h 127.0.0.1','-l',work/'server.log','start'],log)
        started = True
        run([bin_dir/'psql','-v','ON_ERROR_STOP=1','-c',"create schema auth; create role authenticated; create role anon; alter default privileges in schema public grant execute on functions to anon; create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.uid',true),'')::uuid $$; create table public.reader_sync_state(user_id uuid primary key,quiz_progress jsonb,encrypted_ai_key jsonb,vocab_tombstones jsonb,vocabulary jsonb,favorites jsonb,reading_positions jsonb,completion_records jsonb,preferences jsonb);"],log)
    for name in ['reader-delta-sql.sql','reader-delta-sql-scale.sql','reader-delta-sql-faults.sql','reader-delta-production-import.sql','reader-delta-sql-concurrency.py']:
        with (log_dir / (name+'.log')).open('w') as log:
            run([bin_dir/'psql','-v','ON_ERROR_STOP=1','-c','drop schema if exists reader_delta cascade; truncate public.reader_sync_state;','-f','supabase/reader-delta-sync.sql'],log)
            if name.endswith('.py'):
                run(['python3',root/'tests'/name],log)
            else:
                run([bin_dir/'psql','-v','ON_ERROR_STOP=1','-f',root/'tests'/name],log)
        print(name+': PASS')
    print('Evidence: '+str(log_dir))
finally:
    if started:
        subprocess.run([str(bin_dir/'pg_ctl'),'-D',str(work/'data'),'-m','immediate','stop'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    shutil.rmtree(work)
