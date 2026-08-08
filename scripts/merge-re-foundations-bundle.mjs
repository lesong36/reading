#!/usr/bin/env node
/** Merge RE Foundations analyses with PPT-derived quiz metadata. */
import fs from 'node:fs';
import path from 'node:path';
import { reFoundationsAnswerKeys } from './re-foundations-answer-keys.mjs';

const cwd = process.cwd();
const getArg = (name, fallback) => {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? path.resolve(process.argv[index + 1]) : fallback;
};
const sourceRoot = getArg('--source', path.join(cwd, 'data/re-foundations-source'));
const analysisRoot = getArg('--analysis', path.join(cwd, 'data/generated-reader-json-re-foundations'));
const outputPath = path.join(cwd, 'data/generated-reader-json/reader-articles-re-foundations.import.json');
const reportPath = path.join(cwd, 'data/generated-reader-json/reader-articles-re-foundations.report.json');
const sourceAssetsRoot = path.join(sourceRoot, 'assets');
const outputAssetsRoot = path.join(cwd, 'data/generated-reader-json/re-foundations-assets');

const applyVerifiedAnswers = (questions, articleId) => (questions || []).map((question) => {
  const answerIndex = reFoundationsAnswerKeys[articleId]?.[question.index];
  if (!Number.isInteger(answerIndex) || !Array.isArray(question.options) || question.options.length < 2) return question;
  return { ...question, answerIndex, type: 'single', reason: '' };
});

const main = () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'manifest.json'), 'utf8'));
  const articles = [];
  const errors = [];
  for (const source of manifest.articles || []) {
    const sectionDir = path.join(analysisRoot, source.id, 'sections');
    const files = fs.existsSync(sectionDir) ? fs.readdirSync(sectionDir).filter((name) => name.endsWith('.json')) : [];
    if (files.length !== 1) {
      errors.push({ id: source.id, issue: 'missing_or_ambiguous_analysis', count: files.length });
      continue;
    }
    const section = JSON.parse(fs.readFileSync(path.join(sectionDir, files[0]), 'utf8'));
    if (!Array.isArray(section?.article?.data) || section.article.data.length === 0 || section.generatedBy === 'local-fallback') {
      errors.push({ id: source.id, issue: 'invalid_or_fallback_analysis' });
      continue;
    }
    const quiz = JSON.parse(fs.readFileSync(path.join(sourceRoot, source.questionsPath), 'utf8'));
    // Geometry-first article extraction deliberately ignores quiz-page text.
    // Preserve previously recovered PPT quiz metadata when it exists, while
    // retaining unsupported status whenever no official answer is available.
    const legacyQuizPath = path.join(cwd, 'data/re-foundations-source-v6', source.questionsPath);
    const legacyQuiz = (!quiz.questions?.length && !quiz.unsupported?.length && fs.existsSync(legacyQuizPath))
      ? JSON.parse(fs.readFileSync(legacyQuizPath, 'utf8'))
      : null;
    const resolvedQuiz = legacyQuiz || quiz;
    const resolvedQuestions = applyVerifiedAnswers([
      ...(resolvedQuiz.questions || []),
      ...(resolvedQuiz.unsupported || [])
    ], source.id);
    articles.push({
      ...section.article,
      id: source.id,
      title: `${source.section} / ${source.title}`,
      questions: resolvedQuestions.filter((question) => question.type === 'single'),
      unsupportedQuestions: resolvedQuestions.filter((question) => question.type !== 'single'),
      paragraphLabels: Array.isArray(source.paragraphs) ? source.paragraphs.map((paragraph) => paragraph.label || '') : [],
      footnotes: source.footnotes || [],
      companions: source.companions || []
    });
  }
  const report = { generatedAt: new Date().toISOString(), expectedCount: manifest.extractedCount, successCount: articles.length, errorCount: errors.length, errors };
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  if (fs.existsSync(sourceAssetsRoot)) {
    fs.mkdirSync(outputAssetsRoot, { recursive: true });
    for (const name of fs.readdirSync(sourceAssetsRoot)) {
      fs.copyFileSync(path.join(sourceAssetsRoot, name), path.join(outputAssetsRoot, name));
    }
  }
  fs.writeFileSync(outputPath, `${JSON.stringify(articles, null, 2)}\n`);
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report));
  if (errors.length) process.exitCode = 1;
};

main();
