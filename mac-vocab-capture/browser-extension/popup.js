const status = document.querySelector('#status');
chrome.storage.local.get(['bridgeStatus', 'bridgePayload'], ({ bridgeStatus, bridgePayload }) => {
  status.textContent = bridgePayload
    ? `${bridgeStatus || '已就绪'}：${bridgePayload.context}`
    : (bridgeStatus || '请先刷新阅读网页；若是本地网页，请在扩展详情中开启“允许访问文件网址”。');
});
