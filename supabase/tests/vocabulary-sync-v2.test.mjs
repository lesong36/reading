import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const html = fs.readFileSync(new URL('../../index.html',import.meta.url),'utf8');
const source = html.split('// VOCABULARY_SYNC_V2_BEGIN')[1].split('// VOCABULARY_SYNC_V2_END')[0].split('\n').slice(1).join('\n');
const context = vm.createContext({ crypto:webcrypto, JSON, Set, Error, Number, String });
vm.runInContext(source+'\nglobalThis.createSync=createVocabularySyncV2; globalThis.accountView=vocabularyViewV2; globalThis.anonymousView=anonymousVocabularyView;',context);
const plain = value => JSON.parse(JSON.stringify(value));
const storage = () => { const map=new Map(); return {getItem:key=>map.get(key)||null,setItem:(key,value)=>map.set(key,value)}; };
const response = (revision=0,extra={}) => ({userID:'A',revision,vocabulary:[],tombstones:[],acknowledgedOperationIDs:[],uploadedCount:0,conflict:false,conflictingWordKeys:[],...extra});
const entry = {word:'alpha',meaning:'甲'};
let passed=0;
const test = async (name,body) => { await body(); passed++; process.stdout.write(`PASS ${name}\n`); };
await test('account views project only their snapshot and keep anonymous entries separate',async()=>{
 const memory=storage();memory.setItem('my_local_vocab_book',JSON.stringify([{word:'unsigned-private',meaning:'未归属'}]));
 const a=context.createSync({},'A',memory,()=> 'A');a.queue('upsert',{word:'a-private',meaning:'账号A'});
 const b=context.createSync({},'B',memory,()=> 'B');b.queue('upsert',{word:'b-private',meaning:'账号B'});
 assert.deepEqual(plain(context.accountView(a.snapshot())).map(item=>item.word),['a-private']);
 assert.deepEqual(plain(context.accountView(b.snapshot())).map(item=>item.word),['b-private']);
 assert.deepEqual(plain(context.anonymousView(memory)).vocabulary.map(item=>item.word),['unsigned-private']);
});
await test('durable queue, RPC only and exact acknowledgement',async()=>{
 const memory=storage();const calls=[];
 const client={rpc:async(name,args)=>{calls.push({name,args:plain(args)});return{data:response(1,{vocabulary:[{...entry,cloudVersion:1}],acknowledgedOperationIDs:args.p_operations.map(op=>op.operationID)}),error:null};}};
 const first=context.createSync(client,'A',memory,()=> 'A');first.queue('upsert',entry);
 const reopened=context.createSync(client,'A',memory,()=> 'A');await reopened.flush();
 assert.equal(calls.length,1);assert.equal(calls[0].name,'sync_reader_vocabulary_v2');assert.equal(reopened.snapshot().pending.length,0);
});
await test('global revision conflict retries without altering entry base version',async()=>{
 const calls=[];const client={rpc:async(_,args)=>{calls.push(plain(args));return{data:calls.length===1?response(4,{conflict:true}):response(5,{acknowledgedOperationIDs:args.p_operations.map(op=>op.operationID)}),error:null};}};
 const sync=context.createSync(client,'A',storage(),()=> 'A');sync.queue('upsert',entry);await sync.flush();
 assert.equal(calls[1].p_expected_revision,4);assert.equal(calls[1].p_operations[0].baseVersion,null);
});
await test('word conflict preserves pending and stops automatic retries',async()=>{
 let count=0;const client={rpc:async()=>{count++;return{data:response(2,{conflict:true,conflictingWordKeys:['alpha']}),error:null};}};
 const sync=context.createSync(client,'A',storage(),()=> 'A');sync.queue('upsert',entry);
 await assert.rejects(sync.flush(),/云端词条/);await assert.rejects(sync.flush(),/云端词条/);
 assert.equal(count,1);assert.equal(sync.snapshot().pending.length,1);
});
await test('unconfirmed result cannot erase pending',async()=>{
 const sync=context.createSync({rpc:async()=>({data:response(),error:null})},'A',storage(),()=> 'A');sync.queue('upsert',entry);
 await assert.rejects(sync.flush(),/确认/);assert.equal(sync.snapshot().pending.length,1);
});
await test('missing RPC reports upgrade and retains operations',async()=>{
 const sync=context.createSync({rpc:async()=>({data:null,error:{code:'PGRST202'}})},'A',storage(),()=> 'A');sync.queue('upsert',entry);
 await assert.rejects(sync.flush(),/尚未升级/);assert.equal(sync.snapshot().pending.length,1);
});
await test('account switch ignores an in-flight response',async()=>{
 let active='A',resolve;const client={rpc:()=>new Promise(done=>{resolve=done})};
 const sync=context.createSync(client,'A',storage(),()=>active);sync.queue('upsert',entry);const pending=sync.flush();active='B';resolve({data:response(1),error:null});
 await assert.rejects(pending,/账号已切换/);assert.equal(sync.snapshot().pending.length,1);
});
await test('explicit re-add uses tombstone version and restore kind',async()=>{
 const client={rpc:async()=>({data:response(3,{tombstones:[{wordKey:'alpha',version:3}]}),error:null})};
 const sync=context.createSync(client,'A',storage(),()=> 'A');await sync.read();sync.queue('upsert',entry);
 assert.equal(sync.snapshot().pending[0].kind,'restore');assert.equal(sync.snapshot().pending[0].baseVersion,3);
});
await test('edits queued while RPC awaits keep separate IDs and rebase only own acknowledgement',async()=>{
 let resolve;const calls=[];const client={rpc:async(_,args)=>{calls.push(plain(args));if(calls.length===1)return new Promise(done=>resolve=done);return{data:response(2,{vocabulary:[{word:'alpha',meaning:'乙',cloudVersion:2}],acknowledgedOperationIDs:args.p_operations.map(op=>op.operationID)}),error:null};}};
 const sync=context.createSync(client,'A',storage(),()=> 'A');sync.queue('upsert',entry);const pending=sync.flush();sync.queue('upsert',{word:'alpha',meaning:'乙'});
 const first=calls[0].p_operations[0];resolve({data:response(1,{vocabulary:[{...entry,cloudVersion:1}],acknowledgedOperationIDs:[first.operationID]}),error:null});await pending;
 assert.equal(calls.length,2);assert.notEqual(calls[1].p_operations[0].operationID,first.operationID);assert.equal(calls[1].p_operations[0].baseVersion,1);
});
await test('corrupt local outbox blocks writes without replacing original',async()=>{
 const memory=storage();memory.setItem('reader_vocab_sync_v2:A','{broken');assert.throws(()=>context.createSync({},'A',memory,()=> 'A'));assert.equal(memory.getItem('reader_vocab_sync_v2:A'),'{broken');
});
await test('protected vocabulary columns never appear in reader upsert payloads',async()=>{
 assert.doesNotMatch(html,/let payload = \{ user_id: user\.id, vocabulary:/);
 assert.doesNotMatch(html,/upsert\(\{ user_id: user\.id, vocabulary:/);
 assert.doesNotMatch(html,/vocabulary: removeDeletedVocab\(nextVocabBook/);
});
await test('full reader JSX parses with the existing vendored Babel',async()=>{
 const runtime=vm.createContext({});vm.runInContext(fs.readFileSync(new URL('../../vendor/babel.min.js',import.meta.url),'utf8'),runtime);
 const reader=html.match(/<script type="text\/babel"[^>]*>([\s\S]*?)<\/script>/)[1];runtime.Babel.transform(reader,{presets:['react'],sourceType:'module'});
});
await test('browser correction wins by modification time and preserves future fields',async()=>{
 const helpers=html.slice(html.indexOf('    const compareVocabVersion ='),html.indexOf('    const getVocabKey ='));
 vm.runInContext(helpers+'\nglobalThis.normalize=normalizeVocabBook;',context);
 const result=context.normalize([{word:' Bank ',meaning:'old',timestamp:1,cloudVersion:7,updatedAt:'2026-10-06T01:00:00Z'},{word:'bank',meaning:'new',timestamp:1,cloudVersion:7,updatedAt:'2026-10-06T02:00:00Z',future:{keep:true}}]);
 assert.equal(result.length,1);assert.equal(result[0].meaning,'new');assert.equal(result[0].future.keep,true);
});
await test('native ISO timestamps group into local calendar days',async()=>{
 const helper=html.slice(html.indexOf('    const localDayKey ='),html.indexOf('    const readDailyReportPreferences ='));
 vm.runInContext(helper+'\nglobalThis.day=localDayKey;',context);
 const first=context.day('2026-10-06T01:00:00Z'),second=context.day('2026-10-06T02:00:00Z');
 assert.match(first,/^\d{4}-\d{2}-\d{2}$/);assert.equal(first,second);assert.match(html,/const day = localDayKey\(entry.addedAt \|\| entry.timestamp\)/);
});
await test('local dates respect midnight and DST while old date-only labels stay stable',async()=>{
 const helper=html.slice(html.indexOf('    const localDayKey ='),html.indexOf('    const readDailyReportPreferences ='));
 const values=['2026-10-06T00:30:00Z','2026-11-01T05:30:00Z','2026-11-01T06:30:00Z','2026-10-06','2026-02-30'];
 const run=timezone=>JSON.parse(execFileSync(process.execPath,['--input-type=module','-e',helper+`\nconsole.log(JSON.stringify(${JSON.stringify(values)}.map(localDayKey)))`],{env:{...process.env,TZ:timezone},encoding:'utf8'}));
 assert.deepEqual(run('America/New_York'),['2026-10-05','2026-11-01','2026-11-01','2026-10-06','']);
 assert.deepEqual(run('Asia/Shanghai'),['2026-10-06','2026-11-01','2026-11-01','2026-10-06','']);
});
console.log(`${passed} vocabulary web protocol tests passed`);
