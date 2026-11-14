"""Run against a served reader; READing data is only created in isolated browser contexts."""
import json, os, re
from playwright.sync_api import sync_playwright
URL = os.environ.get('READING_URL', 'http://localhost:8772')
DB = 'reader-learning-data-v1'
def record_js(key):
    return """async () => { const db = await new Promise((ok, bad) => { const r=indexedDB.open('reader-learning-data-v1',1);r.onsuccess=()=>ok(r.result);r.onerror=()=>bad(r.error); });try { return await new Promise((ok,bad)=>{const r=db.transaction('records').objectStore('records').get(%s);r.onsuccess=()=>ok(r.result || null);r.onerror=()=>bad(r.error);});}finally {db.close();}}""" % json.dumps(key)
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context()
    page = context.new_page(); errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.add_init_script("""() => {}""")
    page.add_init_script("""if (!localStorage.getItem('storage-test-seeded')) {
      localStorage.setItem('reader_article_outline_v1_migration-test', JSON.stringify({text:'x'.repeat(700000)}));
      localStorage.setItem('reader_quiz_progress_old-test', JSON.stringify({answers:{q1:2},submitted:false}));
      localStorage.setItem('reader_voice_speed','1.25');
      localStorage.setItem('other-project-key','keep');
      localStorage.setItem('storage-test-seeded','yes');
    }""")
    page.goto(URL);page.get_by_role('button',name='继续阅读',exact=True).first.wait_for(timeout=60000)
    page.wait_for_function("localStorage.getItem('reader_article_outline_v1_migration-test') === null")
    archived=page.evaluate(record_js('reader_article_outline_v1_migration-test'))
    assert len(json.loads(archived)['text']) == 700000
    assert page.evaluate("localStorage.getItem('other-project-key')") == 'keep'
    assert page.evaluate("localStorage.getItem('reader_voice_speed')") == '1.25'
    # Force every subsequent native write to fail; learning writes must use IndexedDB.
    page.evaluate("() => { Storage.prototype.setItem = function(){throw new DOMException('injected full','QuotaExceededError')}; }")
    page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click()
    page.get_by_role('button',name=re.compile(r'^B\s*model$')).click()
    page.get_by_text('已答 1/12',exact=True).wait_for()
    progress_keys=page.evaluate("async () => { const db=await new Promise(ok=>{const r=indexedDB.open('reader-learning-data-v1',1);r.onsuccess=()=>ok(r.result)});return await new Promise(ok=>{const r=db.transaction('records').objectStore('records').getAllKeys();r.onsuccess=()=>{db.close();ok(r.result.filter(k=>k.startsWith('reader_quiz_progress_') && k!=='reader_quiz_progress_old-test'))}}) }")
    assert progress_keys
    key = progress_keys[0]
    import time
    deadline = time.monotonic() + 10
    while json.loads(page.evaluate(record_js(key)) or '{}').get('answers',{}).get('q1') != 1:
        assert time.monotonic() < deadline, 'answer transaction did not commit'
        page.wait_for_timeout(100)
    page.reload(wait_until='domcontentloaded');page.get_by_role('button',name='继续阅读',exact=True).first.wait_for(timeout=60000)
    assert json.loads(page.evaluate(record_js(key)))['answers']['q1'] == 1
    assert page.evaluate("localStorage.getItem('my_local_articles')") is None
    assert not errors, errors
    print(json.dumps({'migration':'PASS','quota_answer_persistence':'PASS','reload':'PASS','unknown_keys_preserved':'PASS','uncaught_errors':errors}))
    context.close()
    # No durable database and no writable Web Storage: UI must survive and warn.
    context=browser.new_context();page=context.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
    page.add_init_script("""indexedDB.open=function(){throw new DOMException('database unavailable','SecurityError')};Storage.prototype.setItem=function(){throw new DOMException('unavailable','QuotaExceededError')};""")
    page.goto(URL);page.get_by_role('button',name='继续阅读',exact=True).first.wait_for(timeout=60000)
    page.get_by_role('button',name='继续阅读',exact=True).first.click();page.get_by_text('做题',exact=True).click();page.get_by_role('button',name=re.compile(r'^A\s*claim$')).click()
    page.get_by_role('alert').first.wait_for();assert not errors,errors
    print(json.dumps({'all_persistence_unavailable':'PASS','warning':'PASS','uncaught_errors':errors}))
    browser.close()
