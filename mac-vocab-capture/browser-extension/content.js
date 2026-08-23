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

  const sentenceForRange = (range) => {
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
    const context = sentenceForRange(selection.getRangeAt(0));
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
})();
