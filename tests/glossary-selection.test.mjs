import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

test('limits newly generated glossary entries to the requested categories', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'index.html'), 'utf8');
  assert.match(source, /GENERATED_GLOSSARY_KINDS = new Set\(\['technical_term', 'cultural_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /const glossary = normalizeGeneratedGlossary\(parsed\.glossary \|\| \[\]\)/);
  assert.match(source, /正例：tomb、thieves、statues、furniture、jars、mummy/);
  assert.match(source, /Ancient Egypt（古埃及）、Ancient Egyptian（古埃及的）、ancient Egyptians（古埃及人）、Nile River（尼罗河）/);
  assert.match(source, /即使也是主题词或题目答案，仍然必须保留/);
  assert.doesNotMatch(source.slice(source.indexOf('const buildGlossarySelectionRules'), source.indexOf('const escapeRegExp')), /proper_noun|context_term/);
});

test('uses the same strict glossary contract in batch analysis', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'scripts/analyze-md-sections.mjs'), 'utf8');
  assert.match(source, /allowedKinds = new Set\(\['technical_term', 'cultural_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /以正在阅读本文的中国学生为准/);
  assert.match(source, /即使也是主题词或题目答案，仍然必须保留/);
  assert.doesNotMatch(source.slice(source.indexOf('const ANALYSIS_SYSTEM_PROMPT'), source.indexOf('const DEFAULT_CONFIG')), /proper_noun|context_term/);
});
