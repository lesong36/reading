import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import { parseBook } from '../scripts/attach-rfd-markdown-quiz.mjs';

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
    assert.match(source, /BUNDLED_LIBRARY_SEED_KEY = 'reader_bundled_library_seeded_v38'/);
    assert.match(source, /BUNDLED_LIBRARY_SEED_VERSION = '38'/);
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
