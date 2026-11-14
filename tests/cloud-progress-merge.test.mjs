import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const start = html.indexOf('    const quizVersionTime =');
const end = html.indexOf('    const getQuizProgressStorageKey =', start);
assert.ok(start >= 0, 'versioned progress helpers must be integrated');
const functions = html.slice(start, end);
const normalize = html.slice(html.indexOf('    const normalizeQuizAnswer ='), html.indexOf('    const getWordBankAnswers ='));
const context = vm.createContext({}); vm.runInContext(normalize + functions + '\nglobalThis.merge = mergeQuizProgress;globalThis.norm=normalizeQuizProgress;', context);
const t = n => `2026-11-14T00:00:0${n}.000Z`;
const merge = (a,b) => JSON.parse(JSON.stringify(context.merge(a,b)));
test('per-answer versions preserve q1 while another stale device edits q2', () => {
 const result = merge({ answers:{q1:2},answerUpdatedAt:{q1:t(3)} }, {answers:{q1:0,q2:1},answerUpdatedAt:{q1:t(1),q2:t(4)},lastAnsweredAt:t(4)});
 assert.deepEqual(result.answers,{q1:2,q2:1});
});
test('answer and locator deletions cannot resurrect from stale snapshots', () => {
 const a={answerDeletedAt:{q1:t(3)},locatorDeletedAt:{q1:t(3)}};
 const b={answers:{q1:2},locatorSentenceIds:{q1:'s1'},lastAnsweredAt:t(2)};
 for (const result of [merge(a,b),merge(b,a)]) {assert.deepEqual(result.answers,{});assert.deepEqual(result.locatorSentenceIds,{});assert.equal(result.answerDeletedAt.q1,t(3));}
});
test('reset suppresses older answers and submission but permits a later answer', () => {
 const result=merge({resetAt:t(3),submitted:false,submissionUpdatedAt:t(3)}, {answers:{q1:2,q2:1},answerUpdatedAt:{q1:t(2),q2:t(4)},submitted:true,submittedAt:t(2)});
 assert.deepEqual(result.answers,{q2:1});assert.equal(result.submitted,false);
});
test('newer explicit unsubmit overrides old submitted snapshot',()=>{
 assert.equal(merge({submitted:false,submissionUpdatedAt:t(4)},{submitted:true,submittedAt:t(2)}).submitted,false);
});
test('legacy records preserve answers and deterministic union',()=>{
 const a={answers:{q1:1}},b={answers:{q2:2}};assert.deepEqual(merge(a,b).answers,{q1:1,q2:2});assert.deepEqual(merge(a,b),merge(b,a));
});
test('an explicit epoch version is not promoted by later unrelated activity',()=>{
 const initial = merge({answers:{q1:1}},{answers:{q2:2},answerUpdatedAt:{q2:t(4)},lastAnsweredAt:t(4)});
 const result = merge(initial,{answers:{q1:3},answerUpdatedAt:{q1:t(2)}});
 assert.equal(result.answers.q1,3);
});
