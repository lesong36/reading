"""Real browser IndexedDB migration, abort and cross-tab regression tests."""
import json, os
from playwright.sync_api import sync_playwright
URL=os.environ.get('READING_URL','http://localhost:8773').rstrip('/')
HARNESS=f'<script src="{URL}/scripts/reader-storage.js"></script>'
with sync_playwright() as p:
 b=p.chromium.launch(headless=True)
 def new_page(context):
  page=context.new_page();page.route('**/storage-harness.html',lambda route: route.fulfill(content_type='text/html',body=HARNESS));page.goto(URL+'/storage-harness.html');page.wait_for_function('typeof createReaderStorage === "function"');return page
 context=b.new_context();page=new_page(context)
 result=page.evaluate('''async () => {
  localStorage.setItem('my_local_articles','large-article');localStorage.setItem('reader_quiz_progress_a','old');sessionStorage.setItem('reader_quiz_progress_a','latest');localStorage.setItem('other-project','keep');
  window.s=createReaderStorage();await s.ready;
  if(localStorage.getItem('my_local_articles')!==null || s.getItem('my_local_articles')!=='large-article' || s.getItem('reader_quiz_progress_a')!=='latest')throw Error('migration mismatch');
  s.setItem('reader_voice_speed','1.5');if(localStorage.getItem('reader_voice_speed')!=='1.5')throw Error('small setting');
  s.setItem('reader_openai_compat_model','x'.repeat(9000));await s.flush();if(localStorage.getItem('reader_openai_compat_model')!==null)throw Error('oversized setting in native store');
  if(s.isManagedKey('reader_openai_compat_model'))throw Error('settings incorrectly included in clear-learning-data');
  localStorage.setItem('reader_article_outline_v1_late','late');await s.maintain();if(localStorage.getItem('reader_article_outline_v1_late')!==null || s.getItem('reader_article_outline_v1_late')!=='late')throw Error('proactive migration');
  return {migration:true,session_recovery:true,settings_budget:true,proactive_management:true};
 }''');print(json.dumps(result),flush=True)
 second=new_page(context);second.evaluate('async () => {window.s=createReaderStorage();await s.ready}')
 page.evaluate("async () => {s.removeItem('reader_quiz_progress_a');await s.flush()}")
 second.wait_for_function("s.getItem('reader_quiz_progress_a')===null");print('cross-tab deletion PASS',flush=True);context.close()
 context=b.new_context();page=new_page(context)
 result=page.evaluate('''async () => {
  localStorage.setItem('my_local_articles','must-survive');const original=IDBObjectStore.prototype.put;
  IDBObjectStore.prototype.put=function(){throw new DOMException('injected abort','QuotaExceededError')};
  window.s=createReaderStorage();await s.ready;
  if(localStorage.getItem('my_local_articles')!=='must-survive' || !s.status().pending || !s.status().error)throw Error('migration lost original');
  IDBObjectStore.prototype.put=original;await s.maintain();
  if(localStorage.getItem('my_local_articles')!==null || s.getItem('my_local_articles')!=='must-survive' || s.status().pending)throw Error('recovery failed');
  return {transaction_failure_preserves_source:true,maintenance_recovers:true};
 }''');print(json.dumps(result),flush=True);context.close()
 context=b.new_context();page=new_page(context)
 result=page.evaluate('''async () => {
  const first=createReaderStorage();await first.ready;first.setItem('my_local_articles','precious-original');await first.flush();first.dispose();
  const original=IDBObjectStore.prototype.openCursor;IDBObjectStore.prototype.openCursor=function(){throw new Error('injected read failure')};
  const broken=createReaderStorage();await broken.ready;broken.setItem('my_local_articles','[]');
  try{await broken.flush()}catch(_){}
  if(broken.status().indexedDB || !broken.status().error)throw Error('failed read left writable database');
  IDBObjectStore.prototype.openCursor=original;
  const db=await new Promise(ok=>{const r=indexedDB.open('reader-learning-data-v1',1);r.onsuccess=()=>ok(r.result)});
  const actual=await new Promise(ok=>{const r=db.transaction('records').objectStore('records').get('my_local_articles');r.onsuccess=()=>ok(r.result)});db.close();broken.dispose();
  if(actual!=='precious-original')throw Error('unreadable database overwritten');
  return {read_failure_cannot_overwrite_history:true};
 }''');print(json.dumps(result),flush=True);context.close();b.close()
