"""Actual app UI with isolated incremental RPC; Chrome and Edge, no real accounts."""
import json,os,re,threading
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from playwright.sync_api import sync_playwright
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**k):super().__init__(*a,directory=ROOT,**k)
 def log_message(self,*a):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
STUB='''export function createClient(){let log=[],receipts=new Map();window.__deltaRequests=[];let user={id:'00000000-0000-4000-8000-000000000001',email:'test@example.invalid'};return {auth:{getSession:async()=>({data:{session:{user}}}),onAuthStateChange:(fn)=>{window.__switchDeltaUser=(id)=>{user={id,email:'test@example.invalid'};fn('SIGNED_IN',{user});};return {data:{subscription:{unsubscribe(){}}}}}},from(table){if(table==='reader_sync_state')throw Error('legacy snapshot accessed');const q={select(){return q},eq(){return q},order(){return q},limit(){return q},insert(){return q},maybeSingle(){return Promise.resolve({data:null,error:null})},then(ok){return Promise.resolve({data:[],error:null}).then(ok)}};return q;},rpc:async(name,args)=>{window.__deltaRequests.push({name,args});let data;if(name==='reader_delta_activate')data={activated:true,migrationVerified:true};else if(name==='reader_delta_legacy_manifest')data=[];else if(name==='reader_delta_finish_migration')data={verified:true};else if(name==='reader_delta_push'){data={epoch:'test',acknowledgements:args.p_operations.map(op=>{if(receipts.has(op.operationID))return receipts.get(op.operationID);const prior=log.filter(e=>e.entityType===op.entityType&&e.entityID===op.entityID).at(-1);const ack={operationID:op.operationID,status:'applied',version:(prior?.version||0)+1};receipts.set(op.operationID,ack);log.push({...op,version:ack.version,deleted:op.kind==='delete',cursor:log.length+1});return ack;})};}else if(name==='reader_delta_pull'){if(window.__slowDeltaPull){window.__slowDeltaPull=false;window.__pullStarted=true;await new Promise(ok=>setTimeout(ok,1600));}const changes=log.filter(e=>e.cursor>args.p_cursor).slice(0,50);const next=changes.at(-1)?.cursor||args.p_cursor;data={epoch:'test',changes,nextCursor:next,hasMore:next<log.length};}else throw Error('unknown RPC '+name);return {data,error:null};}}}'''
with sync_playwright() as p:
 for channel in ['chrome','msedge']:
  browser=p.chromium.launch(channel=channel,headless=True);ctx=browser.new_context();page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
  page.route('**/local-config.js',lambda r:r.fulfill(content_type='application/javascript',body='window.__reader_local_config={}'))
  page.route('https://esm.sh/@supabase/supabase-js@2?bundle',lambda r:r.fulfill(content_type='application/javascript',headers={'Access-Control-Allow-Origin':'*'},body=STUB))
  page.goto(f'http://127.0.0.1:{server.server_port}/index.html');page.wait_for_timeout(5000)
  page.get_by_role('button',name='继续阅读',exact=True).first.wait_for(timeout=15000)
  page.wait_for_function("window.__deltaRequests?.some(r=>r.name==='reader_delta_pull')",timeout=30000)
  page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click()
  page.get_by_role('button',name='1',exact=True).click();page.get_by_role('button',name=re.compile(r'^B\s*model$')).click()
  page.wait_for_function("window.__deltaRequests.some(r=>r.name==='reader_delta_push'&&r.args.p_operations.some(o=>o.entityType==='answer_event'))",timeout=15000)
  event=page.evaluate("window.__deltaRequests.flatMap(r=>r.args?.p_operations||[]).find(o=>o.entityType==='answer_event')")
  page.wait_for_timeout(2200)
  page.evaluate("window.__slowDeltaPull=true;window.__pullStarted=false;window.dispatchEvent(new Event('focus'))")
  page.wait_for_function('window.__pullStarted===true',timeout=15000)
  page.get_by_role('button',name=re.compile(r'^C\s*assume$')).click()
  page.wait_for_function("window.__deltaRequests.flatMap(r=>r.args?.p_operations||[]).some(o=>o.entityType==='quiz_answers'&&o.payload===2)",timeout=15000)
  page.wait_for_timeout(2000)
  assert page.get_by_role('button',name=re.compile(r'^C\s*assume')).count()==1
  initial='00000000-0000-4000-8000-000000000001'
  page.evaluate("window.__switchDeltaUser('00000000-0000-4000-8000-000000000002')")
  page.wait_for_timeout(1500)
  page.evaluate('(id)=>window.__switchDeltaUser(id)',initial)
  page.wait_for_timeout(1500)
  assert '账号已切换' not in page.locator('body').inner_text()
  assert len(json.dumps(event).encode())<2000,event
  assert not errors,errors
  print(json.dumps({'browser':channel,'answerEventBytes':len(json.dumps(event).encode()),'pageErrors':errors,'result':'PASS'}),flush=True);browser.close()
server.shutdown()
