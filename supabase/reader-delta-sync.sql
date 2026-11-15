-- Reader protocol 3. Apply after schema.sql. No shared VocabMaster tables.
create schema if not exists reader_delta;
revoke all on schema reader_delta from public;
create table if not exists reader_delta.accounts(user_id uuid primary key, epoch text not null default gen_random_uuid()::text, cursor bigint not null default 0, migrated boolean not null default false);
create table if not exists reader_delta.entities(user_id uuid not null, entity_type text not null, entity_id text not null, version bigint not null, deleted boolean not null, payload jsonb, primary key(user_id,entity_type,entity_id));
create table if not exists reader_delta.changes(user_id uuid not null, cursor bigint not null, change jsonb not null, primary key(user_id,cursor));
create table if not exists reader_delta.receipts(user_id uuid not null, operation_id text not null, operation jsonb not null, receipt jsonb not null, primary key(user_id,operation_id));
create table if not exists reader_delta.legacy_backup(user_id uuid primary key, snapshot jsonb not null, content_hash text not null, created_at timestamptz not null default now());
alter table reader_delta.accounts enable row level security;
alter table reader_delta.entities enable row level security;
alter table reader_delta.changes enable row level security;
alter table reader_delta.receipts enable row level security;
alter table reader_delta.legacy_backup enable row level security;
create or replace function public.reader_delta_push(p_operations jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); a reader_delta.accounts%rowtype; o jsonb; e reader_delta.entities%rowtype; r reader_delta.receipts%rowtype; ack jsonb; result jsonb:='[]'; c jsonb; v bigint;
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_operations is null or jsonb_typeof(p_operations)<>'array' or jsonb_array_length(p_operations)>50 or octet_length(p_operations::text)>131072 then raise exception 'batch limit exceeded'; end if;
 insert into reader_delta.accounts(user_id) values(u) on conflict do nothing;
 select * into a from reader_delta.accounts where user_id=u for update;
 for o in select value from jsonb_array_elements(p_operations) loop
  o:=o||jsonb_build_object('kind',coalesce(o->>'kind',case when coalesce((o->>'deleted')::boolean,false) then 'delete' else 'upsert' end));
  if o->>'entityType' not in ('answer_event','quiz_answers','quiz_locatorSentenceIds','quiz_answerUpdatedAt','quiz_answerDeletedAt','quiz_locatorUpdatedAt','quiz_locatorDeletedAt','quiz_meta','reading_positions','completion_records','preferences','favorite','vocabulary','encrypted_ai_key') or length(o->>'operationID')>200 or length(o->>'entityID')>1000 or length(o->>'entityType')>80 or (o->>'entityType'='answer_event' and o->>'kind'<>'upsert') or coalesce(o->>'operationID','')='' or coalesce(o->>'entityID','')='' or coalesce(o->>'entityType','')='' or coalesce(o->>'kind','') not in ('upsert','delete','restore') or octet_length(o::text)>65536 then raise exception 'invalid or oversized operation'; end if;
  select * into r from reader_delta.receipts where user_id=u and operation_id=o->>'operationID';
  if found then
   if r.operation<>o then raise exception 'operation ID reused with different payload'; end if;
   result:=result||jsonb_build_array(r.receipt); continue;
  end if;
  select * into e from reader_delta.entities where user_id=u and entity_type=o->>'entityType' and entity_id=o->>'entityID';
  v:=coalesce(e.version,0);
  if coalesce((o->>'baseVersion')::bigint,0)<>v or (o->>'entityType'='answer_event' and v>0) or (coalesce(e.deleted,false) and o->>'kind'='upsert') then
   ack:=jsonb_build_object('operationID',o->>'operationID','status','conflict','version',v,'deleted',coalesce(e.deleted,false));
  else
   v:=v+1; a.cursor:=a.cursor+1;
   insert into reader_delta.entities values(u,o->>'entityType',o->>'entityID',v,o->>'kind'='delete',o->'payload') on conflict(user_id,entity_type,entity_id) do update set version=excluded.version,deleted=excluded.deleted,payload=excluded.payload;
   c:=jsonb_build_object('cursor',a.cursor,'entityType',o->>'entityType','entityID',o->>'entityID','version',v,'deleted',o->>'kind'='delete','payload',o->'payload');
   insert into reader_delta.changes values(u,a.cursor,c);
   ack:=jsonb_build_object('operationID',o->>'operationID','status','applied','version',v);
  end if;
  insert into reader_delta.receipts values(u,o->>'operationID',o,ack);
  result:=result||jsonb_build_array(ack);
 end loop;
 update reader_delta.accounts set cursor=a.cursor where user_id=u;
 return jsonb_build_object('epoch',a.epoch,'acknowledgements',result);
