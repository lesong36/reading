import os,json,re
from playwright.sync_api import sync_playwright
url=os.environ.get('READING_URL','http://localhost:8765')
with sync_playwright() as p:
 b=p.chromium.launch(headless=True)
 for mode in ['quota','denied']:
  page=b.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
  page.goto(url);page.wait_for_load_state('networkidle')
  page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click()
  page.evaluate('''mode => { const original=Storage.prototype.setItem; Storage.prototype.setItem=function(k,v) { if(this===localStorage || mode==='denied') throw new DOMException('fault injection',mode==='quota'?'QuotaExceededError':'SecurityError'); return original.call(this,k,v); }; }''',mode)
  page.get_by_role('button',name=re.compile(r'^A\s*claim$'),exact=True).click();page.get_by_text('做题',exact=True).click();page.get_by_text('已答 1/12',exact=True).wait_for()
  assert page.locator('#reader-storage-warning').is_visible();assert not errors,errors
  if mode=='quota':
   assert page.evaluate("Object.keys(sessionStorage).some(k=>k.startsWith('reader_quiz_progress_') && Object.values(JSON.parse(sessionStorage.getItem(k)).answers).includes(0))")
   page.reload(wait_until='domcontentloaded');page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click();page.get_by_text('已答 1/12',exact=True).wait_for()
  print(json.dumps({'mode':mode,'uncaught_errors':errors,'result':'PASS','url':url}));page.close()
 b.close()
