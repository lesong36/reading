#!/usr/bin/env node
/**
 * Extract TPO/OG English passages + multiple-choice questions from the converted
 * TPO1-30 Word text. Discards 「参考译文」. Writes MD + questions JSON + manifest.
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

const cwd = process.cwd();
const DEFAULT_DOC =
  '/Users/coty/Documents/Lei_MBP/Education/MBA/GT/toefl/阅读/TPO1-30阅读题、参考答案及译文.doc';
const DEFAULT_OUT = path.resolve(cwd, 'data/tpo-source');

const parseArgs = (argv) => {
  const args = {
    doc: DEFAULT_DOC,
    txt: '',
    out: DEFAULT_OUT,
    only: '',
    dryRun: false
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => argv[++i];
    if (arg === '--doc') args.doc = next();
    else if (arg === '--txt') args.txt = next();
    else if (arg === '--out') args.out = path.resolve(next());
    else if (arg === '--only') args.only = next();
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--help') {
      console.log(`Usage: node scripts/extract-tpo-from-doc.mjs [--doc path] [--txt path] [--out dir] [--only TPO-1] [--dry-run]`);
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
};

const escapeRegExp = (value) => String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const slugify = (value) =>
  String(value || '')
    .normalize('NFKD')
    .replace(/[^\w\u4e00-\u9fff]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase()
    .slice(0, 80) || 'passage';

const isChineseHeavy = (title) => /[\u4e00-\u9fff]/.test(title);

const ensureTxt = (args) => {
  if (args.txt && fs.existsSync(args.txt)) {
    return fs.readFileSync(args.txt, 'utf8');
  }
  const cacheTxt = path.join(args.out, '_cache', 'tpo1-30.txt');
  if (fs.existsSync(cacheTxt) && !args.doc) {
    return fs.readFileSync(cacheTxt, 'utf8');
  }
  if (!fs.existsSync(args.doc)) {
    throw new Error(`DOC not found: ${args.doc}`);
  }
  fs.mkdirSync(path.dirname(cacheTxt), { recursive: true });
  const result = spawnSync('textutil', ['-convert', 'txt', '-output', cacheTxt, args.doc], {
    encoding: 'utf8'
  });
  if (result.status !== 0) {
    throw new Error(`textutil failed: ${result.stderr || result.stdout || result.status}`);
  }
  return fs.readFileSync(cacheTxt, 'utf8');
};

const parseTocArticles = (text) => {
  const titles = [];
  for (const match of text.matchAll(/HYPERLINK \\l "_Toc\d+"\s+(.+?)\s+PAGEREF/g)) {
    titles.push(match[1].trim());
  }

  const articles = [];
  let section = 'Front';
  for (const title of titles) {
    if (title === '使用说明' || title === '目录') continue;
    const tpo = title.match(/^TPO-?(\d+)$/i) || title.match(/^Tpo(\d+)$/i);
    if (tpo) {
      section = `TPO-${Number(tpo[1])}`;
      continue;
    }
    if (['OG', 'Online Test', 'Official Model Exam', 'OG Test 2'].includes(title)) {
      section = title;
      continue;
    }
    if (title.startsWith('参考译文') || title.startsWith('参考文献')) continue;
    if (isChineseHeavy(title)) continue;
    articles.push({
      section,
      title,
      id: `${slugify(section)}-${slugify(title)}`
    });
  }
  return articles;
};

const bodyStartIndex = (text) => {
  let lastPagerRef = -1;
  for (const match of text.matchAll(/PAGEREF/g)) lastPagerRef = match.index;
  if (lastPagerRef === -1) return 0;
  const ff = text.indexOf('\f', lastPagerRef);
  return ff === -1 ? lastPagerRef : ff;
};

const findTitleAt = (text, title, fromIndex) => {
  // textutil uses form-feed page breaks before some titles and preserves leading
  // whitespace on others. Treat those as line boundaries, otherwise valid
  // passages immediately following a page break are silently missed.
  const pattern = new RegExp(`(?:^|[\\n\\f])[\\t ]*${escapeRegExp(title)}[\\t ]*(?:\\r?\\n|$)`, 'i');
  pattern.lastIndex = 0;
  const slice = text.slice(fromIndex);
  const match = pattern.exec(slice);
  if (!match) return -1;
  // index of the title line start inside full text
  const relative = match.index + (match[0].startsWith('\n') ? 1 : 0);
  return fromIndex + relative;
};

const splitPassageAndQuestions = (block) => {
  // First exam-style numbered question
  const questionStart = /\n[\t \u00a0]*\d{1,2}[\.．:：]\s*(?:Which|The |According|In paragraph|Paragraph|Look at|An introductory|Directions|Complete|What |Why |How |When |Where |Who |All of the following|It can be inferred|Select)/i;
  const qStart = block.search(questionStart);
  if (qStart === -1) {
    // fallback: first question number, including the full-width full stop
    // commonly emitted by textutil from this source document.
    const fallback = block.search(/\n[\t \u00a0]*1[\.．:：]\s*/);
    if (fallback === -1) return { passage: block.trim(), questionBlock: '' };
    return {
      passage: block.slice(0, fallback).trim(),
      questionBlock: block.slice(fallback).trim()
    };
  }
  return {
    passage: block.slice(0, qStart).trim(),
    questionBlock: block.slice(qStart).trim()
  };
};

