#!/usr/bin/env node
/** Resume-safe, serial P920 batch runner for RFD1–6 and RE article models. */
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const root = process.cwd();
const args = process.argv.slice(2);
const valueAfter = (flag, fallback = '') => {
  const index = args.indexOf(flag);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const has = (flag) => args.includes(flag);
const collections = valueAfter('--collections', 'rfd,re').split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
const outputDir = path.resolve(root, valueAfter('--output', 'data/article-reading-model-v1'));
const baseUrl = valueAfter('--base-url', process.env.LLM_BASE_URL || 'http://100.121.25.47:8090/v1');
const model = valueAfter('--model', process.env.LLM_MODEL || '');
const limit = Math.max(0, Number(valueAfter('--limit', '0')) || 0);
const dryRun = has('--dry-run');
const force = has('--force');
const reportPath = path.join(outputDir, '.batch-progress.json');
const sources = {
  rfd: { library: 'data/generated-reader-json/reader-articles.import.json', matches: article => /^rfd[1-6]-/.test(article.id), gradeBand: 'upper_elementary' },
  re: { library: 'data/generated-reader-json/reader-articles-re-foundations.import.json', matches: article => article.id.startsWith('re-foundations-'), gradeBand: 'upper_elementary' }
};
if (!collections.length || collections.some(name => !sources[name])) throw new Error('--collections accepts rfd,re');

const run = (command, commandArgs) => new Promise((resolve, reject) => {
  const child = spawn(command, commandArgs, { cwd: root, stdio: 'inherit' });
  child.once('error', reject);
  child.once('exit', code => code === 0 ? resolve() : reject(new Error(`${path.basename(command)} exited ${code}`)));
});
const saveReport = (report) => {
  fs.mkdirSync(outputDir, { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
};

const queue = collections.flatMap(collection => {
  const source = sources[collection];
  const library = JSON.parse(fs.readFileSync(path.join(root, source.library), 'utf8'));
  return library.filter(source.matches).map(article => ({ collection, library: source.library, gradeBand: source.gradeBand, id: article.id }));
}).filter(item => force || !fs.existsSync(path.join(outputDir, `${item.id}.json`)));
const items = limit ? queue.slice(0, limit) : queue;
const report = {
  startedAt: new Date().toISOString(), collections, candidateCount: queue.length, scheduledCount: items.length,
  completed: [], failed: [], skippedExisting: queue.length === 0 ? 0 : collections.flatMap(collection => JSON.parse(fs.readFileSync(path.join(root, sources[collection].library), 'utf8')).filter(sources[collection].matches)).length - queue.length
};

if (dryRun) {
  console.log(JSON.stringify({ ...report, items: items.map(item => ({ collection: item.collection, id: item.id })) }, null, 2));
  process.exit(0);
}

for (const item of items) {
  const generatorArgs = [
    'scripts/generate-article-reading-model.mjs', '--library', item.library, '--only', item.id,
    '--output', path.relative(root, outputDir), '--grade-band', item.gradeBand,
    '--provider', 'openai', '--base-url', baseUrl
  ];
  if (model) generatorArgs.push('--model', model);
  if (force) generatorArgs.push('--force');
  try {
    console.log(`\n[${report.completed.length + report.failed.length + 1}/${items.length}] ${item.id}`);
    await run(process.execPath, generatorArgs);
    await run(process.execPath, ['scripts/validate-article-reading-model.mjs', path.relative(root, path.join(outputDir, `${item.id}.json`)), '--library', item.library]);
    report.completed.push({ ...item, completedAt: new Date().toISOString() });
  } catch (error) {
    report.failed.push({ ...item, failedAt: new Date().toISOString(), error: error.message });
  }
  saveReport(report);
}
report.finishedAt = new Date().toISOString();
saveReport(report);
console.log(JSON.stringify({ completed: report.completed.length, failed: report.failed.length, reportPath }, null, 2));
if (report.failed.length) process.exitCode = 1;