end $$;
create or replace function public.reader_delta_pull(p_epoch text default null,p_cursor bigint default 0,p_limit integer default 50) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); a reader_delta.accounts%rowtype; row record; items jsonb:='[]'; n bigint:=p_cursor;
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_limit is null or p_cursor is null or p_limit<1 or p_limit>50 or p_cursor<0 then raise exception 'invalid page'; end if;
 insert into reader_delta.accounts(user_id) values(u) on conflict do nothing;
 select * into a from reader_delta.accounts where user_id=u;
 if (p_epoch is not null and p_epoch<>a.epoch) or p_cursor>a.cursor then return jsonb_build_object('epoch',a.epoch,'resetRequired',true,'nextCursor',0,'hasMore',true,'changes','[]'::jsonb); end if;
 for row in select cursor,change from reader_delta.changes where user_id=u and cursor>p_cursor order by cursor limit p_limit loop
  exit when octet_length((items||jsonb_build_array(row.change))::text)>100000;
  items:=items||jsonb_build_array(row.change); n:=row.cursor;
 end loop;
 return jsonb_build_object('epoch',a.epoch,'nextCursor',n,'hasMore',n<a.cursor,'changes',items);
end $$;
revoke all on function public.reader_delta_push(jsonb) from public;
revoke all on function public.reader_delta_pull(text,bigint,integer) from public;
grant execute on function public.reader_delta_push(jsonb), public.reader_delta_pull(text,bigint,integer) to authenticated;
-- Freeze the legacy source only for explicitly activated accounts. Backup is never deleted.
create or replace function reader_delta.guard_legacy() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from reader_delta.accounts where user_id=new.user_id and migrated) and (TG_OP='INSERT' or (to_jsonb(new)-'vocab_master_progress'-'updated_at') is distinct from (to_jsonb(old)-'vocab_master_progress'-'updated_at')) then raise exception 'READER_UPGRADE_REQUIRED: protocol 3 required'; end if;
 return new;
end $$;
create or replace function public.reader_delta_activate() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); s jsonb;
begin
 if u is null then raise exception 'authentication required'; end if;
 insert into reader_delta.accounts(user_id) values(u) on conflict do nothing;
 perform 1 from reader_delta.accounts where user_id=u for update;
 if exists(select 1 from reader_delta.accounts where user_id=u and migrated) then
  return jsonb_build_object('activated',true,'protocol',3,'migrationVerified',(select migration_verified from reader_delta.accounts where user_id=u));
 end if;
 select to_jsonb(t) into s from public.reader_sync_state t where user_id=u for update;
 if s is not null then insert into reader_delta.legacy_backup(user_id,snapshot,content_hash) values(u,s,md5(s::text)) on conflict do nothing; end if;
 update reader_delta.accounts set migrated=true where user_id=u;
 return jsonb_build_object('activated',true,'protocol',3,'migrationVerified',(select migration_verified from reader_delta.accounts where user_id=u));
end $$;
-- Bounded legacy field pages; source snapshot is immutable after activation.
create or replace function public.reader_delta_legacy_page(p_field text,p_after text default '',p_limit integer default 50) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); source jsonb; r record; items jsonb:='[]'; n text:=p_after;
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_field not in ('vocabulary','favorites','reading_positions','quiz_progress','completion_records','preferences','encrypted_ai_key','vocab_tombstones') or p_limit<1 or p_limit>50 then raise exception 'invalid migration page'; end if;
 select snapshot->p_field into source from reader_delta.legacy_backup where user_id=u;
 if p_field='encrypted_ai_key' then
  if source is not null and source<>'null'::jsonb and p_after='' then
   if octet_length(source::text)>65536 then raise exception 'legacy item oversized; original retained'; end if;
   items:=jsonb_build_array(jsonb_build_object('id','singleton','payload',source)); n:='singleton';
  end if;
 elsif jsonb_typeof(source)='object' then
  for r in select key,value from jsonb_each(source) where key>p_after order by key limit p_limit loop
   if octet_length(r.value::text)>65536 then raise exception 'legacy item oversized; original retained'; end if;
   exit when octet_length((items||jsonb_build_array(jsonb_build_object('id',r.key,'payload',r.value)))::text)>100000;
   items:=items||jsonb_build_array(jsonb_build_object('id',r.key,'payload',r.value)); n:=r.key;
  end loop;
 elsif jsonb_typeof(source)='array' then
  for r in select ordinality::text key,value from jsonb_array_elements(source) with ordinality where ordinality>coalesce(nullif(p_after,''),'0')::bigint order by ordinality limit p_limit loop
   if octet_length(r.value::text)>65536 then raise exception 'legacy item oversized; original retained'; end if;
   exit when octet_length((items||jsonb_build_array(jsonb_build_object('id',r.key,'payload',r.value)))::text)>100000;
   items:=items||jsonb_build_array(jsonb_build_object('id',r.key,'payload',r.value)); n:=r.key;
  end loop;
 elsif source is not null and source<>'null'::jsonb and p_after='' then
  if octet_length(source::text)>65536 then raise exception 'legacy item oversized; original retained'; end if;
  items:=jsonb_build_array(jsonb_build_object('id','singleton','payload',source)); n:='singleton';
 end if;
 return jsonb_build_object('items',items,'nextKey',n,'hasMore',case when p_field='encrypted_ai_key' then false else case jsonb_typeof(source) when 'object' then exists(select 1 from jsonb_object_keys(source) k where k>n) when 'array' then coalesce(nullif(n,''),'0')::bigint<jsonb_array_length(source) else false end end);
