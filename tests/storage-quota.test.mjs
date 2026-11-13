import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const helper = html.slice(html.indexOf('const pendingQuizWrites ='), html.indexOf('const clearLocalLearningStorage ='));
for (const name of ['QuotaExceededError', 'SecurityError']) {
  test(`storage ${name} cannot crash answering`, () => {
    const context = vm.createContext({ localStorage: { setItem() { throw Object.assign(new Error('unavailable'), { name }); } }, document: { getElementById: () => ({ textContent: "" }) }, console: { warn() {} } });
    vm.runInContext(helper, context);
    assert.equal(vm.runInContext("trySetLocalStorage('reader_quiz_progress_test', JSON.stringify({ answers: { q1: 2 } }))", context), false);
  });
}
test('successful writes preserve the progress payload', () => {
  const stored = new Map();
  const context = vm.createContext({ localStorage: { setItem: (k, v) => stored.set(k, v) }, console });
  vm.runInContext(helper, context);
  assert.equal(vm.runInContext("trySetLocalStorage('progress', '{\"answers\":{\"q1\":2}}')", context), true);
  assert.deepEqual(JSON.parse(stored.get('progress')), { answers: { q1: 2 } });
});
test('all application storage writes use the guarded helper', () => {
  assert.equal((html.match(/localStorage\.setItem\(/g) || []).length, 1);
  assert.match(html, /trySetLocalStorage\(key, JSON\.stringify\(quizProgress\)\)/);
});

test('quota fallback restores latest answers and includes them in cloud enumeration', () => {
  const context = vm.createContext({
    localStorage: { setItem() { throw new Error('full'); }, getItem: () => '{"answers":{"q1":0}}' },
    sessionStorage: { setItem() {}, removeItem() {}, getItem: () => null },
    document: { getElementById: () => ({ textContent: '' }) }, console: { warn() {} }
  });
  vm.runInContext(helper, context);
  vm.runInContext("trySetLocalStorage('reader_quiz_progress_test', '{\"answers\":{\"q1\":2}}')", context);
  assert.equal(vm.runInContext("JSON.parse(readQuizStorage('reader_quiz_progress_test')).answers.q1", context), 2);
  assert.equal(vm.runInContext("quizStorageKeys().includes('reader_quiz_progress_test')", context), true);
});
