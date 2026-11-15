import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');
const source=html.slice(html.indexOf('      const persistQuizProgress ='),html.indexOf('      const queueVocabularyMutation ='));
test('answer boundary journals only changed fields before projecting UI',()=>{
 const calls=[];const old={answers:Object.fromEntries(Array.from({length:10000},(_,i)=>['q'+i,0]))};
 const context={quizProgress:old,currentArticleId:'article',user:{id:'owner'},cloudAccountRef:{current:{generation:1}},cloudDataLoadedRef:{current:true},deltaSyncRef:{current:{__readerOpened:true,__generation:1,snapshot:()=>({userID:'owner'}),enqueueQuizChange:event=>{calls.push(['answer_event',event.eventID,event]);return Promise.resolve();}}},crypto:{randomUUID:()=> 'event'},trySetLocalStorage:()=>calls.push('local'),getQuizProgressStorageKey:x=>x,setQuizProgress:x=>calls.push('ui'),scheduleCloudSyncRetry:()=>{}};
 vm.createContext(context);vm.runInContext(source+'\npersistQuizProgress({...quizProgress,answers:{...quizProgress.answers,q1:2}});',context);
 assert.equal(calls[0][0],'answer_event');assert.deepEqual(JSON.parse(JSON.stringify(calls[0][2].changes)),{answers:{q1:2}});
 assert.ok(JSON.stringify(calls[0]).length<500);assert.equal(calls.at(-1),'ui');
});
test('account mismatch does not journal an answer into another owner outbox',()=>{
 let journaled=false;const context={quizProgress:{answers:{}},currentArticleId:'article',user:{id:'new'},cloudAccountRef:{current:{generation:3}},cloudDataLoadedRef:{current:true},deltaSyncRef:{current:{__readerOpened:true,__generation:3,snapshot:()=>({userID:'old'}),enqueueQuizChange:()=>{journaled=true;}}},trySetLocalStorage:()=>{},getQuizProgressStorageKey:x=>x,setQuizProgress:()=>{}};
 vm.createContext(context);vm.runInContext(source+'\npersistQuizProgress({answers:{q1:2}});',context);assert.equal(journaled,false);
});

test('returning to the same account rejects an earlier generation outbox',()=>{
 let journaled=false;const context={quizProgress:{answers:{}},currentArticleId:'article',user:{id:'owner'},cloudAccountRef:{current:{generation:3}},deltaSyncRef:{current:{__readerOpened:true,__generation:1,snapshot:()=>({userID:'owner'}),enqueueQuizChange:()=>{journaled=true;}}},trySetLocalStorage:()=>{},getQuizProgressStorageKey:x=>x,setQuizProgress:()=>{}};
 vm.createContext(context);vm.runInContext(source+'\npersistQuizProgress({answers:{q1:2}});',context);assert.equal(journaled,false);
});
