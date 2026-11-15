"""Real Chrome/Edge IndexedDB durability; isolated fake RPC, no learner accounts."""
import json, os, threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from playwright.sync_api import sync_playwright
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**k): super().__init__(*a,directory=ROOT,**k)
 def log_message(self,*a): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
url=f'http://127.0.0.1:{server.server_port}/scripts/reader-delta-sync.js'
with sync_playwright() as p:
 for channel in ['chrome','msedge']:
  browser=p.chromium.launch(channel=channel,headless=True)
  context=browser.new_context(); page=context.new_page()
  page.goto(url); page.add_script_tag(url=url)
  result=page.evaluate('''async () => {
    const client={rpc:async()=>{throw new Error('offline')}};
    const sync=createReaderDeltaSync({client,userID:'browser-A',isCurrentAccount:()=>true});
    await sync.open(); await sync.enqueue('reading_position','article-1',{sentenceId:'s1'});
    try { await sync.sync(); } catch (_) {}
    return sync.snapshot();
  }''')
  assert len(result['pending'])==1,result
  page.reload();page.add_script_tag(url=url)
  result=page.evaluate('''async () => {
    const a=createReaderDeltaSync({client:{},userID:'browser-A',isCurrentAccount:()=>true});await a.open();
    const b=createReaderDeltaSync({client:{},userID:'browser-B',isCurrentAccount:()=>true});await b.open();
    return {a:a.snapshot(),b:b.snapshot()};
  }''')
  assert len(result['a']['pending'])==1,result
  assert len(result['b']['pending'])==0,result
  result=page.evaluate('''async () => {
    const receipts=new Map(), log=[];let dropped=false;
    const client={rpc:async(name,args)=>{
      if(name==='reader_delta_push'){
        const acknowledgements=args.p_operations.map(op=>{
          if(receipts.has(op.operationID)) return receipts.get(op.operationID);
          const ack={operationID:op.operationID,status:'applied',version:1};
          receipts.set(op.operationID,ack);log.push({...op,cursor:log.length+1,version:1,deleted:op.kind==='delete'});return ack;
        });
        if(!dropped){dropped=true;throw new Error('committed response lost');}
        return {data:{epoch:'test-epoch',acknowledgements}};
      }
      return {data:{epoch:'test-epoch',changes:log.filter(e=>e.cursor>args.p_cursor),nextCursor:log.length,hasMore:false}};
    }};
    const a=createReaderDeltaSync({client,userID:'loss',isCurrentAccount:()=>true});await a.open();
    await a.enqueue('reading_positions','article',{sentenceId:'new'});
    try{await a.sync();}catch(_){}
    const retained=a.snapshot().pending.length;
    await a.sync();const recovered=a.snapshot().pending.length;
    const b=createReaderDeltaSync({client,userID:'tabs',isCurrentAccount:()=>true});
    const c=createReaderDeltaSync({client,userID:'tabs',isCurrentAccount:()=>true});await b.open();await c.open();
    await Promise.all([b.enqueue('reading_positions','one',{sentenceId:'1'}),c.enqueue('reading_positions','two',{sentenceId:'2'})]);
    const d=createReaderDeltaSync({client,userID:'tabs',isCurrentAccount:()=>true});await d.open();
    return {retained,recovered,uniqueServerOperations:receipts.size,concurrentPending:d.snapshot().pending.length};
  }''')
  assert result=={'retained':1,'recovered':0,'uniqueServerOperations':1,'concurrentPending':2},result
  print(json.dumps({'browser':channel,'responseLossAndConcurrentTabs':result,'result':'PASS'}),flush=True)
  print(json.dumps({'browser':channel,'offlineQueue':1,'afterRefresh':1,'otherAccountQueue':0,'result':'PASS'}),flush=True)
  browser.close()
server.shutdown()
