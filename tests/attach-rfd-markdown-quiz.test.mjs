import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import { parseBook, READING_SKILL_LAYOUTS } from '../scripts/attach-rfd-markdown-quiz.mjs';

test('preserves the target sentence for each RFD word-bank blank', () => {
  const tomb = parseBook('rfd4').find(({ unit }) => unit === 2);
  const wordBank = tomb.questions.find(question => question.id === 'q8');
  const blanks = wordBank.blanks;

  assert.equal(wordBank.type, 'word-bank');
  assert.equal(blanks.length, 4);
  assert.match(blanks[0].prompt, /WHAT: The 1\. \(  \) of King Tutankhamun was found\./);
  assert.match(blanks[3].prompt, /WHY: Experts now 4\. \(  \) these objects to learn about ancient Egypt\./);
  assert.doesNotMatch(blanks[3].prompt, /Words:\s*请完成/);
  assert.deepEqual(wordBank.options, ['digging', 'beautiful', 'tomb', 'study', 'gold']);
});

test('turns RFD multi-select and word-bank activities into auto-gradable questions', () => {
  const rfd4Unit1 = parseBook('rfd4').find(({ unit }) => unit === 1);
  assert.deepEqual(rfd4Unit1.questions.find(question => question.id === 'q3'), {
    id: 'q3', index: 3, prompt: 'How does the writer describe ancient Egypt? （select 2）',
    options: ['amazing', 'advanced', 'old'], answerIndex: null, answerIndexes: [0, 1], type: 'multiple', rawAnswer: 'AB', answerSource: 'audited-rfd-markdown'
  });
  const rfd4IdeaTree = rfd4Unit1.questions.find(question => question.id === 'q8').ideaTree;
  assert.equal(rfd4IdeaTree.mainIdea.blankId, 'blank-1');
  assert.deepEqual(rfd4IdeaTree.branches.map(branch => branch.label), ['Sub-idea 1', 'Sub-idea 2']);
  assert.deepEqual(rfd4IdeaTree.branches[0].details.map(detail => detail.label), ['Detail 1', 'Detail 2']);
  assert.deepEqual(rfd4IdeaTree.branches[1].details.map(detail => detail.blankId), [null, 'blank-4']);
  assert.ok(rfd4IdeaTree.branches.every(branch => branch.entries.length === 1 && branch.details.every(detail => detail.entries.length === 1)));

  const rfd4Unit7 = parseBook('rfd4').find(({ unit }) => unit === 7);
  assert.deepEqual(rfd4Unit7.questions.find(question => question.id === 'q8').blanks.map(blank => blank.id), ['blank-1', 'blank-2', 'blank-3']);

  const rfd5Unit16 = parseBook('rfd5').find(({ unit }) => unit === 16);
  assert.equal(rfd5Unit16.questions.find(question => question.id === 'q7').answerIndex, 0);
  assert.deepEqual(
    rfd5Unit16.questions.find(question => question.id === 'q8').blanks.map(question => question.answerIndex),
    [1, 2, 0]
  );
});

test('keeps a visible target prompt for every RFD4–6 word-bank blank', () => {
  const books = ['rfd4', 'rfd5', 'rfd6'];

  for (const book of books) {
    const blanks = parseBook(book)
      .flatMap(unit => unit.questions)
      .filter(question => question.type === 'word-bank')
      .flatMap(question => question.blanks);

    for (const question of blanks) {
      assert.ok(question.prompt, `${book} ${question.id} is missing its target prompt`);
      assert.doesNotMatch(question.prompt, /^请完成第\s*\d+\s*空。?$/);
    }
  }
});

