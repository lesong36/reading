const menuId = 'vocab-capture-lookup';
const endpoint = 'http://127.0.0.1:38473/browser-context';
// Edge includes the Chrome token, so its own UA marker must be checked first.
const userAgent = globalThis.navigator?.userAgent || '';
const browserID = /Edg\//.test(userAgent) ? 'edge'
  : /Chrome\//.test(userAgent) && !/Chromium\/|OPR\/|Vivaldi\//.test(userAgent) ? 'chrome' : null;
const session = crypto.randomUUID();
let revision = 0;
let generation = 0;
let current = null;
let heartbeat = null;
const safeError = error => {
  const message = error instanceof Error ? error.message : '';
  if (/^HTTP \d{3}$/.test(message) || ['请先在扩展窗口中配对拾词助手', '此站点已暂停取句', '当前浏览器不支持扩展取句，请使用 Chrome 或 Edge'].includes(message)) return message;
  return '连接或网页读取失败，请重试';
};
const setStatus = bridgeStatus => chrome.storage.local.set({ bridgeStatus });
const settings = () => chrome.storage.local.get(['pairingToken', 'blockedSites', 'automaticContext']);
const send = async (payload, token) => {
  if (!browserID) throw new Error('当前浏览器不支持扩展取句，请使用 Chrome 或 Edge');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Vocab-Token': token }, body: JSON.stringify({ ...payload, browserID }), signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
  } finally { clearTimeout(timer); }
};
const invalidate = async () => {
  generation++; current = null;
  clearInterval(heartbeat); heartbeat = null;
  const request = { action: 'invalidate', session, revision: ++revision };
  const { pairingToken } = await settings();
  if (pairingToken) await send(request, pairingToken).catch(() => {});
};
const activeSender = async sender => {
  const focused = await chrome.windows.getLastFocused();
  if (!focused.focused || sender.frameId !== 0 || !sender.tab?.id || sender.tab.windowId !== focused.id) return false;
  const tabs = await chrome.tabs.query({ active: true, windowId: focused.id });
  return tabs[0]?.id === sender.tab.id && tabs[0]?.url === sender.tab.url;
};
const publish = async (sender, explicit) => {
  const startGeneration = generation;
  const config = await settings();
  if (!config.pairingToken) throw new Error('请先在扩展窗口中配对拾词助手');
  const site = new URL(sender.tab.url).origin;
  if ((config.blockedSites || []).includes(site)) throw new Error('此站点已暂停取句');
  if (!explicit && config.automaticContext === false) return { ok: false };
  if (!await activeSender(sender)) return { ok: false };
  // Re-read the actual active selection instead of trusting an earlier queued payload.
  const payload = await chrome.tabs.sendMessage(sender.tab.id, { type: 'current-selection', allowUnfocused: explicit }, { frameId: 0 });
  if (!payload || startGeneration !== generation || !await activeSender(sender)) return { ok: false };
  const captureToken = explicit ? crypto.randomUUID() : undefined;
  const request = { ...payload, action: explicit ? 'capture' : 'context', session, revision: ++revision,
    active: true, tabID: sender.tab.id, windowID: sender.tab.windowId, url: sender.tab.url, captureToken };
  await send(request, config.pairingToken);
  if (startGeneration !== generation) return { ok: false };
  current = { tabID: sender.tab.id, windowID: sender.tab.windowId, url: sender.tab.url };
  if (!heartbeat) heartbeat = setInterval(async () => {
    if (!current) return;
    try {
      const tab = await chrome.tabs.get(current.tabID);
      const result = await publish({ tab, frameId: 0 }, false);
      if (!result.ok) await invalidate();
    } catch (_) { await invalidate(); }
  }, 1500);
  await setStatus('已确认活动网页选区');
  if (explicit) {
    const query = new URLSearchParams({ ...payload, token: captureToken });
    await chrome.tabs.create({ url: `vocabcapture://capture?${query}`, active: true });
  }
  return { ok: true };
};
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => chrome.contextMenus.create({ id: menuId, title: '拾词助手：查词', contexts: ['selection'] }));
  // Remove the legacy persisted raw context without reading it.
  chrome.storage.local.remove('bridgePayload');
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === menuId && tab?.id) chrome.tabs.sendMessage(tab.id, { type: 'capture-context' }, { frameId: 0 });
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message?.type === 'pair') {
    const token = String(message.token || '').trim();
    send({ action: 'pair' }, token).then(async () => {
      await chrome.storage.local.set({ pairingToken: token }); await setStatus('配对成功'); respond({ ok: true });
    }).catch(error => respond({ ok: false, error: safeError(error) }));
    return true;
  }
  if (message?.type === 'invalidate-context') {
    // Inactive pages must not erase a newer active tab's selection.
    if (!current || current.tabID === sender.tab?.id) invalidate();
    return;
  }
  if (!['cache-context', 'capture-context'].includes(message?.type) || !sender.tab) return;
  publish(sender, message.type === 'capture-context').then(respond).catch(async error => {
    await setStatus(`取句未完成：${safeError(error)}`); respond({ ok: false, error: safeError(error) });
  });
  return true;
});
chrome.tabs.onActivated.addListener(() => invalidate());
chrome.windows.onFocusChanged.addListener(() => invalidate());
chrome.tabs.onRemoved.addListener(tabID => { if (current?.tabID === tabID) invalidate(); });
chrome.tabs.onUpdated.addListener((tabID, change) => {
  if (current?.tabID === tabID && (change.url || change.status === 'loading')) invalidate();
});
