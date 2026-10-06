const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const contractContext = {};
vm.runInNewContext(fs.readFileSync(require.resolve('../text-contract.js'), 'utf8'), contractContext);
const contract = contractContext.VocabTextContract;
for (const fixture of require('./text-fixtures.json')) test(`sentence: ${fixture.sentence}`, () => {
  const offset = fixture.last ? fixture.text.lastIndexOf(fixture.word) : fixture.text.indexOf(fixture.word);
  assert.equal(contract.sentence(fixture.text, offset, offset + fixture.word.length), fixture.sentence);
});
test('phrase limit, en dash and five-word selection', () => {
  assert.equal(contract.phrase('as a matter of fact'), 'as a matter of fact');
  assert.equal(contract.phrase('well–known'), 'well–known');
  assert.equal(contract.phrase('one two three four five six seven eight nine ten eleven twelve thirteen'), null);
});
test('visible DOM inline sentence excludes scripts and hidden elements; reselect republishes', async () => {
  const root = { nodeType: 1, tagName: 'P', parentElement: null, getAttribute: () => null, display: 'block' };
  const hidden = { ...root, tagName: 'SCRIPT', parentElement: root };
  const concealed = { ...root, parentElement: root, hidden: true };
  const nodes = [
    { nodeType: 3, parentElement: hidden, nodeValue: 'PRIVATE_SCRIPT. ' },
    { nodeType: 3, parentElement: concealed, nodeValue: 'PRIVATE_HIDDEN. ' },
    { nodeType: 3, parentElement: root, nodeValue: 'You can ' },
    { nodeType: 3, parentElement: root, nodeValue: 'provide a custom model.' }
  ];
  const range = { commonAncestorContainer: root, startContainer: nodes[3], startOffset: 10, endContainer: nodes[3], endOffset: 16, intersectsNode: n => n === nodes[3] };
  let selection = { rangeCount: 1, toString: () => 'custom', getRangeAt: () => range };
  const events = {}, messages = []; let receiver;
  const context = {
    VocabTextContract: contract, Node: { TEXT_NODE: 3 }, NodeFilter: { SHOW_TEXT: 4 },
    document: { body: root, hasFocus: () => true, createTreeWalker: () => { let n = 0; return { nextNode: () => nodes[n++] }; }, addEventListener: (type, fn) => { events[type] = fn; } },
    window: { getSelection: () => selection, getComputedStyle: e => ({ display: e.display || 'inline', visibility: 'visible' }), addEventListener: (type, fn) => { events[type] = fn; } },
    chrome: { runtime: { onMessage: { addListener: fn => { receiver = fn; } }, sendMessage: async message => { messages.push(message); return { ok: true }; } } },
    setTimeout, clearTimeout, Date
  };
  vm.runInNewContext(fs.readFileSync(require.resolve('../content.js'), 'utf8'), context);
  let captured; receiver({ type: 'current-selection' }, {}, value => { captured = value; });
  assert.equal(captured.context, 'You can provide a custom model.');
  assert.ok(!captured.context.includes('PRIVATE'));
  events.selectionchange(); await new Promise(resolve => setTimeout(resolve, 150));
  selection = null; events.selectionchange(); await new Promise(resolve => setTimeout(resolve, 150));
  selection = { rangeCount: 1, toString: () => 'custom', getRangeAt: () => range };
  events.selectionchange(); await new Promise(resolve => setTimeout(resolve, 150));
  assert.equal(messages.filter(m => m.type === 'cache-context').length, 2);
  events.blur(); assert.equal(messages.at(-1).type, 'invalidate-context');
});
