import test from 'node:test';
import assert from 'node:assert/strict';

import { parseQuestions } from '../scripts/extract-tpo-from-doc.mjs';

test('parseQuestions removes injected paragraph excerpts and splits indented follow-up questions', () => {
  const block = `2.The word "practical" in the passage is closest in meaning to
 usable
 plentiful
 economical
 familiar

    Paragraph 2: By far the most abundant form of geothermal energy occurs here.

\t3.The word "abundant" in the passage is closest in meaning to
 economical
 familiar
 plentiful
 useful

\t4.According to paragraph 2, which of the following is true?
 They are under international control.
 They are more common than reservoirs that have a higher temperature.
 Few of them produce enough heat to warm large industrial spaces.
 They are used to generate electricity.

参考答案：
2. 1
3. 3
4. 2`;

  const { questions, unsupported } = parseQuestions(block);
  assert.equal(unsupported.length, 0);
  assert.deepEqual(
    questions.map((question) => question.index),
    [2, 3, 4]
  );
  assert.equal(questions[0].prompt, 'The word "practical" in the passage is closest in meaning to');
  assert.deepEqual(questions[0].options, ['usable', 'plentiful', 'economical', 'familiar']);
  assert.equal(questions[0].answerIndex, 0);
  assert.equal(questions[2].paragraphHint, '2');
});

test('parseQuestions marks summary questions unsupported and preserves multiline official answers', () => {
  const block = `14.Directions: An introductory sentence for a brief summary of the passage is provided below. Complete the summary by selecting the THREE answer choices that express the most important ideas in the passage. This question is worth 2 points.
Important idea.
●
●
●

Answer Choices
 Choice A
 Choice B
 Choice C
 Choice D
 Choice E
 Choice F

参考答案：
14. Choice B
    Choice D
    Choice F`;

  const { questions, unsupported } = parseQuestions(block);
  assert.equal(questions.length, 0);
  assert.equal(unsupported.length, 1);
  assert.equal(unsupported[0].type, 'unsupported');
  assert.equal(unsupported[0].answerIndex, null);
  assert.equal(unsupported[0].rawAnswer, 'Choice B\n    Choice D\n    Choice F');
});

test('parseQuestions marks multi-select questions unsupported', () => {
  const block = `7.Select the TWO answer choices that indicate two methods people used to increase productivity.
 Method A
 Method B
 Method C
 Method D

参考答案：
7. Method A
   Method C`;

  const { questions, unsupported } = parseQuestions(block);
  assert.equal(questions.length, 0);
  assert.equal(unsupported.length, 1);
  assert.equal(unsupported[0].index, 7);
  assert.equal(unsupported[0].rawAnswer, 'Method A\n   Method C');
});
