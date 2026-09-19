import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

test('limits newly generated glossary entries to the requested categories', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'index.html'), 'utf8');
  assert.match(source, /GENERATED_GLOSSARY_KINDS = new Set\(\['technical_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /const glossary = normalizeGeneratedGlossary\(parsed\.glossary \|\| \[\]\)/);
  assert.doesNotMatch(source.slice(source.indexOf('const buildGlossarySelectionRules'), source.indexOf('const escapeRegExp')), /proper_noun|context_term/);
});

test('uses the same strict glossary contract in batch analysis', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'scripts/analyze-md-sections.mjs'), 'utf8');
  assert.match(source, /allowedKinds = new Set\(\['technical_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /文章标题或主题名称、一般人名地名、核心人物\/事物、关键动作/);
  assert.doesNotMatch(source.slice(source.indexOf('const ANALYSIS_SYSTEM_PROMPT'), source.indexOf('const DEFAULT_CONFIG')), /proper_noun|context_term/);
});
