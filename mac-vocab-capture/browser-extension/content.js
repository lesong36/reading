(() => {
  const token = "[A-Za-z]+(?:['’][A-Za-z]+)?";
  const phrasePattern = new RegExp(`^${token}(?:[\\s-]+${token}){0,11}$`);

  const clean = (value = '') => String(value).replace(/\s+/g, ' ').trim();
  const textOffsetInDocument = (container, offset) => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let total = 0;
    let node;
    while ((node = walker.nextNode())) {
      if (node === container) return total + Math.min(offset, node.nodeValue.length);
      total += node.nodeValue.length;
    }
    const before = document.createRange();
    before.selectNodeContents(document.body);
    before.setEnd(container, offset);
    return before.toString().length;
  };

  const browserSentenceForRange = (range) => {
    const selection = window.getSelection();
    if (!selection || typeof selection.modify !== 'function') return null;
    const original = [];
    for (let index = 0; index < selection.rangeCount; index += 1) original.push(selection.getRangeAt(index).cloneRange());
    try {
      const start = range.cloneRange();
      start.collapse(true);
      selection.removeAllRanges();
      selection.addRange(start);
      selection.modify('extend', 'backward', 'sentence');
      const leading = selection.getRangeAt(0).cloneRange();

      const end = range.cloneRange();
      end.collapse(false);
      selection.removeAllRanges();
      selection.addRange(end);
      selection.modify('extend', 'forward', 'sentence');
      const trailing = selection.getRangeAt(0).cloneRange();

      const sentence = document.createRange();
      sentence.setStart(leading.startContainer, leading.startOffset);
      sentence.setEnd(trailing.endContainer, trailing.endOffset);
      const result = clean(sentence.toString()).slice(0, 800);
      return result.length > clean(range.toString()).length ? result : null;
    } catch (_) {
      return null;
    } finally {
      selection.removeAllRanges();
      original.forEach(saved => selection.addRange(saved));
    }
  };

  const domSentenceForRange = (range) => {
    // Use the text node that actually owns the browser selection. A nearest
    // div may contain an entire article with repeated phrases, making offsets
    // point to the wrong occurrence.
    const text = document.body.textContent || '';
    const startOffset = textOffsetInDocument(range.startContainer, range.startOffset);
    const endOffset = textOffsetInDocument(range.endContainer, range.endOffset);
    const left = Math.max(
      text.lastIndexOf('.', Math.max(0, startOffset - 1)),
      text.lastIndexOf('!', Math.max(0, startOffset - 1)),
      text.lastIndexOf('?', Math.max(0, startOffset - 1)),
      text.lastIndexOf('。', Math.max(0, startOffset - 1)),
      text.lastIndexOf('！', Math.max(0, startOffset - 1)),
      text.lastIndexOf('？', Math.max(0, startOffset - 1))
    );
    const rightCandidates = ['.', '!', '?', '。', '！', '？']
      .map(mark => text.indexOf(mark, endOffset))
      .filter(index => index >= 0);
    const right = rightCandidates.length ? Math.min(...rightCandidates) + 1 : text.length;
    return clean(text.slice(left + 1, right)).slice(0, 800);
  };

  const contextFromSelection = () => {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount !== 1) return null;
    const word = clean(selection.toString()).replace(/^[“”"'(（\[]+|[”"'’).,!?;:）\]]+$/g, '');
    if (!phrasePattern.test(word)) return null;
    const range = selection.getRangeAt(0);
    const context = browserSentenceForRange(range) || domSentenceForRange(range);
    return context.length > word.length ? { word, context } : null;
  };

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== 'capture-context') return;
    const payload = contextFromSelection();
    if (!payload) return;
    const query = new URLSearchParams(payload).toString();
    const frame = document.createElement('iframe');
    frame.style.display = 'none';
    frame.src = `vocabcapture://capture?${query}`;
    document.documentElement.appendChild(frame);
    window.setTimeout(() => frame.remove(), 1500);
  });

  let lastPublished = '';
  let publishing = false;
  const publishCurrentContext = () => {
    if (publishing) return;
    const payload = contextFromSelection();
    if (!payload) return;
    const key = `${payload.word}\n${payload.context}`;
    if (key === lastPublished) return;
    lastPublished = key;
    fetch('http://127.0.0.1:38473/browser-context', {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
      body: JSON.stringify(payload)
    }).catch(() => {});
  };
  document.addEventListener('selectionchange', () => window.setTimeout(publishCurrentContext, 0));
})();
