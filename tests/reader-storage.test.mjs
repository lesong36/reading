import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync(new URL('../scripts/reader-storage.js', import.meta.url), 'utf8');
function setup() {
 const legacy = { reader_quiz_progress_old: '{"answers":{"q1":2}}', getItem(k) { return this[k] ?? null; } };
 const context = vm.createContext({ localStorage: legacy, sessionStorage: {}, setInterval: () => 1, clearInterval() {} });
 vm.runInContext(source, context); return context.createReaderStorage();
}
test('unavailable database preserves legacy data and current in-memory answers', async () => {
 const store = setup(); await store.ready;
 assert.equal(store.getItem('reader_quiz_progress_old'), '{"answers":{"q1":2}}');
 store.setItem('reader_quiz_progress_old', 'latest');
 assert.equal(store.getItem('reader_quiz_progress_old'), 'latest');
 await assert.rejects(store.flush()); assert.equal(store.status().pending, 1);
});
test('large learning records are managed; small settings and unknown sites are excluded', () => {
 const store = setup();
 for (const key of ['my_local_articles', 'reader_quiz_progress_a', 'reader_article_outline_v1_a', 'reader_vocab_sync_v2_a']) assert.equal(store.isManagedKey(key), true);
 for (const key of ['reader_openai_compat_api_key', 'reader_voice_speed', 'reader_bundled_library_seeded_v47', 'other_app']) assert.equal(store.isManagedKey(key), false);
});
test('security-denied getters cannot prevent initialization', async () => {
 const context = vm.createContext({});
 vm.runInContext("Object.defineProperty(globalThis, 'localStorage', {get(){throw new Error('denied')}}); Object.defineProperty(globalThis, 'sessionStorage', {get(){throw new Error('denied')}})", context);
 vm.runInContext(source, context); const store = context.createReaderStorage(); await store.ready;
 assert.equal(store.status().indexedDB, false); assert.equal(store.getItem('missing'), null);
});
test('oversized settings stay in memory with visible pending durability state', async () => {
 const store = setup(); await store.ready; let notified = false; store.subscribe(() => { notified = true; });
 const value = 'x'.repeat(9000); store.setItem('reader_openai_compat_model', value);
 assert.equal(store.getItem('reader_openai_compat_model'), value);
 assert.equal(store.status().pending > 0, true); assert.equal(notified, true); await assert.rejects(store.flush());
 assert.equal(Boolean(store.status().error), true);
});
test('overflowed settings remain outside the clear-learning-data scope', async () => {
 const store = setup(); await store.ready;
 store.setItem('reader_openai_compat_model', 'x'.repeat(9000));
 assert.equal(store.isManagedKey('reader_openai_compat_model'), false);
 await assert.rejects(store.flush());
});
