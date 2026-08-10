#!/usr/bin/env node
/** Convert the manually extracted 时文阅读 Markdown into a bundled reader pack. */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const defaultInput = '/Users/coty/Downloads/pdf30_final.md';
const defaultOutput = path.join(cwd, 'data/generated-reader-json/reader-articles-shiwen.import.json');
const defaultReport = path.join(cwd, 'data/generated-reader-json/reader-articles-shiwen.report.json');

const optionIndex = (letter) => 'ABCDEFGH'.indexOf(String(letter || '').toUpperCase());
const args = process.argv.slice(2).reduce((result, arg, index, list) => {
  if (arg === '--input') result.input = path.resolve(list[index + 1]);
  if (arg === '--output') result.output = path.resolve(list[index + 1]);
  return result;
}, { input: defaultInput, output: defaultOutput });
args.report = args.output.replace(/\.import\.json$/, '.report.json');

const clean = (value = '') => value.replace(/\r/g, '').trim();
const splitEnglishSentences = (text) => {
  const normalized = clean(text).replace(/\n+/g, ' ');
  return (normalized.match(/[^.!?]+[.!?]+(?:[”"')\]]+)?|[^.!?]+$/g) || [])
    .map(clean)
    .filter(sentence => /[A-Za-z]/.test(sentence));
};
const readerSentence = (text, para, id) => ({
  id: `s${id}`,
  para,
  text,
  translation: '暂未生成译文；可使用 AI 助教获取讲解。',
  grammarFocus: '先找出句子的主语和谓语。',
  pronounRef: '无明显代词指代。',
  logicConnector: '无明显逻辑连接词。',
  sentenceCoach: { summary: '先读懂句子的大意。', keyHint: '先找主语和谓语。' },
  teachingFocus: {
    mainQuestion: '这句话是谁在做什么？', grammarQuestion: '先圈出谓语动词。',
    modifierQuestion: '再看看哪些词在补充说明。', relationshipQuestion: '按顺序把信息连起来。',
    commonMistake: '不要只看单词，要把整句连起来理解。',
    thinkingPath: ['找到主语', '找到谓语', '补全其他信息'], encouragement: '你可以读懂它。'
  },
  analysis: '### 【主干结构】\n先找主语和谓语。\n\n### 【主谓一致】\n注意主语与谓语的搭配。\n\n### 【动词时态与原形】\n观察谓语动词的形式。',
  segments: [{ text, type: 'modifier', label: '完整句子（待 AI 深度解析）' }],
  generatedBy: 'source-import'
});

const answerLetters = (answer) => new Map([...answer.matchAll(/(\d+)\.\s*([A-H]|T|F)\b/g)].map(([, index, value]) => [Number(index), value]));
const parseOptions = (block) => [...block.matchAll(/(?:^|\s)([A-D])\.\s*([\s\S]*?)(?=\s+[A-D]\.\s*|$)/g)]
  .map(([, letter, value]) => ({ letter, value: clean(value) }));
const unsupported = (index, prompt, rawAnswer, reason) => ({
  id: `q${index}`, index, prompt, options: [], answerIndex: null, type: 'unsupported', rawAnswer, reason
});

const parseQuestions = ({ body, answer, type }) => {
  const official = answerLetters(answer);
  if (/判断型阅读/.test(type)) {
    const questionBlock = body.match(/阅读短文，?判断下列句子正\(T\)误\(F\)。?\n([\s\S]*)$/)?.[1] || '';
    return [...questionBlock.matchAll(/^(\d+)\.?\s+(.+?)(?:\s*\[\s*\])?\s*$/gm)].map(([, number, prompt]) => {
      const index = Number(number); const value = official.get(index);
      return value ? { id: `q${index}`, index, prompt: clean(prompt), options: ['T', 'F'], answerIndex: value === 'T' ? 0 : 1, type: 'single', answerSource: 'official' }
        : unsupported(index, clean(prompt), '', 'missing_official_answer');
    });
  }
  if (/选词填空|完形填空/.test(type)) {
    const bank = [...body.matchAll(/^([A-H])\.\s*(.+)$/gm)].map(([, letter, value]) => ({ letter, value: clean(value) }));
    const indexes = [...official.keys()].sort((left, right) => left - right);
    return indexes.map(index => {
      const value = official.get(index); const answerIndex = bank.findIndex(option => option.letter === value);
      return answerIndex >= 0 ? { id: `q${index}`, index, prompt: `填空 ${index}`, options: bank.map(option => option.value), answerIndex, type: 'single', answerSource: 'official' }
        : unsupported(index, `填空 ${index}`, value, 'unmapped_answer_option');
    });
  }
  if (/任务型阅读/.test(type)) {
    const answerMatch = answer.match(/任务[一二三四]：\s*([A-D])\b/);
    const promptMatch = body.match(/(Which can be put in ▲[^\n]*|该图书馆可能是下列哪个集装箱改装的？)/);
    const optionArea = promptMatch
      ? body.slice(promptMatch.index).split(/\n任务[二三四]：/)[0]
      : body;
    const options = parseOptions(optionArea);
    if (options.length >= 2 && answerMatch && promptMatch) {
      const answerIndex = optionIndex(answerMatch[1]);
      return [{ id: 'q1', index: 1, prompt: promptMatch[1], options: options.map(option => option.value), answerIndex, type: 'single', answerSource: 'official' }];
    }
    return [unsupported(1, '任务型阅读（请按原文完成任务）', clean(answer), 'task_response_not_auto_gradable')];
  }

  const questionBlocks = [...body.matchAll(/^(\d+)\s+(.+?)(?=^\d+\s+|\n【答案】|$)/gms)];
  return questionBlocks.map(([, number, block]) => {
    const index = Number(number); const options = parseOptions(block); const value = official.get(index);
    const prompt = clean(block.slice(0, block.search(/(?:^|\n)A\./m)) || block);
    if (options.length >= 2 && value && optionIndex(value) >= 0 && !options.some(option => /\[图片\]|^$/.test(option.value))) {
      return { id: `q${index}`, index, prompt, options: options.map(option => option.value), answerIndex: optionIndex(value), type: 'single', answerSource: 'official' };
    }
    return unsupported(index, prompt, value || clean(answer), /\[图片\]/.test(block) ? 'image_dependent' : 'unsupported_question_format');
  });
};

const source = fs.readFileSync(args.input, 'utf8').trim();
const entries = source.split(/(?=^===== 第 \d+ 篇 \|)/m).filter(Boolean);
const skipped = [];
const articles = [];
for (const entry of entries) {
  const header = entry.match(/^===== 第 (\d+) 篇 \| 原书P(\d+) \| PDF页(\d+) =====\n【(.+?)】（(.+?)）/m);
  const body = (entry.match(/【正文】\n([\s\S]*?)(?=\n【答案】|$)/) || [])[1] || '';
  const answer = (entry.match(/【答案】\n([\s\S]*)$/) || [])[1] || '';
  if (!header || !body || !answer) { skipped.push({ entry: header?.[1] || '', issue: 'missing_required_section' }); continue; }
  const [, sequence, bookPage, pdfPage, title, type] = header;
  const withoutDirections = body.replace(/^阅读短文[^\n]*\n(?:[A-H]\.\s*[^\n]*\n)*/m, '');
  const questionStart = /选词填空|完形填空/.test(type)
    ? withoutDirections.search(/^1\s+_+/m)
    : withoutDirections.search(/^(阅读短文|任务一|\d+\s+.+?\s*\[\s*\])/m);
  const reading = clean(questionStart >= 0 ? withoutDirections.slice(0, questionStart) : withoutDirections);
  const questions = parseQuestions({ body, answer, type });
  const officialIndexes = [...answerLetters(answer).keys()].sort((left, right) => left - right);
  const questionIndexes = questions.map(question => question.index).sort((left, right) => left - right);
  const requiresExactQuestionMapping = /判断型阅读|阅读理解/.test(type);
  if (!reading || (requiresExactQuestionMapping && JSON.stringify(questionIndexes) !== JSON.stringify(officialIndexes))) {
    skipped.push({ entry: Number(sequence), title, issue: 'incomplete_source', questionCount: questions.length }); continue;
  }
  const data = splitEnglishSentences(reading).map((sentence, index) => readerSentence(sentence, 1, index + 1));
  if (!data.length) { skipped.push({ entry: Number(sequence), title, issue: 'no_english_sentences' }); continue; }
  articles.push({
    id: `shiwen-no30-${String(sequence).padStart(2, '0')}`, title: `时文阅读 No.30 / ${String(sequence).padStart(2, '0')} / ${title}`,
    source: { collection: '时文阅读', issue: 'No.30', originalBookPage: Number(bookPage), pdfPage: Number(pdfPage), type },
    data, questions, generatedBy: 'source-import'
  });
}
const report = { generatedAt: new Date().toISOString(), input: args.input, sourceEntryCount: entries.length, articleCount: articles.length, skipped, autoGradableQuestionCount: articles.flatMap(article => article.questions).filter(question => question.type === 'single').length, unsupportedQuestionCount: articles.flatMap(article => article.questions).filter(question => question.type !== 'single').length };
fs.mkdirSync(path.dirname(args.output), { recursive: true });
fs.writeFileSync(args.output, `${JSON.stringify(articles, null, 2)}\n`);
fs.writeFileSync(args.report, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify(report, null, 2));
