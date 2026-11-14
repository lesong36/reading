import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
test('application writes and reads use the managed storage boundary', () => {
  assert.doesNotMatch(html, /\blocalStorage\.(setItem|getItem|removeItem)\(/);
  assert.match(html, /readerStorage.ready.then\(\(\) => \{ initializeSupabase\(\); root.render/);
  assert.match(html, /scripts\/reader-storage.js/);
});
test('storage failure cannot escape an application save', () => {
  const helper = html.slice(html.indexOf('const trySetLocalStorage ='), html.indexOf('const clearLocalLearningStorage ='));
  for (const name of ['QuotaExceededError', 'SecurityError']) {
    const context = vm.createContext({ readerStorage: { setItem() { throw Object.assign(new Error('full'), { name }); } }, console: { warn() {} } });
    vm.runInContext(helper, context);
    assert.equal(vm.runInContext("trySetLocalStorage('reader_quiz_progress_test', '{}')", context), false);
  }
});
test('management runs periodically and on returning to the page', () => {
  assert.match(html, /setInterval\(check, 5 \* 60 \* 1000\)/);
  assert.match(html, /addEventListener\('visibilitychange', onVisible\)/);
  assert.match(html, /readerStorage\.isManagedKey\(key\)/);
  assert.match(html, /await readerStorage.flush\(\)/);
});
test('both distributed HTML entries include the same storage integration', () => {
  const alias = fs.readFileSync(new URL('../英语长难句交互阅读解析.html', import.meta.url), 'utf8');
  assert.equal(alias, html);
});
test('legacy file backup cannot overwrite a newer primary bookshelf', () => {
  assert.match(html, /if \(!hasPrimaryArticles && data.savedArticles.length > 0\) setSavedArticles/);
  assert.match(html, /if \(!hasPrimaryCompletions && Object.keys/);
});
