#!/usr/bin/env node
/** Attach the audited RFD4–6 Markdown quiz banks to their analyzed reader sections. */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const cwd = process.cwd();
const root = path.join(cwd, 'data/generated-reader-json');
const books = ['rfd4', 'rfd5', 'rfd6'];
const clean = (value = '') => value.replace(/\r/g, '').trim();

export const parseBook = (stem, { baseDir = cwd } = {}) => {
  const text = fs.readFileSync(path.join(baseDir, 'docs', `${stem}.md`), 'utf8');
  return [...text.matchAll(/^##\s+(?:Unit\s+|U)(\d+)\s+(.+?)\n\n([\s\S]*?)(?=^##\s+(?:Unit\s+|U)\d+\s+|(?![\s\S]))/gm)].map(([, unit, title, body]) => {
    const answerMatch = body.match(/^ans\s*[:：]\s*(.+)$/mi);
    if (!answerMatch) throw new Error(`${stem} Unit ${unit}: missing ans line`);
    const answers = answerMatch[1].trim().split(/\s+/);
    // Source tables can contain numbered blanks (for example, "Detail: 1.").
    // Actual questions always start a new paragraph, so only those boundaries
    // are considered question starts.
    const rawBlocks = [...body.matchAll(/(?:^|\n\n)(\d+)\.\s+([\s\S]*?)(?=\n\n\d+\.\s+|^ans:|(?![\s\S]))/gm)];
    if (rawBlocks.length < answers.length) throw new Error(`${stem} Unit ${unit}: ${rawBlocks.length} questions, ${answers.length} answers`);
    // Some chart questions repeat `1.`, `2.` for their blanks after the real
    // numbered question list.  The answer key defines the actual question
    // count, so ignore those nested labels.
    const questions = rawBlocks.slice(0, answers.length).flatMap(([, index, initialBlock], position) => {
      // The final chart question sometimes numbers its individual blanks as
      // `2.`, `3.`, etc. after a blank line. The boundary matcher sees those
      // labels as questions, so stitch them back onto the final source item.
      const trailingBlankBlocks = position === answers.length - 1
        ? rawBlocks.slice(answers.length).map(([, nestedIndex, nestedBlock]) => `${nestedIndex}. ${nestedBlock}`).join('\n\n')
        : '';
      const block = `${initialBlock}${trailingBlankBlocks ? `\n\n${trailingBlankBlocks}` : ''}`;
      // Most sources put options on separate lines, but a few word-bank
      // questions place `a. ... b. ...` on one line.
      const optionMatches = [...block.matchAll(/(?:^|\s)([a-z])\.\s+(.+?)(?=\s+[a-z]\.\s+|$)/gmi)];
      const firstOption = optionMatches[0];
      const prompt = clean(block.slice(0, firstOption?.index ?? 0));
      const options = optionMatches.map(([, , value]) => clean(value));
      const answerKey = answers[position];
      const answerIndexes = [...answerKey].map(answer => 'abcdefghijklmnopqrstuvwxyz'.indexOf(answer));
      if (!prompt || options.length < 2 || answerIndexes.some(answerIndex => answerIndex < 0 || answerIndex >= options.length)) {
        throw new Error(`${stem} Unit ${unit} Q${index}: invalid prompt/options/key`);
      }
      const isMultiSelect = /(?:select|choose)\s+(?:2|two)/i.test(prompt);
      const hasMultipleBlanks = answerIndexes.length > 1 && /(?:_|\bcomplete\b|\bchart\b|\btable\b|each sentence)/i.test(prompt);
      if (hasMultipleBlanks && !isMultiSelect) {
        const finalOption = optionMatches.at(-1);
        const beforeOptions = block.slice(0, firstOption?.index ?? 0).split('\n');
        const afterOptions = block
          .slice((finalOption?.index ?? 0) + (finalOption?.[0].length ?? 0))
          .split('\n');
        const blankOccurrences = line => [...line.matchAll(/\(\s*\)|_{2,}(?:\d+_{2,})?/g)];
        const isBlankLine = line => blankOccurrences(line).length > 0;
        const allPromptLines = [...beforeOptions, ...afterOptions]
          .map(clean)
          .filter(Boolean);
        const explicitBlankLines = allPromptLines.flatMap(line =>
          Array.from({ length: blankOccurrences(line).length }, () => line)
        );
        // A few chart activities phrase each entry as a prompt rather than
        // drawing underscores. They are still single-word blanks according to
        // the audited answer key and should remain visible to the learner.
        const blankLines = explicitBlankLines.length > 0
          ? explicitBlankLines
          : allPromptLines.filter(line => /^[-•]\s+/.test(line));
        if (blankLines.length !== answerIndexes.length) {
          throw new Error(`${stem} Unit ${unit} Q${index}: expected ${answerIndexes.length} blank sentences, found ${blankLines.length}`);
        }
        const firstBlankLineIndex = beforeOptions.findIndex(isBlankLine);
        const blankPrompt = clean(
          (firstBlankLineIndex >= 0 ? beforeOptions.slice(0, firstBlankLineIndex) : beforeOptions).join('\n')
        ).replace(/\bWords:\s*$/i, '').trim();
        return answerIndexes.map((answerIndex, blankOffset) => ({
          id: `q${index}-blank-${blankOffset + 1}`,
          index: Number(index) + (blankOffset + 1) / 100,
          prompt: `${blankPrompt}\n\n${blankLines[blankOffset]}\n\n请完成第 ${blankOffset + 1} 空。`,
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

const main = () => {
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
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
