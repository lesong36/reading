#!/usr/bin/env node
/** Attach validated Article Reading Model sidecars to an existing bookshelf pack. */
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const args = process.argv.slice(2);
const valueAfter = (flag, fallback) => {
  const index = args.indexOf(flag);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const has = (flag) => args.includes(flag);
const libraryPath = path.resolve(root, valueAfter('--library', 'data/generated-reader-json/reader-articles-re-foundations.import.json'));
const modelDir = path.resolve(root, valueAfter('--model-dir', 'data/article-reading-model-v1'));
const publicModelDir = valueAfter('--public-model-dir', './data/article-reading-model-v1').replace(/\/+$/, '');
const only = valueAfter('--only', '');
const dryRun = has('--dry-run');
const files = fs.existsSync(modelDir) ? fs.readdirSync(modelDir).filter(file => file.endsWith('.json') && !file.startsWith('.')) : [];
const models = new Map(files.map(file => {
  const model = JSON.parse(fs.readFileSync(path.join(modelDir, file), 'utf8'));
  if (model?.schema_version !== '1.0' || !model?.article?.id) throw new Error(`Invalid model sidecar: ${file}`);
  return [model.article.id, file];
}));
const articles = JSON.parse(fs.readFileSync(libraryPath, 'utf8'));
let attached = 0;
const next = articles.map(article => {
  if (only && article.id !== only) return article;
  const file = models.get(article.id);
  if (!file) return article;
  attached += 1;
  return { ...article, readingModelPath: `${publicModelDir}/${file}` };
});
if (!attached) throw new Error(only ? `No model sidecar found for ${only}` : 'No model sidecars matched this library.');
if (!dryRun) fs.writeFileSync(libraryPath, `${JSON.stringify(next, null, 2)}\n`);
console.log(JSON.stringify({ dryRun, libraryPath, attached, articleIds: next.filter(article => article.readingModelPath).map(article => article.id) }, null, 2));
