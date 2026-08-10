#!/usr/bin/env node
/**
 * Merge Qwen's validated 时文逐句解析 into the extracted article pack.
 * Questions and official answers remain entirely from the extracted source;
 * the model contributes only learning annotations (translation/grammar).
 */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const sourcePath = path.resolve(cwd, 'data/generated-reader-json/reader-articles-shiwen.import.json');
const analysisDir = path.resolve(cwd, 'data/generated-reader-json-shiwen/shiwen-no30/sections');
const reportPath = path.resolve(cwd, 'data/generated-reader-json/reader-articles-shiwen.report.json');

const sectionIdFromFile = (name) => name.match(/^\d+-(shiwen-no30-\d+)\.json$/)?.[1] || '';
const hasFallback = (section) => section?.generatedBy === 'local-fallback'
  || section?.article?.data?.some(sentence => sentence?.generatedBy === 'local-fallback');
const comparableText = (value) => String(value || '')
  // The sentence splitter/model can format one ellipsis as ". . .".  Treat
  // that typography-only form as equivalent without hiding word changes.
  .replace(/\.\s+\.\s+\./g, '...')
  .replace(/\s+/g, ' ')
  .trim();

const protectInvalidSegments = (article) => {
  let count = 0;
  const data = (article?.data || []).map(sentence => {
    const joined = (sentence.segments || []).map(segment => segment.text || '').join('');
    if (joined === sentence.text) return sentence;
    count += 1;
    return {
      ...sentence,
      segments: [{
        text: sentence.text,
        type: 'modifier',
        label: '完整句（自动保护，详见下方解析）'
      }],
      autoSegmentFallback: true
    };
  });
  return { article: { ...article, data }, count };
};

const validateSection = (section, source, file) => {
  const errors = [];
  const articleId = source.id;
  if (section?.sectionTitle !== articleId) errors.push({ articleId, file, issue: 'section_title_mismatch' });
  if (!Array.isArray(section?.article?.data) || section.article.data.length === 0) {
    errors.push({ articleId, file, issue: 'missing_article_data' });
  }
  if (hasFallback(section)) errors.push({ articleId, file, issue: 'full_fallback_not_allowed' });
  if (section?.warnings?.length) errors.push({ articleId, file, issue: 'section_has_warnings' });
  const sourceText = comparableText((source.data || []).map(sentence => sentence.text).join(' '));
  const analysisText = comparableText((section?.article?.data || []).map(sentence => sentence.text).join(' '));
  if (sourceText !== analysisText) errors.push({ articleId, file, issue: 'analysis_does_not_match_clean_source' });
  return errors;
};

const main = () => {
  if (!fs.existsSync(sourcePath)) throw new Error('Missing 时文 source pack. Run: npm run build:shiwen');
  if (!fs.existsSync(analysisDir)) throw new Error('Missing 时文 analyses. Run: npm run analyze:md-sections');
  const sourceArticles = JSON.parse(fs.readFileSync(sourcePath, 'utf8'));
  const filesById = new Map(fs.readdirSync(analysisDir)
    .filter(name => name.endsWith('.json'))
    .map(name => [sectionIdFromFile(name), name])
    .filter(([id]) => id));
  const errors = [];
  const articles = [];
  let autoSegmentFallbackCount = 0;

  for (const source of sourceArticles) {
    const file = filesById.get(source.id);
    if (!file) {
      errors.push({ articleId: source.id, issue: 'missing_analysis' });
      continue;
    }
    let section;
    try {
      section = JSON.parse(fs.readFileSync(path.join(analysisDir, file), 'utf8'));
    } catch (error) {
      errors.push({ articleId: source.id, file, issue: 'invalid_analysis_json', error: error.message });
      continue;
    }
    const sectionErrors = validateSection(section, source, file);
    if (sectionErrors.length) {
      errors.push(...sectionErrors);
      continue;
    }
    const protectedResult = protectInvalidSegments(section.article);
    autoSegmentFallbackCount += protectedResult.article.data.filter(sentence => sentence.autoSegmentFallback).length;
    articles.push({
      ...source,
      data: protectedResult.article.data,
      glossary: protectedResult.article.glossary || [],
      analysisSource: protectedResult.article.source,
      analysisGeneratedAt: section.generatedAt
    });
  }

  const report = {
    generatedAt: new Date().toISOString(),
    expectedCount: sourceArticles.length,
    successCount: articles.length,
    errorCount: errors.length,
    autoSegmentFallbackCount,
    errors
  };
  fs.writeFileSync(sourcePath, `${JSON.stringify(articles, null, 2)}\n`);
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`时文 merged import JSON: ${sourcePath}`);
  console.log(`时文 merge report: ${reportPath}`);
  if (errors.length) process.exitCode = 1;
};

main();