end $$;
revoke all on function public.reader_delta_activate(),public.reader_delta_legacy_page(text,text,integer) from public;
grant execute on function public.reader_delta_activate(),public.reader_delta_legacy_page(text,text,integer) to authenticated;
drop trigger if exists reader_delta_legacy_guard on public.reader_sync_state;
create trigger reader_delta_legacy_guard before insert or update on public.reader_sync_state for each row execute function reader_delta.guard_legacy();
-- Completion is an explicit audit acknowledgement, separate from source freezing.
alter table reader_delta.accounts add column if not exists migration_verified boolean not null default false;
create table if not exists reader_delta.migration_audit(user_id uuid not null, field text not null, expected_count bigint not null, content_hash text not null, primary key(user_id,field));
alter table reader_delta.migration_audit enable row level security;
create or replace function public.reader_delta_legacy_manifest() returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); s jsonb; k text; v jsonb; result jsonb:='[]'; n bigint;
begin
 if u is null then raise exception 'authentication required'; end if;
 select snapshot into s from reader_delta.legacy_backup where user_id=u;
 if s is null then return '[]'::jsonb; end if;
 foreach k in array array['vocabulary','favorites','reading_positions','quiz_progress','completion_records','preferences','encrypted_ai_key','vocab_tombstones'] loop
  v:=s->k;
  n:=case when k='encrypted_ai_key' then case when v is null or v='null'::jsonb then 0 else 1 end else case jsonb_typeof(v) when 'array' then jsonb_array_length(v) when 'object' then (select count(*) from jsonb_object_keys(v)) when 'null' then 0 else case when v is null then 0 else 1 end end end;
  result:=result||jsonb_build_array(jsonb_build_object('field',k,'count',n,'contentHash',md5(coalesce(v,'null'::jsonb)::text)));
 end loop;
 return result;
