"""Prove a configuration archived in IDB is restored before client creation."""
import os
from playwright.sync_api import sync_playwright
URL=os.environ.get('READING_URL','http://localhost:8776').rstrip('/')
with sync_playwright() as p:
 b=p.chromium.launch(headless=True);page=b.new_page()
 page.route('**/storage-harness.html',lambda route:route.fulfill(content_type='text/html',body=f'<script src="{URL}/scripts/reader-storage.js"></script>'))
 page.goto(URL+'/storage-harness.html');page.wait_for_function('typeof createReaderStorage === "function"')
 page.evaluate('''async () => {const s=createReaderStorage();await s.ready;s.setItem('reader_supabase_config',JSON.stringify({url:'https://storage-config-test.invalid',publishableKey:'test-key',padding:'x'.repeat(9000)}));await s.flush();if(localStorage.getItem('reader_supabase_config')!==null)throw Error('config not archived');s.dispose()}''')
 page.route('**/local-config.js',lambda route:route.fulfill(content_type='application/javascript',body='window.__reader_local_config = {};'))
 page.route('https://esm.sh/@supabase/supabase-js@2?bundle',lambda route:route.fulfill(content_type='application/javascript',headers={'Access-Control-Allow-Origin':'*'},body="export function createClient(url,key){window.__testClientUrl=url;return {auth:{getSession:()=>Promise.resolve({data:{session:null}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})}}}"))
 page.goto(URL);page.wait_for_function("window.__testClientUrl === 'https://storage-config-test.invalid'",timeout=60000)
 print('IDB configuration restored before client initialization PASS');b.close()