const stripInjectedParagraphExcerpt = (text) =>
  String(text || '')
    .replace(/\n[\t \u00a0]*Paragraph\s+\d+[：:][\s\S]*$/i, '')
    .trim();

const isUnsupportedQuestionPrompt = (text) => {
  const prompt = String(text || '');
  return (
    /\bLook at the four squares\b/i.test(prompt) ||
    /\bWhere would the sentence best fit\b/i.test(prompt) ||
    /\bAn introductory sentence for a brief summary\b/i.test(prompt) ||
    /\bComplete the summary\b/i.test(prompt) ||
    /\bComplete the table\b/i.test(prompt) ||
    /\bSelect the TWO answer choic(?:e|es)\b/i.test(prompt) ||
    /\bSelect from the seven\b/i.test(prompt) ||
    /\bselected from the seven\b/i.test(prompt) ||
    /\bDrag each\b/i.test(prompt)
  );
};

const parseQuestions = (questionBlock) => {
  if (!questionBlock) return { questions: [], unsupported: [] };

  // The Word source varies between “参考答案：”, “参考答案:”, a bare
  // “参考答案” and “答案：”. All delimit the official-answer block.
  const answerSplit = questionBlock.search(/(?:\n|\f)\s*(?:参考)?答案\s*[：:]?/);
  const qText = answerSplit === -1 ? questionBlock : questionBlock.slice(0, answerSplit);
  const aText = answerSplit === -1 ? '' : questionBlock.slice(answerSplit);

  const chunks = qText
    .split(/\n(?=[\t \u00a0]*\d{1,2}[\.．:：]\s*)/)
    .map((c) => c.trim())
    .filter(Boolean);
  const questions = [];
  const unsupported = [];

  const inferPlainOptions = (text) => {
    const lines = text.split('\n').map((line) => line.trim()).filter(Boolean);
    if (lines.length < 5) return [];
    if (/\b(?:Answer Choices|Directions)\b/i.test(text)) return [];
    const candidates = lines.slice(-4);
    if (candidates.some((line) => /^(?:Paragraph|Answer Choices|Directions|●|■)/i.test(line))) return [];
    return candidates;
  };

  for (const chunk of chunks) {
    const header = chunk.match(/^[\t \u00a0]*(\d{1,2})[\.．:：]\s*([\s\S]*)$/);
    if (!header) continue;
    const index = Number(header[1]);
    const rest = stripInjectedParagraphExcerpt(header[2]);
    const unsupportedPrompt = isUnsupportedQuestionPrompt(rest);
    let optionMatches = [...rest.matchAll(/^[○O]\s*(.+)$/gm)].map((m) => m[1].trim());
    let prompt = rest
      .replace(/^○\s*.+$/gm, '')
      .replace(/\n{2,}/g, '\n')
      .trim();

    // Later sections of the DOC store ordinary four-option questions as
    // unmarked lines. They are still official multiple-choice questions;
    // the final four non-empty lines are the choices.
    if (!unsupportedPrompt && optionMatches.length < 4) {
      const inferred = inferPlainOptions(prompt);
      if (inferred.length === 4) {
        optionMatches = inferred;
        const promptLines = prompt.split('\n').map((line) => line.trim()).filter(Boolean);
        prompt = promptLines.slice(0, -4).join('\n');
      }
    }

    const paraHintMatch = prompt.match(/paragraph\s+(\d+)/i);
    const paragraphHint = paraHintMatch ? paraHintMatch[1] : '';

    if (!unsupportedPrompt && optionMatches.length >= 4) {
      questions.push({
        id: `q${index}`,
        index,
        prompt,
        options: optionMatches.slice(0, 4),
        answerIndex: null,
        paragraphHint: paragraphHint || null,
        type: 'single'
      });
    } else {
      unsupported.push({
        id: `q${index}`,
        index,
        prompt,
        options: optionMatches,
        answerIndex: null,
        paragraphHint: paragraphHint || null,
        type: 'unsupported',
        rawChunk: chunk.slice(0, 500)
      });
    }
  }

  // Answers may be numbered with or without the circle marker: 1. ○3 / 1. 3.
  const answerMap = new Map();
  const rawAnswerMap = new Map();
  for (const match of aText.matchAll(/(?:^|\n)\s*(\d{1,2})[\.．]\s*(?:○\s*)?([1-4])(?=\s|$)/g)) {
    answerMap.set(Number(match[1]), Number(match[2]) - 1);
  }
  // A few source sections list one bare answer digit per line. Associate them
  // with the question order, leaving non-numeric insert/summary answers alone.
  const bareAnswers = aText
    .split('\n')
    .map((line) => line.trim())
    .map((line) => line.match(/^([1-4])(?=\s|\(|$)/)?.[1])
    .filter(Boolean)
    .map(Number);
  // Some pages contain only unnumbered “○3” lines. Use them only when there
  // are no explicit numbered answers, so ordinary option markers can never
  // disturb a correctly parsed answer map.
  if (answerMap.size === 0 && bareAnswers.length === 0) {
    aText
      .split('\n')
      .map((line) => line.trim().match(/^[○O]\s*([1-4])(?=\s|$)/)?.[1])
      .filter(Boolean)
      .map(Number)
      .forEach((answer, position) => bareAnswers.push(answer));
  }
  const orderedIndexes = [...questions, ...unsupported].map((item) => item.index).sort((a, b) => a - b);
  bareAnswers.forEach((answer, position) => {
    const index = orderedIndexes[position];
    if (index != null && !answerMap.has(index)) answerMap.set(index, answer - 1);
  });
  // Non ○ answers (summary/table etc.) — capture the whole numbered block.
  const answerEntries = aText
    .split(/\n(?=[\t \u00a0]*\d{1,2}[\.．]\s*)/)
    .map((entry) => entry.trim())
    .filter(Boolean);
  for (const entry of answerEntries) {
    const match = entry.match(/^[\t \u00a0]*(\d{1,2})[\.．]\s*([\s\S]*)$/);
    if (!match) continue;
    const answerBody = match[2].trim().replace(/\n{2,}/g, '\n');
    if (!answerBody || /^(?:○\s*)?[1-4]\s*$/.test(answerBody)) continue;
    rawAnswerMap.set(Number(match[1]), answerBody);
  }

  for (const q of questions) {
    if (answerMap.has(q.index)) q.answerIndex = answerMap.get(q.index);
  }
  for (const q of unsupported) {
    if (rawAnswerMap.has(q.index)) q.rawAnswer = rawAnswerMap.get(q.index);
    if (answerMap.has(q.index)) {
      // rare: unsupported still got ○ answer
      q.answerIndex = answerMap.get(q.index);
    }
  }

  // A visible four-option question without an official answer key must never
  // be presented as auto-gradable. Keep it navigable, but make the limitation
  // explicit instead of silently accepting an unverifiable answer.
  for (let index = questions.length - 1; index >= 0; index -= 1) {
    const question = questions[index];
    if (question.answerIndex != null) continue;
    questions.splice(index, 1);
    unsupported.push({
      ...question,
      type: 'unsupported',
      rawChunk: question.prompt.slice(0, 500),
      rawAnswer: rawAnswerMap.get(question.index) || ''
    });
  }
  unsupported.sort((left, right) => left.index - right.index);

  return { questions, unsupported };
};

const cleanPassage = (passage, title) => {
  let body = passage.trim();
  // Drop leading title line if duplicated
  if (body.startsWith(title)) {
    body = body.slice(title.length).trim();
  }
  // Drop leading section tags like TPO-1 / OG alone
  body = body.replace(/^(?:TPO-?\d+|OG|Online Test|Official Model Exam|OG Test 2)\s*/i, '').trim();
  if (body.startsWith(title)) body = body.slice(title.length).trim();
  // Some Word pages repeat the passage as “Paragraph N:” immediately before
  // their questions. It is not part of the article body.
  body = body.replace(/\n[\t \u00a0]*Paragraph\s+\d+[：:][\s\S]*$/i, '').trim();
  return body.replace(/\n{3,}/g, '\n\n').trim();
};

const extractArticle = (text, article, fromIndex, nextTitle) => {
  const titleAt = findTitleAt(text, article.title, fromIndex);
  if (titleAt === -1) {
    return { ok: false, error: 'title_not_found', fromIndex };
  }

  const contentStart = titleAt + article.title.length;
  let contentEnd = text.length;

  if (nextTitle) {
    const nextAt = findTitleAt(text, nextTitle, contentStart + 1);
    if (nextAt !== -1) contentEnd = Math.min(contentEnd, nextAt);
  }

  // Prefer cutting after 参考答案 block, before 参考译文
  const slice = text.slice(contentStart, contentEnd);
  const translationAt = slice.search(/\n参考译文[：:]/);
  const usable = translationAt === -1 ? slice : slice.slice(0, translationAt);

  const { passage, questionBlock } = splitPassageAndQuestions(usable);
  const cleaned = cleanPassage(passage, article.title);
  const { questions, unsupported } = parseQuestions(questionBlock);

  const graded = questions.filter((q) => q.type === 'single' && q.answerIndex != null);
  const missingAnswers = questions.filter((q) => q.type === 'single' && q.answerIndex == null);

  return {
    ok: true,
    titleAt,
    nextCursor: contentStart + usable.length,
    passage: cleaned,
    questions,
    unsupported,
    stats: {
      passageChars: cleaned.length,
      questionCount: questions.length,
      unsupportedCount: unsupported.length,
      gradedCount: graded.length,
      missingAnswers: missingAnswers.map((q) => q.index)
    }
  };
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  fs.mkdirSync(args.out, { recursive: true });
  const passagesDir = path.join(args.out, 'passages');
  const questionsDir = path.join(args.out, 'questions');
  fs.mkdirSync(passagesDir, { recursive: true });
  fs.mkdirSync(questionsDir, { recursive: true });

  const text = ensureTxt(args).replace(/\r\n/g, '\n');
  let articles = parseTocArticles(text);
  if (args.only) {
    const needle = args.only.toLowerCase();
    articles = articles.filter(
      (a) =>
        a.section.toLowerCase().includes(needle) ||
        a.title.toLowerCase().includes(needle) ||
        a.id.toLowerCase().includes(needle)
    );
  }

  const start = bodyStartIndex(text);
  let cursor = start;
  const results = [];
  const errors = [];

  console.log(`Articles to extract: ${articles.length} (body starts at ${start})`);

  for (let i = 0; i < articles.length; i += 1) {
    const article = articles[i];
    const nextTitle = articles[i + 1]?.title || null;
    const extracted = extractArticle(text, article, cursor, nextTitle);
    if (!extracted.ok) {
      // retry from body start once (section jump)
      const retry = extractArticle(text, article, start, nextTitle);
      if (!retry.ok) {
        errors.push({ id: article.id, section: article.section, title: article.title, error: extracted.error });
        console.warn(`MISS ${article.id}`);
        continue;
      }
      Object.assign(extracted, retry);
    }

    cursor = Math.max(cursor, extracted.titleAt + article.title.length);

    const md = `# ${article.section} / ${article.title}\n\n${extracted.passage}\n`;
    const questionPayload = {
      id: article.id,
      section: article.section,
      title: article.title,
      questions: extracted.questions,
      unsupported: extracted.unsupported
    };

    results.push({
      id: article.id,
      section: article.section,
      title: article.title,
      ...extracted.stats,
      mdPath: `passages/${article.id}.md`,
      questionsPath: `questions/${article.id}.json`
    });

    if (!args.dryRun) {
      fs.writeFileSync(path.join(passagesDir, `${article.id}.md`), md, 'utf8');
      fs.writeFileSync(
        path.join(questionsDir, `${article.id}.json`),
        `${JSON.stringify(questionPayload, null, 2)}\n`,
        'utf8'
      );
    }

    console.log(
      `OK ${article.id} chars=${extracted.stats.passageChars} Q=${extracted.stats.questionCount} U=${extracted.stats.unsupportedCount} graded=${extracted.stats.gradedCount}`
    );
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    sourceDoc: args.doc,
    expectedArticles: args.only ? articles.length : 104,
    extractedCount: results.length,
    errorCount: errors.length,
    articles: results,
    errors
  };

  if (!args.dryRun) {
    fs.writeFileSync(path.join(args.out, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  }

  console.log(`\nDone. extracted=${results.length} errors=${errors.length}`);
  if (!args.only && results.length !== 104) {
    console.warn(`WARNING: expected 104 articles, got ${results.length}`);
  }
  if (errors.length) process.exitCode = 2;
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

export { extractArticle, parseQuestions };
