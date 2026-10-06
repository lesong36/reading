const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
function fixture({ ok = true, active = true, readSelection, userAgent = "Mozilla/5.0 Chrome/143.0.0.0 Safari/537.36" } = {}) {
  const events = {}, requests = [], persisted = [], opened = [];
  const tab = { id: 7, windowId: 2, url: 'https://example.test/read' };
  const selection = { word: 'bank', context: 'The bank is closed.' };
  const store = { pairingToken: 'FAKE_PAIR_TOKEN' };
  const event = key => ({ addListener: fn => { events[key] = fn; } });
  const context = {
    navigator: { userAgent }, crypto: webcrypto, AbortController, setTimeout, clearTimeout, setInterval: () => 1, clearInterval: () => {}, URL, URLSearchParams,
    fetch: async (_url, options) => { requests.push({ ...options, payload: JSON.parse(options.body) }); return { ok, status: ok ? 204 : 401 }; },
    chrome: {
      storage: { local: { get: async () => ({ ...store }), set: async value => { persisted.push(value); Object.assign(store, value); }, remove: async keys => { for (const key of [keys].flat()) delete store[key]; } } },
      windows: { getLastFocused: async () => ({ id: 2, focused: true }), onFocusChanged: event('focus') },
      tabs: { query: async () => [active ? tab : { ...tab, id: 8 }], sendMessage: readSelection || (async () => selection), get: async () => tab,
        create: async value => { opened.push(value); }, onActivated: event('activate'), onRemoved: event('remove'), onUpdated: event('update') },
      runtime: { onInstalled: event('installed'), onMessage: event('message') },
      contextMenus: { onClicked: event('menu'), removeAll: callback => callback(), create: () => {} }
    }
  };
  vm.createContext(context); vm.runInContext(fs.readFileSync(require.resolve('../background.js'), 'utf8'), context);
  const sendMessage = (type, payload = selection) => new Promise(resolve => { events.message({ type, payload }, { tab, frameId: 0 }, resolve); });
  return { context, events, requests, persisted, opened, sendMessage };
}
test('HTTP rejection stays a failure and never persists raw context', async () => {
  const f = fixture({ ok: false });
  const response = await f.sendMessage('cache-context');
  assert.equal(response.ok, false); assert.match(response.error, /HTTP 401/);
  assert.ok(f.persisted.every(value => !('bridgePayload' in value) && !('context' in value)));
});
test('unexpected browser errors cannot persist a private URL or selected text', async () => {
  const f = fixture({ readSelection: async () => { throw new Error('PRIVATE_PAGE_URL PRIVATE_SELECTION'); } });
  const response = await f.sendMessage('cache-context');
  assert.equal(response.ok, false);
  assert.ok(!JSON.stringify(f.persisted).includes('PRIVATE'));
  assert.ok(!response.error.includes('PRIVATE'));
});
test('active page is freshly read; inactive tab cannot publish', async () => {
  const inactive = fixture({ active: false });
  assert.equal((await inactive.sendMessage('cache-context')).ok, false);
  assert.equal(inactive.requests.length, 0);
  const active = fixture();
  assert.equal((await active.sendMessage('cache-context', { word: 'stale', context: 'stale' })).ok, true);
  assert.equal(active.requests[0].payload.word, 'bank');
  assert.equal(active.requests[0].payload.tabID, 7);
  assert.equal(active.requests[0].payload.active, true);
});
test('navigation during selection handshake discards pending result', async () => {
  let release;
  const f = fixture({ readSelection: () => new Promise(resolve => { release = resolve; }) });
  const response = f.sendMessage('cache-context');
  await new Promise(resolve => setImmediate(resolve));
  f.events.activate();
  release({ word: 'bank', context: 'The bank is closed.' });
  assert.equal((await response).ok, false);
  assert.ok(f.requests.every(request => request.payload.action !== 'context'));
});
test('explicit lookup URL uses a nonce, never the paired secret', async () => {
  const f = fixture();
  assert.equal((await f.sendMessage('capture-context')).ok, true);
  const url = new URL(f.opened[0].url);
  assert.notEqual(url.searchParams.get('token'), 'FAKE_PAIR_TOKEN');
  assert.equal(url.searchParams.get('token'), f.requests[0].payload.captureToken);
  assert.equal(f.requests[0].payload.action, 'capture');
  assert.equal(f.requests[0].payload.browserID, 'chrome');
});

test('Chrome and Edge publish explicit publisher IDs on context and invalidation', async () => {
  for (const [userAgent, browserID] of [
    ['Mozilla/5.0 Chrome/143.0.0.0 Safari/537.36', 'chrome'],
    ['Mozilla/5.0 Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0', 'edge']
  ]) {
    const f = fixture({ userAgent });
    assert.equal((await f.sendMessage('cache-context')).ok, true);
    f.events.activate();
    await new Promise(resolve => setImmediate(resolve));
    assert.ok(f.requests.length >= 2);
    assert.ok(f.requests.every(request => request.payload.browserID === browserID));
  }
});

test('pairing includes the publisher identity; unsupported worker UA never sends context', async () => {
  const chrome = fixture();
  const paired = await new Promise(resolve => chrome.events.message({ type: 'pair', token: 'FAKE_NEW_TOKEN' }, {}, resolve));
  assert.equal(paired.ok, true);
  assert.equal(chrome.requests[0].payload.action, 'pair');
  assert.equal(chrome.requests[0].payload.browserID, 'chrome');
  for (const userAgent of ['', 'Mozilla/5.0 Firefox/144.0', 'Mozilla/5.0 Chromium/143.0 Chrome/143.0']) {
    const f = fixture({ userAgent });
    const response = await f.sendMessage('cache-context');
    assert.equal(response.ok, false);
    assert.equal(f.requests.length, 0);
    assert.match(response.error, /Chrome.*Edge/);
  }
});
