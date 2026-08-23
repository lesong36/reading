(() => {
  const token = "[A-Za-z]+(?:['’][A-Za-z]+)?";
  const phrasePattern = new RegExp(`^${token}(?:[\\s-]+${token}){0,11}$`);

  const clean = (value = '') => String(value).replace(/\s+/g, ' ').trim();
  const sentenceForRange = (range) => {
    const semanticRoot = (range.startContainer.nodeType === Node.ELEMENT_NODE
      ? range.startContainer
      : range.startContainer.parentElement)?.closest('p, li, blockquote, td, th, h1, h2, h3, h4, h5, h6, article, section, div') || document.body;
    const before = document.createRange();
    before.selectNodeContents(semanticRoot);
    before.setEnd(range.startContainer, range.startOffset);
    const text = semanticRoot.textContent || '';
    const startOffset = before.toString().length;
    const endOffset = startOffset + range.toString().length;
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
