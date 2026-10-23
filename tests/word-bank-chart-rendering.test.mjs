import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { parseBook } from '../scripts/attach-rfd-markdown-quiz.mjs';

const babelContext = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../vendor/babel.min.js', import.meta.url), 'utf8'), babelContext);
const Babel = babelContext.Babel;
const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const renderer = source.slice(source.indexOf('const renderWordBankCompareItem ='), source.indexOf('const renderWordBankGroupedChart ='));
const compiled = Babel.transform(`${renderer}; renderWordBankCompareItem;`, { presets: ['react'] }).code;
const renderItem = vm.runInNewContext(compiled, {
  React: { createElement: (type, props, ...children) => ({ type, props, children: children.flat(Infinity) }) },
  renderWordBankInlineBlank: blankId => ({ type: 'blank', blankId })
});
const blankIdsIn = node => node?.type === 'blank' ? [node.blankId]
  : node?.children ? node.children.flatMap(blankIdsIn) : [];

test('renders all three answer targets for the dogs knowledge chart without placeholder text', () => {
  const question = parseBook('rfd4').find(unit => unit.unit === 13).questions.at(-1);
  const targets = question.knowledgeChart.groups.flatMap(group => group.items.flatMap((item, index) => blankIdsIn(renderItem(item, index))));
  assert.deepEqual(targets, question.blanks.map(blank => blank.id));
});

test('renders each assigned blank once for every shipped word-bank chart item', () => {
  for (const book of ['rfd4', 'rfd5', 'rfd6']) {
    for (const unit of parseBook(book)) {
      for (const question of unit.questions.filter(question => question.type === 'word-bank')) {
        for (const key of ['compareChart', 'knowledgeChart', 'fiveWOneH', 'classification', 'timeline', 'retelling']) {
          const chart = question[key];
          if (!chart) continue;
          const items = chart.groups?.flatMap(group => group.items) || chart.events;
          for (const [index, item] of items.entries()) {
            assert.deepEqual(blankIdsIn(renderItem(item, index)), item.blankIds, `${book} U${unit.unit} ${question.id} ${key} item ${index}`);
          }
        }
      }
    }
  }
});

test('appends only blanks left over after inline placeholders', () => {
  assert.deepEqual(blankIdsIn(renderItem({ text: 'Dogs ________.', blankIds: ['blank-1', 'blank-2'] }, 0)), ['blank-1', 'blank-2']);
  assert.deepEqual(blankIdsIn(renderItem({ text: 'Information only.', blankIds: [] }, 0)), []);
});
