#!/usr/bin/env node
/** Live, read-only progress monitor for the resumable local 时文阅读 analysis. */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const sourcePath = path.join(cwd, 'data/shiwen-source/shiwen-no30.md');
const outputRoot = path.join(cwd, 'data/generated-reader-json-shiwen');
const sectionDir = path.join(outputRoot, 'shiwen-no30', 'sections');
const args = process.argv.slice(2).reduce((result, arg, index, list) => {
  if (arg === '--watch') result.watch = true;
  else if (arg === '--json') result.json = true;
  else if (arg === '--interval') result.intervalMs = Math.max(1000, Number(list[index + 1]) * 1000 || 5000);
  return result;
}, { watch: false, json: false, intervalMs: 5000 });

const safeJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
};
const expectedIds = () => fs.existsSync(sourcePath)
  ? [...fs.readFileSync(sourcePath, 'utf8').matchAll(/^##\s+(shiwen-no30-\d+)\s*$/gm)].map(match => match[1])
  : [];
const snapshot = () => {
  const expected = expectedIds();
  const files = fs.existsSync(sectionDir) ? fs.readdirSync(sectionDir).filter(name => name.endsWith('.json')).sort() : [];
  const completed = [];
  const invalid = [];
  let sentenceCount = 0;
  let warningCount = 0;
  let fallbackCount = 0;
  for (const file of files) {
    const value = safeJson(path.join(sectionDir, file));
    if (!value?.article?.data?.length) { invalid.push(file); continue; }
    completed.push(value.sectionTitle || file);
    sentenceCount += value.article.data.length;
    warningCount += Array.isArray(value.warnings) ? value.warnings.length : 0;
    if (value.generatedBy === 'local-fallback' || value.article.generatedBy === 'local-fallback') fallbackCount += 1;
  }
  const complete = completed.length;
  const pending = Math.max(expected.length - complete, 0);
  return {
    updatedAt: new Date().toISOString(), expectedArticles: expected.length, completedArticles: complete,
    pendingArticles: pending, percent: expected.length ? Number((complete / expected.length * 100).toFixed(1)) : 0,
    sentenceCount, warningCount, fallbackCount, invalidFiles: invalid, latestCompleted: completed.at(-1) || null,
    state: pending === 0 && expected.length > 0 ? 'complete' : 'running'
  };
};
const print = () => {
  const state = snapshot();
  if (args.json) console.log(JSON.stringify(state));
  else {
    if (args.watch && process.stdout.isTTY) process.stdout.write('\x1Bc');
    console.log(`时文阅读本机解析 · ${state.state}`);
    console.log(`文章：${state.completedArticles}/${state.expectedArticles}（${state.percent}%） · 待处理：${state.pendingArticles}`);
    console.log(`句子：${state.sentenceCount} · 警告：${state.warningCount} · 兜底：${state.fallbackCount}`);
    console.log(`最近完成：${state.latestCompleted || '尚无'}`);
    if (state.invalidFiles.length) console.log(`无效输出：${state.invalidFiles.join(', ')}`);
    console.log(`更新时间：${state.updatedAt}`);
  }
  return state;
};
print();
if (args.watch) setInterval(() => {
  const state = print();
  if (state.state === 'complete') process.exit(0);
}, args.intervalMs);
