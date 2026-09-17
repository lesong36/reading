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
