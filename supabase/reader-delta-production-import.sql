-- Run as database administrator, in one transaction per account.
-- Set reader_migration.owner_id to the already existing owner UUID first.
-- Copies existing data only; never invents answer events.
do $$
declare owner_id uuid:=current_setting('reader_migration.owner_id')::uuid;
 manifest jsonb; item jsonb; page jsonb; source_row jsonb; projected jsonb; entity jsonb;
 after_key text; field_name text; response jsonb; activation jsonb; operation jsonb;
begin
 if not exists(select 1 from public.reader_sync_state where user_id=owner_id) then raise exception 'existing source owner required'; end if;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 activation:=public.reader_delta_activate();
 if coalesce((activation->>'migrationVerified')::boolean,false) then return; end if;
 manifest:=public.reader_delta_legacy_manifest();
 for item in select value from jsonb_array_elements(manifest) loop
  field_name:=item->>'field'; after_key:='';
  loop
   page:=public.reader_delta_legacy_page(field_name,after_key,50);
   for source_row in select value from jsonb_array_elements(page->'items') loop
    projected:=reader_delta.project_legacy(field_name,source_row->>'id',source_row->'payload');
    for entity in select value from jsonb_array_elements(projected) loop
     if not exists(select 1 from reader_delta.entities where user_id=owner_id and entity_type=entity->>'type' and entity_id=entity->>'id' and deleted=coalesce((entity->>'deleted')::boolean,false) and payload is not distinct from entity->'payload') then
      operation:=jsonb_build_object('operationID','legacy-v3:'||md5(field_name||':'||(source_row->>'id')||':'||entity::text),'entityType',entity->>'type','entityID',entity->>'id','baseVersion',0,'kind',case when coalesce((entity->>'deleted')::boolean,false) then 'delete' else 'upsert' end,'payload',entity->'payload');
      response:=public.reader_delta_push(jsonb_build_array(operation));
      if response->'acknowledgements'->0->>'status'<>'applied' then raise exception 'migration destination conflict'; end if;
     end if;
    end loop;
    perform public.reader_delta_stage_legacy(field_name,source_row->>'id',source_row->'payload');
   end loop;
   exit when not (page->>'hasMore')::boolean;
   if page->>'nextKey'=after_key then raise exception 'migration page made no progress'; end if;
   after_key:=page->>'nextKey';
  end loop;
 end loop;
 perform public.reader_delta_finish_migration(manifest);
end $$;
