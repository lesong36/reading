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
  if (message?.type !== 'cache-context' || !message.payload) return;

  fetch('http://127.0.0.1:38473/browser-context', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(message.payload)
  })
    .then(() => sendResponse({ ok: true }))
    .catch(error => sendResponse({ ok: false, error: String(error) }));
  return true;
});
