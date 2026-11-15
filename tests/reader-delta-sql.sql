\set ON_ERROR_STOP on
set test.uid='11111111-1111-1111-1111-111111111111';
select public.reader_delta_push('[{"operationID":"one","entityType":"answer_event","entityID":"a","baseVersion":0,"payload":{"answer":2}}]');
select public.reader_delta_push('[{"operationID":"one","entityType":"answer_event","entityID":"a","baseVersion":0,"payload":{"answer":2}}]');
do $$ begin if (select count(*) from reader_delta.changes)<>1 then raise exception 'duplicate write'; end if; end $$;
select public.reader_delta_pull();
insert into reader_delta.changes select '11111111-1111-1111-1111-111111111111', n, jsonb_build_object('cursor',n,'entityID',n,'payload',jsonb_build_object('answer',2)) from generate_series(2,10000) n;
analyze reader_delta.changes;
explain (analyze,buffers) select change from reader_delta.changes where user_id='11111111-1111-1111-1111-111111111111' and cursor>9999 order by cursor limit 50;
insert into reader_delta.changes select '11111111-1111-1111-1111-111111111111', n, jsonb_build_object('cursor',n,'entityID',n,'payload',jsonb_build_object('answer',2)) from generate_series(10001,100000) n;
analyze reader_delta.changes;
explain (analyze,buffers) select change from reader_delta.changes where user_id='11111111-1111-1111-1111-111111111111' and cursor>99999 order by cursor limit 50;
