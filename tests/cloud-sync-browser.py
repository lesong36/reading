"""Two isolated browsers share a mocked cloud; never uses real user accounts."""
import copy,json,os,re,time
from playwright.sync_api import sync_playwright
URL=os.environ.get('READING_URL','http://localhost:8780').rstrip('/')
USER='00000000-0000-4000-8000-000000000001'
cloud={'quiz_progress':{},'favorites':[],'completion_records':{},'reading_positions':{},'preferences':{}}
writes=[]
STUB=r'''
let user={id:'USER_ID',email:'sync-test@example.invalid'};
const call=async(action,payload)=>{if(action==='write'&&window.__slowWrite){window.__uploadStarted=true;window.__slowWrite=false;await new Promise(ok=>setTimeout(ok,1600));}const response=await fetch('/__test-sync',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,payload,client:window.name})}).then(r=>r.json());if(action==='read'&&window.__slowRead){window.__readStarted=true;window.__slowRead=false;await new Promise(ok=>setTimeout(ok,1600));}return response;};
export function createClient(){window.__switchTestAccount=(id)=>{user={id,email:'other@example.invalid'};window.__authChanged?.('SIGNED_IN',{user})};return {
 auth:{getSession:()=>Promise.resolve({data:{session:{user}},error:null}),onAuthStateChange:(fn)=>{window.__authChanged=fn;return {data:{subscription:{unsubscribe(){}}}}}},
 rpc:async(name,args)=>({data:{userID:user.id,revision:0,vocabulary:[],tombstones:[],acknowledgedOperationIDs:(args.p_operations||[]).map(o=>o.operationID),conflict:false,conflictingWordKeys:[]},error:null}),
 from(table){let op='read',payload,owner;const q={select(){return q},eq(k,v){if(k==='user_id')owner=v;return q},order(){return q},limit(){return q},insert(p){op='insert';payload=p;return q},upsert(p){op='upsert';payload=p;return q},maybeSingle(){return call(table==='reader_sync_state'?'read':'other',{owner})},then(ok,bad){return (table==='reader_sync_state'&&op==='upsert'?call('write',payload):Promise.resolve({data:[],error:null})).then(ok,bad)}};return q}
}}
'''.replace('USER_ID',USER)
def wait(page,predicate,timeout=10):
 deadline=time.monotonic()+timeout
 while not predicate():
  assert time.monotonic()<deadline,'sync deadline exceeded'
  page.wait_for_timeout(100)
def quiz(page):
 page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click()
