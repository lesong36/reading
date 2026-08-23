const menuId = 'vocab-capture-lookup';

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: menuId,
      title: '拾词助手：查词',
      contexts: ['selection']
    });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== menuId || !tab?.id) return;
  chrome.tabs.sendMessage(tab.id, { type: 'capture-context' });
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'content-ready') {
    chrome.storage.local.set({ bridgeStatus: '网页取句脚本已就绪' });
    return;
  }
  if (message?.type !== 'cache-context' || !message.payload) return;

  fetch('http://127.0.0.1:38473/browser-context', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(message.payload)
  })
    .then(() => {
      chrome.storage.local.set({ bridgeStatus: '已把原句交给拾词助手', bridgePayload: message.payload });
      sendResponse({ ok: true });
    })
    .catch(error => {
      chrome.storage.local.set({ bridgeStatus: `无法连接本机拾词助手：${String(error)}` });
      sendResponse({ ok: false, error: String(error) });
    });
  return true;
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status !== 'complete' || !/^https?:|^file:/.test(tab.url || '')) return;
  chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] }).catch(() => {
    // file:// pages require the browser's explicit “允许访问文件网址” switch.
  });
});
