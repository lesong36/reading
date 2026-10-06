/* Shared public fixtures verify this contract against SelectionTextContract.swift. */
(function (root) {
  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const phrase = input => {
    const value = clean(input).replace(/^[\s“”"'(（\[]+|[”"'’).,!?;:）\]]+$/g, '');
    return /^[A-Za-z]+(?:['’–-][A-Za-z]+)*(?:[ –-][A-Za-z]+(?:['’–-][A-Za-z]+)*){0,11}$/.test(value) ? value : null;
  };
  const sentence = (text, start, end) => {
    const boundary = index => {
      const char = text[index];
      if ('\n!?。！？'.includes(char)) return true;
      if (char !== '.') return false;
      if (/\d/.test(text[index - 1] || '') && /\d/.test(text[index + 1] || '')) return false;
      const preceding = text.slice(0, index).split(/\s+/).pop().toLowerCase();
      return !['dr', 'mr', 'mrs', 'ms', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'e.g', 'i.e'].includes(preceding) && !/^[a-z]$/.test(preceding);
    };
    while (start > 0 && !boundary(start - 1)) start--;
    while (end < text.length && !boundary(end)) end++;
    if (end < text.length) end++;
    return clean(text.slice(start, end)).slice(0, 800);
  };
  root.VocabTextContract = { clean, phrase, sentence };
  if (typeof module !== 'undefined') module.exports = root.VocabTextContract;
})(globalThis);