def q1(page,letter,word):
 page.get_by_role('button',name='1',exact=True).click();page.get_by_role('button',name=re.compile('^'+letter+r'\s*'+word+'$')).click()
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True)
 def make(name):
  ctx=browser.new_context();page=ctx.new_page();page.add_init_script('window.name='+json.dumps(name))
  page.route('**/local-config.js',lambda r:r.fulfill(content_type='application/javascript',body='window.__reader_local_config={}'))
  page.route('https://esm.sh/@supabase/supabase-js@2?bundle',lambda r:r.fulfill(content_type='application/javascript',headers={'Access-Control-Allow-Origin':'*'},body=STUB))
  def route(r):
   request=r.request.post_data_json
   if request['action']=='write':
    cloud.update(copy.deepcopy(request['payload']));writes.append(copy.deepcopy(cloud));data=None
   elif request['action']=='read':data=copy.deepcopy(cloud) if request.get('payload',{}).get('owner')==USER else {'quiz_progress':{},'favorites':[],'completion_records':{},'reading_positions':{},'preferences':{}}
   else:data=[]
   r.fulfill(content_type='application/json',body=json.dumps({'data':data,'error':None}))
  page.route('**/__test-sync',route)
  errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
  page.goto(URL);page.get_by_role('button',name='继续阅读',exact=True).first.wait_for(timeout=60000)
  return page,errors
 a,ae=make('A');b,be=make('B');quiz(a);quiz(b)
 q1(a,'B','model')
 wait(a,lambda:any(v.get('answers',{}).get('q1')==1 for v in cloud['quiz_progress'].values()))
 print('answer-only upload PASS',flush=True)
 b.evaluate("window.dispatchEvent(new Event('focus'));document.dispatchEvent(new Event('visibilitychange'))")
 b.get_by_text('已答 1/12',exact=True).wait_for(timeout=10000)
 print('return-to-browser pull updates active quiz without reload PASS',flush=True)
 a.evaluate('window.__slowWrite=true;window.__uploadStarted=false')
 q1(a,'C','assume');a.wait_for_function('window.__uploadStarted===true',timeout=10000)
 q1(a,'D','present')
 wait(a,lambda:any(v.get('answers',{}).get('q1')==3 for v in cloud['quiz_progress'].values()),timeout=12)
 print('change during slow in-flight upload eventually saved PASS',flush=True)
 key=next(k for k,v in cloud['quiz_progress'].items() if v.get('answers',{}).get('q1')==3)
 # Edit after SELECT captured its response, before the response is applied.
 a.evaluate('window.__slowRead=true;window.__readStarted=false')
 q1(a,'B','model');a.wait_for_function('window.__readStarted===true',timeout=10000)
 q1(a,'C','assume')
 wait(a,lambda:cloud['quiz_progress'].get(key,{}).get('answers',{}).get('q1')==2,timeout=12)
 a.wait_for_timeout(1000)
 assert cloud['quiz_progress'][key]['answers']['q1']==2,'late SELECT overwrote fresh edit'
 print('edit during delayed SELECT survives PASS',flush=True)
 # B still holds q1=1; changing q2 must not overwrite A's newer q1=2.
 b.get_by_role('button',name='2',exact=True).click()
 b.locator('button').filter(has_text=re.compile(r'^A')).last.click()
 wait(b,lambda:'q2' in cloud['quiz_progress'].get(key,{}).get('answers',{}),timeout=12)
 assert cloud['quiz_progress'][key]['answers']['q1']==2,'q2 edit restored stale q1'
 print('different-question stale browser merge PASS',flush=True)
 cloud.setdefault('reading_positions',{})[key]={'sentenceId':'newer-cloud-position','updatedAt':'2099-01-01T00:00:00Z'}
 before=len(writes);b.locator('button').filter(has_text=re.compile(r'^B')).last.click()
 wait(b,lambda:len(writes)>before,timeout=12)
 assert cloud['reading_positions'][key]['sentenceId']=='newer-cloud-position','stale position overwrote newer cloud position'
 print('newer article position survives unrelated stale upload PASS',flush=True)
 # Cloud submission must win an older local answer on the returning browser.
 cloud['quiz_progress'][key].update({'answers':{**cloud['quiz_progress'][key]['answers'],'q1':0},'lastAnsweredAt':'2099-01-01T00:00:00Z','submitted':True,'submittedAt':'2099-01-01T00:00:00Z','answerUpdatedAt':{'q1':'2099-01-01T00:00:00Z'}})
 a.evaluate("window.dispatchEvent(new Event('focus'))");a.wait_for_timeout(1800)
 assert cloud['quiz_progress'][key]['answers']['q1']==0,'stale local answer overwrote newer cloud answer'
 a.get_by_text(re.compile('学习记录已同步 · [0-9]{2}:')).first.wait_for(timeout=10000)
 before=len(writes);a.wait_for_timeout(3000);assert len(writes)==before,'runaway repeated uploads while idle'
 assert not ae and not be,(ae,be)
 print('newer remote answer protected PASS; no uncaught errors',flush=True)
 a.evaluate('window.__slowRead=true;window.__readStarted=false;window.dispatchEvent(new Event("focus"))')
 a.wait_for_function('window.__readStarted===true',timeout=10000)
 a.get_by_role('button',name=re.compile('我的书架')).click();a.get_by_role('button',name='继续阅读',exact=True).nth(1).click();a.get_by_text('做题',exact=True).click()
 a.wait_for_timeout(2400)
 other=a.evaluate('''async () => {const db=await new Promise(ok=>{const r=indexedDB.open('reader-learning-data-v1',1);r.onsuccess=()=>ok(r.result)});try{return await new Promise(ok=>{const r=db.transaction('records').objectStore('records').get('reader_quiz_progress_og-aggression');r.onsuccess=()=>ok(r.result||'{}')})}finally{db.close()}}''')
 assert not json.loads(other).get('answers'), 'delayed article A response persisted under article B'
 assert not cloud['quiz_progress'].get('og-aggression',{}).get('answers'), 'wrong article answers uploaded'
 print('switch article during delayed pull preserves article ownership PASS',flush=True)
 a.evaluate('window.__slowRead=true;window.__readStarted=false;window.dispatchEvent(new Event("focus"))')
 a.wait_for_function('window.__readStarted===true',timeout=10000)
 baseline=len(writes);a.evaluate('window.__switchTestAccount("00000000-0000-4000-8000-000000000002")');a.wait_for_timeout(2500)
 assert not any(item.get('user_id')==USER for item in writes[baseline:]),'old account uploaded after delayed read and account switch'
 print('account switch cancels delayed old-account upload PASS',flush=True)
 browser.close()
