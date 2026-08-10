#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const cwd = process.cwd();
const input = path.join(cwd, 'data/generated-reader-json/reader-articles-shiwen.import.json');
const output = path.join(cwd, 'data/shiwen-source/shiwen-no30.md');
const articles = JSON.parse(fs.readFileSync(input, 'utf8'));
const markdown = articles.map(article => [
  `## ${article.id}`,
  '',
  article.data.map(sentence => sentence.text).join(' '),
  ''
].join('\n')).join('\n');
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, markdown);
console.log(`Prepared ${articles.length} 时文阅读 sections: ${output}`);
