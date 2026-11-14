import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');
const source=html.slice(html.indexOf('const normalizeQuizAnswer ='),html.indexOf('const getQuizProgressStorageKey ='));
function merge(local,cloud){const ctx=vm.createContext({local,cloud});vm.runInContext(source,ctx);return JSON.parse(vm.runInContext('JSON.stringify(mergeQuizProgress(local,cloud))',ctx));}
test('old browser answers cannot replace newer cloud submission',()=>{
 const result=merge({answers:{q1:0},lastAnsweredAt:'2026-11-12T12:00:00Z'}, {answers:{q1:2,q2:1},lastAnsweredAt:'2026-11-13T12:00:00Z',submitted:true,submittedAt:'2026-11-13T12:00:01Z'});
 assert.deepEqual(result.answers,{q1:2,q2:1});assert.equal(result.submitted,true);
});
test('new local answer survives a stale cloud snapshot while retaining other answers',()=>{
 const result=merge({answers:{q1:1},lastAnsweredAt:'2026-11-14T12:00:00Z'},{answers:{q1:2,q2:0},lastAnsweredAt:'2026-11-13T12:00:00Z'});
 assert.deepEqual(result.answers,{q1:1,q2:0});
});
test('answer and position changes trigger upload after local answer save',()=>{
 const saver=html.indexOf('trySetLocalStorage(key, JSON.stringify(quizProgress))');
 const upload=html.indexOf('const quizProgressByArticle = {}',saver);
 assert.ok(upload>saver);
 assert.match(html,/cloudWriteRevision, user, quizProgress, currentArticleId, selectedSentence\?\.id/);
});
test('foreground, visibility and periodic refresh do not depend on another edit',()=>{
 assert.match(html,/addEventListener\('focus', resumeCloudSync\)/);
 assert.match(html,/addEventListener\('visibilitychange', resumeCloudSync\)/);
 assert.match(html,/setInterval\(resumeCloudSync, 30000\)/);
 assert.match(html,/if \(articleId === activeQuizArticleRef.current\) setQuizProgress\(progress\)/);
});
test('changes arriving during upload schedule a follow-up upload',()=>{
 assert.match(html,/if \(cloudWriteInFlightRef.current\) \{ cloudWriteQueuedRef.current = true; return; \}/);
 assert.match(html,/if \(cloudWriteQueuedRef.current\) \{\s*cloudWriteQueuedRef.current = false;\s*setCloudWriteRevision/);
});

test('unrelated stale article positions do not move a newer cloud cursor backward',()=>{
 const local={a:{sentenceId:'old',updatedAt:'2026-11-12T00:00:00Z'},b:{sentenceId:'new-b',updatedAt:'2026-11-14T00:00:00Z'}};
 const cloud={a:{sentenceId:'new-a',updatedAt:'2026-11-13T00:00:00Z'}};
 const ctx=vm.createContext({local,cloud});vm.runInContext(source,ctx);
 const result=vm.runInContext('mergeReadingPositions(local,cloud)',ctx);
 assert.equal(result.a.sentenceId,'new-a');assert.equal(result.b.sentenceId,'new-b');
});
test('a stalled request has a deadline instead of holding sync forever',async()=>{
 const helper=html.slice(html.indexOf('const withCloudDeadline ='),html.indexOf('const SYNC_VAULT_VERSION ='));
 const ctx=vm.createContext({setTimeout,clearTimeout});vm.runInContext(helper,ctx);
 await assert.rejects(vm.runInContext('withCloudDeadline(new Promise(()=>{}),5)',ctx),/超时/);
 assert.equal(await vm.runInContext('withCloudDeadline(Promise.resolve(3),5)',ctx),3);
});
