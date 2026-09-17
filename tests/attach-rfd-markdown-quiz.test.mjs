import test from 'node:test';
import assert from 'node:assert/strict';

import { parseBook } from '../scripts/attach-rfd-markdown-quiz.mjs';

test('preserves the target sentence for each RFD word-bank blank', () => {
  const tomb = parseBook('rfd4').find(({ unit }) => unit === 2);
  const blanks = tomb.questions.filter(question => question.id.startsWith('q8-blank-'));

  assert.equal(blanks.length, 4);
  assert.match(blanks[0].prompt, /WHAT: The 1\. \(  \) of King Tutankhamun was found\./);
  assert.match(blanks[3].prompt, /WHY: Experts now 4\. \(  \) these objects to learn about ancient Egypt\./);
  assert.doesNotMatch(blanks[3].prompt, /Words:\s*请完成/);
  assert.deepEqual(blanks[3].options, ['digging', 'beautiful', 'tomb', 'study', 'gold']);
});

test('turns RFD multi-select and word-bank activities into auto-gradable questions', () => {
  const rfd4Unit1 = parseBook('rfd4').find(({ unit }) => unit === 1);
  assert.deepEqual(rfd4Unit1.questions.find(question => question.id === 'q3'), {
    id: 'q3', index: 3, prompt: 'How does the writer describe ancient Egypt? （select 2）',
    options: ['amazing', 'advanced', 'old'], answerIndex: null, answerIndexes: [0, 1], type: 'multiple', rawAnswer: 'AB', answerSource: 'audited-rfd-markdown'
  });

  const rfd4Unit7 = parseBook('rfd4').find(({ unit }) => unit === 7);
  const animalBlankIds = rfd4Unit7.questions.filter(question => question.id.startsWith('q8-blank-')).map(question => question.id);
  assert.deepEqual(animalBlankIds, ['q8-blank-1', 'q8-blank-2', 'q8-blank-3']);

  const rfd5Unit16 = parseBook('rfd5').find(({ unit }) => unit === 16);
  assert.equal(rfd5Unit16.questions.find(question => question.id === 'q7').answerIndex, 0);
  assert.deepEqual(
    rfd5Unit16.questions.filter(question => question.id.startsWith('q8-blank-')).map(question => question.answerIndex),
    [1, 2, 0]
  );
});

test('keeps a visible target prompt for every RFD4–6 word-bank blank', () => {
  const books = ['rfd4', 'rfd5', 'rfd6'];

  for (const book of books) {
    const blanks = parseBook(book)
      .flatMap(unit => unit.questions)
      .filter(question => question.id.includes('-blank-'));

    for (const question of blanks) {
      const sections = question.prompt.split(/\n\n/).map(section => section.trim()).filter(Boolean);
      const target = sections.at(-2);

      assert.ok(target, `${book} ${question.id} is missing its target prompt`);
      assert.doesNotMatch(target, /^请完成第\s*\d+\s*空。?$/);
    }
  }
});
