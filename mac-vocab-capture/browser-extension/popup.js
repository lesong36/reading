const status = document.querySelector('#status');
const automatic = document.querySelector('#automatic');
const siteButton = document.querySelector('#site');
let site = null, blocked = [];
(async () => {
  const config = await chrome.storage.local.get(['bridgeStatus', 'pairingToken', 'blockedSites', 'automaticContext']);
  status.textContent = config.bridgeStatus || (config.pairingToken ? '已配对；刷新网页后选词。' : '尚未配对');
  automatic.checked = config.automaticContext !== false;
  blocked = config.blockedSites || [];
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  try { site = new URL(tab.url).origin; } catch (_) {}
  siteButton.disabled = !site;
  siteButton.textContent = blocked.includes(site) ? '恢复当前站点' : '暂停当前站点';
})();
document.querySelector('#pair').onclick = async () => {
  const response = await chrome.runtime.sendMessage({ type: 'pair', token: document.querySelector('#token').value });
  document.querySelector('#token').value = '';
  status.textContent = response.ok ? '配对成功' : `配对失败：${response.error}`;
};
automatic.onchange = async () => {
  await chrome.storage.local.set({ automaticContext: automatic.checked });
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, { type: automatic.checked ? 'refresh-context' : 'capture-disabled' }).catch(() => {});
  // Send invalidation through the content script so tab identity is preserved.
  if (!automatic.checked) await chrome.tabs.sendMessage(tab.id, { type: 'clear-context' }).catch(() => {});
};
siteButton.onclick = async () => {
  blocked = blocked.includes(site) ? blocked.filter(item => item !== site) : [...blocked, site];
  await chrome.storage.local.set({ blockedSites: blocked });
  siteButton.textContent = blocked.includes(site) ? '恢复当前站点' : '暂停当前站点';
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, { type: 'clear-context' }).catch(() => {});
};
document.querySelector('#lookup').onclick = async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, { type: 'capture-context' }).catch(() => {});
};
document.querySelector('#forget').onclick = async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, { type: 'clear-context' }).catch(() => {});
  await chrome.storage.local.remove(['pairingToken', 'bridgeStatus', 'bridgePayload']);
  status.textContent = '已忘记配对；在拾词助手中撤销可使旧配对码立即失效。';
};
