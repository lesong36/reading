(() => {
  if (globalThis.__vocabCaptureContentLoaded) return;
  globalThis.__vocabCaptureContentLoaded = true;
  const { clean, phrase, sentence } = globalThis.VocabTextContract;
  const visible = node => {
    for (let parent = node.parentElement; parent; parent = parent.parentElement) {
      if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(parent.tagName) || parent.hidden || parent.getAttribute('aria-hidden') === 'true') return false;
      const style = window.getComputedStyle(parent);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    }
    return true;
  };
  const blockFor = node => {
    let element = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    while (element && element !== document.body) {
      if (['block', 'list-item', 'table-cell', 'flex', 'grid'].includes(window.getComputedStyle(element).display)) return element;
      element = element.parentElement;
    }
    return document.body;
  };
  const contextFromSelection = (allowUnfocused = false) => {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount !== 1 || (!allowUnfocused && !document.hasFocus())) return null;
    const word = phrase(selection.toString());
    if (!word) return null;
    const range = selection.getRangeAt(0);
    const root = blockFor(range.commonAncestorContainer);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let text = '', start = null, end = null, node, previousBlock = null;
    while ((node = walker.nextNode())) {
      if (!visible(node)) continue;
      const block = blockFor(node);
      if (previousBlock && previousBlock !== block) text += '\n';
      previousBlock = block;
      const offset = text.length;
      if (node === range.startContainer) start = offset + range.startOffset;
      if (node === range.endContainer) end = offset + range.endOffset;
      // Element-boundary selections are mapped only through visible intersecting nodes.
      if (range.intersectsNode(node)) {
        if (start === null) start = offset;
        end = node === range.endContainer ? offset + range.endOffset : offset + node.nodeValue.length;
      }
      text += node.nodeValue;
      if (text.length > 100000) return null;
    }
    if (start === null || end === null) return null;
    const context = sentence(text, start, end);
    return context.length > word.length ? { word, context } : null;
  };
  let revision = 0, lastSuccessful = '', lastSuccessfulAt = 0, timer;
  const invalidate = () => {
    revision++; lastSuccessful = ''; clearTimeout(timer);
    chrome.runtime.sendMessage({ type: 'invalidate-context' }).catch(() => {});
  };
  const publish = async (explicit = false) => {
    const currentRevision = ++revision;
    const payload = contextFromSelection(explicit);
    if (!payload) { invalidate(); return; }
    const key = `${payload.word}\n${payload.context}`;
    if (!explicit && key === lastSuccessful && Date.now() - lastSuccessfulAt < 500) return;
    try {
      const result = await chrome.runtime.sendMessage({ type: explicit ? 'capture-context' : 'cache-context', payload });
      if (currentRevision === revision && result?.ok) { lastSuccessful = key; lastSuccessfulAt = Date.now(); }
    } catch (_) { /* Failed handoff remains retryable. */ }
  };
  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === 'clear-context') { invalidate(); return; }
    if (message?.type === 'current-selection') { respond(contextFromSelection(message.allowUnfocused === true)); return; }
    if (message?.type === 'capture-context') { publish(true); return; }
    if (message?.type === 'refresh-context') { publish(false); }
  });
  document.addEventListener('selectionchange', () => {
    invalidate(); timer = setTimeout(() => publish(), 120);
  });
  window.addEventListener('blur', invalidate);
  window.addEventListener('pagehide', invalidate);
  window.addEventListener('focus', () => publish());
  document.addEventListener('visibilitychange', () => { if (document.hidden) invalidate(); else publish(); });
  chrome.runtime.sendMessage({ type: 'content-ready' }).catch(() => {});
})();
