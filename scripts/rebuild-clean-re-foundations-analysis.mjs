#!/usr/bin/env node
/**
 * Reuse only previously generated sentences that are present in the audited
 * source text. This is a recovery path for malformed model JSON, never a way
 * to reintroduce slide teaching material.
 */
import fs from 'node:fs';
import path from 'node:path';

const cwd = process.cwd();
const sourceIndex = process.argv.indexOf('--source');
const sourceRoot = path.resolve(sourceIndex >= 0 ? process.argv[sourceIndex + 1] : path.join(cwd, 'data/re-foundations-source-v14'));
const priorRoots = [
  path.join(cwd, 'data/generated-reader-json-re-foundations-v5'),
  path.join(cwd, 'data/generated-reader-json-re-foundations-v4'),
  path.join(cwd, 'data/generated-reader-json-re-foundations-v2'),
  path.join(cwd, 'data/generated-reader-json-re-foundations')
];
const outputRoot = path.join(cwd, 'data/generated-reader-json-re-foundations-clean');
const normalize = (value = '') => String(value)
  .toLowerCase().replace(/[“”‘’]/g, "'").replace(/\s+/g, ' ').trim();
const removeFlattenedFootnoteMarkers = (value = '') => String(value)
  .replace(/(?<=[\p{L}”’])\s+[1-9](?=\s+(?:and|of|for|in|to|,|\.|;|—))/gu, '')
  .trim();
const sectionFile = (root, id) => {
  const dir = path.join(root, id, 'sections');
  return fs.existsSync(dir) ? fs.readdirSync(dir).find((name) => name.endsWith('.json')) : null;
};
const main = () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'manifest.json'), 'utf8'));
  const report = { expected: manifest.extractedCount, success: 0, failures: [] };
  for (const article of manifest.articles) {
    const source = fs.readFileSync(path.join(sourceRoot, article.mdPath), 'utf8').replace(/^#.*\n+/, '');
    const sourceNormalized = normalize(source);
    const ids = article.id === 're-foundations-1a-a-mysterious-visitor'
      ? [article.id, 're-foundations-1a-mysterious-visitor'] : [article.id];
    let section = null;
    for (const root of priorRoots) {
      for (const id of ids) {
        const file = sectionFile(root, id);
        if (file) { section = JSON.parse(fs.readFileSync(path.join(root, id, 'sections', file), 'utf8')); break; }
      }
      if (section) break;
    }
    const data = section?.article?.data;
    if (!Array.isArray(data)) { report.failures.push({ id: article.id, issue: 'no_prior_analysis' }); continue; }
    const kept = data.map((sentence) => ({ ...sentence, text: removeFlattenedFootnoteMarkers(sentence.text) })).filter((sentence) => {
      const text = normalize(sentence.text);
      return text.length >= 4 && sourceNormalized.includes(text);
    });
    const wordsCovered = new Set(kept.flatMap((sentence) => normalize(sentence.text).match(/[a-z]+/g) || []));
    const sourceWords = [...new Set(sourceNormalized.match(/[a-z]+/g) || [])];
    const coverage = sourceWords.filter((word) => wordsCovered.has(word)).length / Math.max(sourceWords.length, 1);
    if (kept.length === 0 || coverage < 0.94) {
      report.failures.push({ id: article.id, issue: 'insufficient_clean_coverage', kept: kept.length, coverage });
      continue;
    }
    const rebuilt = { ...section, article: { ...section.article, id: article.id, title: `${article.section} / ${article.title}`, data: kept } };
    const dir = path.join(outputRoot, article.id, 'sections');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `clean-${article.id}.json`), `${JSON.stringify(rebuilt, null, 2)}\n`);
    report.success += 1;
  }
  fs.writeFileSync(path.join(outputRoot, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report, null, 2));
  if (report.failures.length) process.exitCode = 1;
};
main();