test('refreshes cached RFD quizzes after their grading model changes', () => {
  for (const entrypoint of ['index.html', '英语长难句交互阅读解析.html']) {
    const source = fs.readFileSync(path.join(process.cwd(), entrypoint), 'utf8');
    assert.match(source, /BUNDLED_LIBRARY_SEED_KEY = 'reader_bundled_library_seeded_v43'/);
    assert.match(source, /BUNDLED_LIBRARY_SEED_VERSION = '43'/);
    assert.match(source, /hasRequiredBundledQuizLayouts/);
    assert.match(source, /const normalizeQuizIdeaTree = \(ideaTree\) => \{\s*if \(!ideaTree \|\| typeof ideaTree !== 'object'\) return null;/);
    assert.match(source, /const normalizeQuizTimeline = \(timeline\) => \{\s*if \(!timeline \|\| typeof timeline !== 'object'\) return null;/);
    assert.match(source, /const normalizeQuizGroupedChart = \(chart\) => \{/);
  }
});

test('keeps official multi-answer prompts and keys aligned', () => {
  const rfd4Unit14 = parseBook('rfd4').find(({ unit }) => unit === 14).questions.find(question => question.id === 'q3');
  const rfd5Unit6 = parseBook('rfd5').find(({ unit }) => unit === 6).questions.find(question => question.id === 'q3');
  const rfd5Unit7 = parseBook('rfd5').find(({ unit }) => unit === 7).questions.find(question => question.id === 'q3');

  assert.match(rfd4Unit14.prompt, /select 2/i);
  assert.deepEqual(rfd4Unit14.answerIndexes, [0, 1]);
  assert.match(rfd5Unit6.prompt, /are ways to make hand signs.*select 2/i);
  assert.deepEqual(rfd5Unit6.answerIndexes, [0, 1]);
  assert.match(rfd5Unit7.prompt, /select 4/i);
  assert.deepEqual(rfd5Unit7.answerIndexes, [0, 1, 2, 3]);
});

test('uses answer-key order when source numbering restarts inside a word bank', () => {
  const questions = parseBook('rfd5').find(({ unit }) => unit === 8).questions;

  assert.deepEqual(questions.map(question => question.id), ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8']);
  assert.deepEqual(questions.map(question => question.index), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(questions.at(-1).type, 'word-bank');
});

test('keeps RFD5 comparison charts grouped with every answerable blank', () => {
  const unit8 = parseBook('rfd5').find(({ unit }) => unit === 8).questions.at(-1);
  assert.deepEqual(unit8.blanks.map(blank => blank.answerIndex), [4, 1, 0, 2]);
  assert.deepEqual(unit8.compareChart, {
    groups: [
      { label: 'Barcodes', items: [{ text: 'They have thin and thick ________.', blankIds: ['blank-1'] }] },
      {
        label: 'Both',
        items: [
          { text: 'Companies use them to hold ________ about items.', blankIds: ['blank-2'] },
          { text: 'You ________ them to read them.', blankIds: ['blank-3'] }
        ]
      },
      { label: 'QR Codes', items: [{ text: 'They use ________ instead of bars.', blankIds: ['blank-4'] }] }
    ]
  });

  const unit10 = parseBook('rfd5').find(({ unit }) => unit === 10).questions.at(-1);
  assert.deepEqual(unit10.compareChart.groups.map(group => group.label), ['Drum Machines', 'Both', 'Human Drummers']);
  assert.deepEqual(unit10.compareChart.groups[0].items[0].blankIds, ['blank-1', 'blank-2']);
  assert.deepEqual(unit10.compareChart.groups[1].items, [{ text: 'Play beats.', blankIds: [] }]);
  assert.deepEqual(unit10.compareChart.groups[2].items[0].blankIds, ['blank-3']);
});

test('preserves RFD5 sequencing and prior-knowledge chart layouts', () => {
  const rfd5 = parseBook('rfd5');
  for (const unitNumber of [4, 11, 12]) {
    const question = rfd5.find(({ unit }) => unit === unitNumber).questions.at(-1);
    assert.ok(question.timeline, `Unit ${unitNumber} should retain its timeline`);
    const placedBlankIds = question.timeline.events.flatMap(event => event.blankIds);
    assert.deepEqual(placedBlankIds.sort(), question.blanks.map(blank => blank.id).sort());
  }

  const unit4 = rfd5.find(({ unit }) => unit === 4).questions.at(-1);
  assert.match(unit4.timeline.events[0].text, /first created to read enermy messages/i);
  assert.match(unit4.timeline.events.at(-1).text, /play ______ and Go/i);

  const unit16 = rfd5.find(({ unit }) => unit === 16).questions.at(-1);
  assert.deepEqual(unit16.knowledgeChart.groups.map(group => group.label), ['What I Know', 'What I Want to Know', 'What I Learned']);
  assert.deepEqual(unit16.knowledgeChart.groups[2].items[0].blankIds, ['blank-2', 'blank-3']);
});

test('keeps source-faithful reading-skill metadata and every blank in its layout', () => {
  for (const [book, units] of Object.entries(READING_SKILL_LAYOUTS)) {
    const parsedUnits = new Map(parseBook(book).map(unit => [unit.unit, unit]));
    for (const [unitNumber, questions] of Object.entries(units)) {
      for (const [questionNumber, layout] of Object.entries(questions)) {
        const question = parsedUnits.get(Number(unitNumber))?.questions.find(item => item.index === Number(questionNumber));
        assert.equal(question?.chartLayout, layout, `${book} Unit ${unitNumber} Q${questionNumber} should retain ${layout}`);
        const chart = layout === 'main-idea-tree' ? question.ideaTree
          : layout === 'compare-chart' ? question.compareChart
            : layout === 'five-w-one-h' ? question.fiveWOneH
              : layout === 'classification' ? question.classification
                : layout === 'knowledge-chart' ? question.knowledgeChart
                  : layout === 'retelling' ? question.retelling
                    : question.timeline;
        assert.ok(chart, `${book} Unit ${unitNumber} Q${questionNumber} is missing its ${layout} data`);
        const placedBlankIds = layout === 'main-idea-tree'
          ? [chart.mainIdea, ...chart.details, ...chart.branches.flatMap(branch => [branch, ...branch.details])].flatMap(node => node.entries.flatMap(entry => entry.blankIds?.length ? entry.blankIds : [entry.blankId])).filter(Boolean)
          : chart.groups ? chart.groups.flatMap(group => group.items.flatMap(item => item.blankIds))
            : chart.events.flatMap(event => event.blankIds);
        assert.deepEqual([...new Set(placedBlankIds)].sort(), question.blanks.map(blank => blank.id).sort(), `${book} Unit ${unitNumber} Q${questionNumber} must place every blank`);
      }
    }
  }
});

test('does not split continued main-idea details into duplicate labels', () => {
  const tree = parseBook('rfd4').find(({ unit }) => unit === 3).questions.at(-1).ideaTree;
  assert.deepEqual(tree.details.map(detail => detail.label), ['Detail 1', 'Detail 2']);
  assert.deepEqual(tree.details[0].entries.map(entry => entry.blankId), ['blank-2', 'blank-3']);
  assert.equal(tree.details[1].entries.length, 1);
});

test('ships every declared Reading Skills layout in the generated quiz library', () => {
  const library = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'data/generated-reader-json/reader-articles.import.json'), 'utf8'));
  for (const [book, units] of Object.entries(READING_SKILL_LAYOUTS)) {
    for (const [unitNumber, questions] of Object.entries(units)) {
      const articlePrefix = `${book}-${String(unitNumber).padStart(2, '0')}-`;
      const article = library.find(item => String(item.id).startsWith(articlePrefix));
      assert.ok(article, `generated library is missing ${book} Unit ${unitNumber}`);
      for (const [questionNumber, layout] of Object.entries(questions)) {
        assert.equal(
          article.questions?.find(question => question.id === `q${questionNumber}`)?.chartLayout,
          layout,
          `generated library should retain ${book} Unit ${unitNumber} Q${questionNumber} as ${layout}`
        );
      }
    }
  }
});

test('places the shared comparison group below the two side groups', () => {
  for (const entrypoint of ['index.html', '英语长难句交互阅读解析.html']) {
    const source = fs.readFileSync(path.join(process.cwd(), entrypoint), 'utf8');
    const compareRenderer = source.slice(source.indexOf('const sharedGroup = currentWordBankCompareChart.groups.find'));
    const compareBlock = compareRenderer.slice(0, compareRenderer.indexOf('})() : currentWordBankIdeaTree'));
    assert.match(compareBlock, /sharedGroup && <div className="mx-auto w-full pt-1 md:max-w-\[62%\]">/);
    assert.doesNotMatch(compareBlock, /md:absolute/);
  }
});
