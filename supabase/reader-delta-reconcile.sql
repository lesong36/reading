-- Confirm a stale operation only when its entire intended state is already present.
-- The original conflict receipt remains immutable for audit and idempotent retry.
create table if not exists reader_delta.reconciliations(user_id uuid not null, operation_id text not null, acknowledgement jsonb not null, primary key(user_id,operation_id));
alter table reader_delta.reconciliations enable row level security;
create or replace function public.reader_delta_reconcile(p_operation_ids jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); id text; r reader_delta.receipts%rowtype; e reader_delta.entities%rowtype; acknowledgement jsonb; results jsonb:='[]';
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_operation_ids is null or jsonb_typeof(p_operation_ids)<>'array' or jsonb_array_length(p_operation_ids)>50 or octet_length(p_operation_ids::text)>20000 then raise exception 'invalid reconciliation batch'; end if;
 perform 1 from reader_delta.accounts where user_id=u for update;
 for id in select jsonb_array_elements_text(p_operation_ids) loop
  if length(id)>200 then raise exception 'invalid operation ID'; end if;
  select x.acknowledgement into acknowledgement from reader_delta.reconciliations x where x.user_id=u and x.operation_id=id;
  if found then results:=results||jsonb_build_array(acknowledgement); continue; end if;
  select * into r from reader_delta.receipts where user_id=u and operation_id=id;
  if not found or r.receipt->>'status'<>'conflict' or r.operation->>'entityType'='answer_event' then continue; end if;
  select * into e from reader_delta.entities where user_id=u and entity_type=r.operation->>'entityType' and entity_id=r.operation->>'entityID';
  if found and e.deleted=(r.operation->>'kind'='delete') and coalesce(e.payload,'null'::jsonb) is not distinct from coalesce(r.operation->'payload','null'::jsonb) then
   acknowledgement:=jsonb_build_object('operationID',id,'status','equivalent','version',e.version);
   insert into reader_delta.reconciliations values(u,id,acknowledgement);
   results:=results||jsonb_build_array(acknowledgement);
  end if;
 end loop;
 return jsonb_build_object('acknowledgements',results);
end $$;
revoke all on function public.reader_delta_reconcile(jsonb) from public,anon;
grant execute on function public.reader_delta_reconcile(jsonb) to authenticated;
