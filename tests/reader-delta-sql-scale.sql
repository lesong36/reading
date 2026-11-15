\set ON_ERROR_STOP on
\timing on
set test.uid='22222222-2222-2222-2222-222222222222';
insert into reader_delta.accounts(user_id,cursor) values('22222222-2222-2222-2222-222222222222',10000) on conflict(user_id) do update set cursor=10000;
insert into reader_delta.changes select '22222222-2222-2222-2222-222222222222', n,jsonb_build_object('cursor',n,'entityType','answer_event','entityID',n,'payload',jsonb_build_object('answer',2)) from generate_series(1,10000) n on conflict do nothing;
select public.reader_delta_push('[{"operationID":"scale-10000","entityType":"answer_event","entityID":"scale-10000","baseVersion":0,"payload":{"answer":3}}]');
select octet_length('[{"operationID":"scale-10000","entityType":"answer_event","entityID":"scale-10000","baseVersion":0,"payload":{"answer":3}}]') request_bytes,public.reader_delta_pull(null,10000,50) response,octet_length(public.reader_delta_pull(null,10000,50)::text) response_bytes;
insert into reader_delta.changes select '22222222-2222-2222-2222-222222222222', n,jsonb_build_object('cursor',n,'entityType','answer_event','entityID',n,'payload',jsonb_build_object('answer',2)) from generate_series(10002,100000) n on conflict do nothing;
update reader_delta.accounts set cursor=100000 where user_id=auth.uid();
select public.reader_delta_push('[{"operationID":"scale-100000","entityType":"answer_event","entityID":"scale-100000","baseVersion":0,"payload":{"answer":3}}]');
select octet_length('[{"operationID":"scale-100000","entityType":"answer_event","entityID":"scale-100000","baseVersion":0,"payload":{"answer":3}}]') request_bytes,public.reader_delta_pull(null,100000,50) response,octet_length(public.reader_delta_pull(null,100000,50)::text) response_bytes;

select jsonb_build_object('p_operations',jsonb_build_array(jsonb_build_object('operationID','scale-100000','entityType','answer_event','entityID','scale-100000','baseVersion',0,'payload',jsonb_build_object('answer',3)))) request_body,
 octet_length(jsonb_build_object('p_operations',jsonb_build_array(jsonb_build_object('operationID','scale-100000','entityType','answer_event','entityID','scale-100000','baseVersion',0,'payload',jsonb_build_object('answer',3))))::text) full_request_bytes;
explain (analyze,buffers) select change from reader_delta.changes where user_id=auth.uid() and cursor>100000 order by cursor limit 50;
