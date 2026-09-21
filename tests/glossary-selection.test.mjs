import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

test('limits newly generated glossary entries to the requested categories', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'index.html'), 'utf8');
  assert.match(source, /GENERATED_GLOSSARY_KINDS = new Set\(\['domain_term', 'cultural_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /normalizeGeneratedGlossary\(parsed\.glossary \|\| \[\]\)/);
  assert.match(source, /entry\.kind === 'technical_term' \? \{ \.\.\.entry, kind: 'domain_term' \}/);
  assert.match(source, /每个候选词须通过以下四项检查/);
  assert.match(source, /领域性：.*学习难度：.*语义特殊性：.*语言来源：/s);
  assert.match(source, /不得因词条是文章标题、核心概念、主题词、题目答案或关键动作就自动收录或排除/);
  assert.match(source, /removeQuizTestedGlossary/);
  assert.match(source, /directlyTestedQuizTerms/);
  assert.match(source, /question\.type === 'word-bank'/);
  assert.match(source, /不要因为某词仅在主旨题、细节题、事实判断题、题干叙述、干扰项或定位材料中出现就排除它/);
  assert.doesNotMatch(source, /Ancient Egypt（古埃及）|tomb、thieves/);
  assert.doesNotMatch(source.slice(source.indexOf('const buildGlossarySelectionRules'), source.indexOf('const escapeRegExp')), /proper_noun|context_term/);
});

test('uses the same strict glossary contract in batch analysis', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'scripts/analyze-md-sections.mjs'), 'utf8');
  assert.match(source, /allowedKinds = new Set\(\['domain_term', 'cultural_term', 'rare_word', 'loanword', 'acronym'\]\)/);
  assert.match(source, /rawKind === 'technical_term' \? 'domain_term' : rawKind/);
  assert.match(source, /目标读者是正在阅读本文的中国学生/);
  assert.match(source, /不得因词条是文章标题、核心概念、主题词、题目答案或关键动作就自动收录或排除/);
  assert.doesNotMatch(source.slice(source.indexOf('const ANALYSIS_SYSTEM_PROMPT'), source.indexOf('const DEFAULT_CONFIG')), /proper_noun|context_term/);
});
