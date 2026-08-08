#!/usr/bin/env node
/** Verify that a RE Foundations source pack contains only article prose. */
import fs from 'node:fs';
import path from 'node:path';

const cwd = process.cwd();
const argIndex = process.argv.indexOf('--source');
const sourceRoot = path.resolve(argIndex >= 0 ? process.argv[argIndex + 1] : path.join(cwd, 'data/re-foundations-source'));
const manifest = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'manifest.json'), 'utf8'));
const forbidden = [
  /[\p{Script=Han}]/u,
  /_{3,}/,
  /\b(?:VOCABULARY LEARNING|READING COMPREHENSION|BEFORE YOU READ|WHILE READING)\b/i,
  /\bQuestion\s+\d+\s*:/i,
  /\bMain Idea\b/i,
  /(?:HOTTEST VCHILIES|KOBAYASHI.?S WORLD RECORDS|Passage Summary|Title Detail)/i
];
const failures = [];

if (manifest.expectedFiles !== 24 || manifest.extractedCount !== 24 || manifest.errorCount !== 0) {
  failures.push({ issue: 'incomplete_pack', expectedFiles: manifest.expectedFiles, extractedCount: manifest.extractedCount, errorCount: manifest.errorCount });
}
for (const article of manifest.articles || []) {
  const body = fs.readFileSync(path.join(sourceRoot, article.mdPath), 'utf8');
  const hit = forbidden.find((pattern) => pattern.test(body));
  if (hit) failures.push({ id: article.id, issue: 'teaching_material_in_body', pattern: String(hit) });
  if (!Array.isArray(article.paragraphs) || article.paragraphs.length < 2) {
    failures.push({ id: article.id, issue: 'paragraphs_not_recovered', count: article.paragraphs?.length || 0 });
  }
}

console.log(JSON.stringify({ sourceRoot, articleCount: manifest.articles?.length || 0, failureCount: failures.length, failures }, null, 2));
if (failures.length) process.exitCode = 1;
