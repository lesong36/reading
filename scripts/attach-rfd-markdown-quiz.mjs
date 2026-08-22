#!/usr/bin/env node
/** Attach the audited RFD4–6 Markdown quiz banks to their analyzed reader sections. */
import fs from 'node:fs';
import path from 'node:path';

const cwd = process.cwd();
const root = path.join(cwd, 'data/generated-reader-json');
const books = ['rfd4', 'rfd5', 'rfd6'];
const clean = (value = '') => value.replace(/\r/g, '').trim();

const parseBook = (stem) => {
  const text = fs.readFileSync(path.join(cwd, 'docs', `${stem}.md`), 'utf8');
  return [...text.matchAll(/^##\s+(?:Unit\s+|U)(\d+)\s+(.+?)\n\n([\s\S]*?)(?=^##\s+(?:Unit\s+|U)\d+\s+|(?![\s\S]))/gm)].map(([, unit, title, body]) => {
    const answerMatch = body.match(/^ans\s*[:：]\s*(.+)$/mi);
    if (!answerMatch) throw new Error(`${stem} Unit ${unit}: missing ans line`);
    const answers = answerMatch[1].trim().split(/\s+/);
    // Source tables can contain numbered blanks (for example, "Detail: 1.").
    // Actual questions always start a new paragraph, so only those boundaries
    // are considered question starts.
    const blocks = [...body.matchAll(/(?:^|\n\n)(\d+)\.\s+([\s\S]*?)(?=\n\n\d+\.\s+|^ans:|(?![\s\S]))/gm)];
    if (blocks.length < answers.length) throw new Error(`${stem} Unit ${unit}: ${blocks.length} questions, ${answers.length} answers`);
    // Some chart questions repeat `1.`, `2.` for their blanks after the real
    // numbered question list.  The answer key defines the actual question
    // count, so ignore those nested labels.
    const questions = blocks.slice(0, answers.length).flatMap(([, index, block], position) => {
      const prompt = clean(block.slice(0, block.search(/^a\.\s/m)));
      // Most sources put options on separate lines, but a few word-bank
      // questions place `a. ... b. ...` on one line.
      const options = [...block.matchAll(/(?:^|\s)([a-z])\.\s+(.+?)(?=\s+[a-z]\.\s+|$)/gmi)].map(([, , value]) => clean(value));
      const answerKey = answers[position];
      const answerIndexes = [...answerKey].map(answer => 'abcdefghijklmnopqrstuvwxyz'.indexOf(answer));
      if (!prompt || options.length < 2 || answerIndexes.some(answerIndex => answerIndex < 0 || answerIndex >= options.length)) {
        throw new Error(`${stem} Unit ${unit} Q${index}: invalid prompt/options/key`);
      }
      const isMultiSelect = /(?:select|choose)\s+(?:2|two)/i.test(prompt);
      const hasMultipleBlanks = answerIndexes.length > 1 && /(?:_|\bcomplete\b|\bchart\b|\btable\b|each sentence)/i.test(prompt);
      if (hasMultipleBlanks && !isMultiSelect) {
        return answerIndexes.map((answerIndex, blankOffset) => ({
          id: `q${index}-blank-${blankOffset + 1}`,
          index: Number(index) + (blankOffset + 1) / 100,
          prompt: `${prompt}\n\n请完成第 ${blankOffset + 1} 空。`,
          options,
          answerIndex,
          type: 'single',
          answerSource: 'audited-rfd-markdown'
        }));
      }
      return {
        id: `q${index}`,
        index: Number(index),
        prompt,
        options,
        answerIndex: answerIndexes.length === 1 ? answerIndexes[0] : null,
        type: answerIndexes.length === 1 ? 'single' : 'unsupported',
        rawAnswer: answerKey.toUpperCase(),
        answerSource: 'audited-rfd-markdown'
      };
    });
    return { unit: Number(unit), title: clean(title), questions };
  });
};

let articleCount = 0;
let questionCount = 0;
for (const stem of books) {
  const byUnit = new Map(parseBook(stem).map(item => [item.unit, item]));
  const sectionDir = path.join(root, stem, 'sections');
  const files = fs.readdirSync(sectionDir).filter(file => file.endsWith('.json')).sort();
  if (files.length !== byUnit.size) throw new Error(`${stem}: ${files.length} analyzed sections, ${byUnit.size} Markdown units`);
  for (const file of files) {
    const payloadPath = path.join(sectionDir, file);
    const payload = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));
    const unit = Number(file.match(/^(\d+)/)?.[1]);
    const quiz = byUnit.get(unit);
    if (!quiz) throw new Error(`${stem}: no quiz for ${file}`);
    payload.article.questions = quiz.questions;
    payload.article.unsupportedQuestions = [];
    fs.writeFileSync(payloadPath, `${JSON.stringify(payload, null, 2)}\n`);
    articleCount += 1;
    questionCount += quiz.questions.length;
  }
}
console.log(`Attached ${questionCount} questions to ${articleCount} RFD4–6 articles.`);