end $$;
create table if not exists reader_delta.import_receipts(user_id uuid not null, field text not null, id text not null, payload jsonb not null, primary key(user_id,field,id));
alter table reader_delta.import_receipts enable row level security;
create or replace function reader_delta.project_legacy(f text,id text,p jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='[]'; field text; r record; meta jsonb;
begin
 if f='vocab_tombstones' then
  return jsonb_build_array(jsonb_build_object('type','vocabulary','id',lower(btrim(p->>'wordKey')),'payload',null,'deleted',true));
 elsif f='quiz_progress' then
  meta:=p;
  foreach field in array array['answers','locatorSentenceIds','answerUpdatedAt','answerDeletedAt','locatorUpdatedAt','locatorDeletedAt'] loop
   meta:=meta-field;
   for r in select key,value from jsonb_each(coalesce(p->field,'{}')) loop
    result:=result||jsonb_build_array(jsonb_build_object('type','quiz_'||field,'id','['||to_json(id)::text||','||to_json(r.key)::text||']','payload',r.value));
   end loop;
  end loop;
  result:=result||jsonb_build_array(jsonb_build_object('type','quiz_meta','id',id,'payload',meta));
 else
  result:=jsonb_build_array(jsonb_build_object('type',case f when 'favorites' then 'favorite' else f end,'id',case f when 'vocabulary' then lower(btrim(p->>'word')) when 'favorites' then p#>>'{}' when 'encrypted_ai_key' then 'default' else id end,'payload',case when f='favorites' then 'true'::jsonb else p end));
 end if;
 return result;
end $$;
create or replace function public.reader_delta_stage_legacy(p_field text,p_id text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); source jsonb; expected jsonb; projection jsonb; e jsonb;
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_field is null or p_id is null or octet_length(p_payload::text)>65536 then raise exception 'invalid import'; end if;
 select snapshot->p_field into source from reader_delta.legacy_backup where user_id=u;
 expected:=case when p_field='encrypted_ai_key' then case when p_id='singleton' then source end else case jsonb_typeof(source) when 'array' then source->(p_id::integer-1) when 'object' then source->p_id else case when p_id='singleton' then source end end end;
 if expected is null or expected is distinct from p_payload then raise exception 'legacy source mismatch'; end if;
 projection:=reader_delta.project_legacy(p_field,p_id,p_payload);
 for e in select value from jsonb_array_elements(projection) loop
  if not exists(select 1 from reader_delta.entities where user_id=u and entity_type=e->>'type' and entity_id=e->>'id' and deleted=coalesce((e->>'deleted')::boolean,false) and payload is not distinct from e->'payload') then raise exception 'destination missing or differs from source'; end if;
 end loop;
 insert into reader_delta.import_receipts values(u,p_field,p_id,p_payload) on conflict(user_id,field,id) do update set payload=excluded.payload;
 return jsonb_build_object('verified',true,'id',p_id);
end $$;
create or replace function public.reader_delta_finish_migration(p_manifest jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); expected jsonb; item jsonb; staged jsonb; source jsonb;
begin
 if u is null then raise exception 'authentication required'; end if;
 perform 1 from reader_delta.accounts where user_id=u and migrated for update;
 if not found then raise exception 'activate migration first'; end if;
 expected:=public.reader_delta_legacy_manifest();
 if p_manifest is distinct from expected then raise exception 'migration manifest mismatch'; end if;
 for item in select value from jsonb_array_elements(expected) loop
  select snapshot->(item->>'field') into source from reader_delta.legacy_backup where user_id=u;
  if item->>'field'='encrypted_ai_key' then
   select payload into staged from reader_delta.import_receipts where user_id=u and field='encrypted_ai_key' and id='singleton';
  elsif jsonb_typeof(source)='array' then
   select coalesce(jsonb_agg(payload order by id::bigint),'[]') into staged from reader_delta.import_receipts where user_id=u and field=item->>'field';
  elsif jsonb_typeof(source)='object' then
   select coalesce(jsonb_object_agg(id,payload),'{}') into staged from reader_delta.import_receipts where user_id=u and field=item->>'field';
  else
   select payload into staged from reader_delta.import_receipts where user_id=u and field=item->>'field' and id='singleton';
  end if;
  if coalesce(staged,'null') is distinct from coalesce(source,'null') then raise exception 'staged source count/hash mismatch; original retained'; end if;
  insert into reader_delta.migration_audit values(u,item->>'field',(item->>'count')::bigint,item->>'contentHash') on conflict do nothing;
 end loop;
 update reader_delta.accounts set migration_verified=true where user_id=u;
 return jsonb_build_object('verified',true,'sourceRetained',true);
end $$;
revoke all on function public.reader_delta_stage_legacy(text,text,jsonb),public.reader_delta_finish_migration(jsonb) from public;
grant execute on function public.reader_delta_stage_legacy(text,text,jsonb),public.reader_delta_finish_migration(jsonb) to authenticated;

revoke all on function public.reader_delta_legacy_manifest() from public;
grant execute on function public.reader_delta_legacy_manifest() to authenticated;
-- Targeted conflict recovery never rewinds the change cursor.
create or replace function public.reader_delta_get(p_entities jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); requested jsonb; e reader_delta.entities%rowtype; result jsonb:='[]'; item jsonb;
begin
 if u is null then raise exception 'authentication required'; end if;
 if p_entities is null or jsonb_typeof(p_entities)<>'array' or jsonb_array_length(p_entities)>50 or octet_length(p_entities::text)>100000 then raise exception 'invalid targeted page'; end if;
 for requested in select value from jsonb_array_elements(p_entities) loop
  select * into e from reader_delta.entities where user_id=u and entity_type=requested->>'entityType' and entity_id=requested->>'entityID';
  if found then item:=jsonb_build_object('entityType',e.entity_type,'entityID',e.entity_id,'version',e.version,'deleted',e.deleted,'payload',e.payload);
  else item:=jsonb_build_object('entityType',requested->>'entityType','entityID',requested->>'entityID','version',0,'deleted',true,'payload',null); end if;
  if octet_length((result||jsonb_build_array(item))::text)>100000 then raise exception 'targeted response too large; retry fewer IDs'; end if;
  result:=result||jsonb_build_array(item);
 end loop;
 return jsonb_build_object('entities',result);
end $$;
revoke all on function public.reader_delta_get(jsonb) from public;
grant execute on function public.reader_delta_get(jsonb) to authenticated;
