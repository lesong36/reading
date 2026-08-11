#!/usr/bin/env node
/**
 * Publish only staged TPO/OG analyses that pass the non-negotiable structural
 * quality gate. The current public 104-article pack is backed up before it is
 * replaced; rejected and unprocessed articles are deliberately absent.
 */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.cwd();
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'data/tpo-source/manifest.json'), 'utf8'));
const cleanManifestPath = path.join(root, 'data/tpo-source-clean/manifest.json');
const cleanEntriesById = fs.existsSync(cleanManifestPath)
  ? new Map(JSON.parse(fs.readFileSync(cleanManifestPath, 'utf8')).entries.map(entry => [entry.id, entry]))
  : new Map();
const BATCH_FILTERS = {
  B1: /^(og|online-test|official-model-exam|og-test-2)-/i,
  B2: /^tpo-([1-9]|10)-/i,
  B3: /^tpo-(1[1-9]|20)-/i,
  B4: /^tpo-(2[1-9]|30)-/i
};
const parseArgs = (argv) => {
  const args = { batches: [], stageRoot: '' };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--batch') args.batches = next().split(',').map(value => value.trim()).filter(Boolean);
    else if (arg === '--stage-root') args.stageRoot = path.resolve(root, next());
    else throw new Error(`Unknown argument: ${arg}`);
  }
  for (const batch of args.batches) {
    if (!BATCH_FILTERS[batch]) throw new Error(`Unknown batch ${batch}`);
  }
  return args;
};
const args = parseArgs(process.argv.slice(2));
const defaultStageRoots = [
  '.tmp_model_compare/og-dual-gpu-2026-08-10T11-56-49-250Z/mac/output',
  '.tmp_model_compare/og-dual-gpu-2026-08-10T11-56-49-250Z/p920/output',
  '.tmp_model_compare/b1-remainder-dual-gpu-2026-08-10T14-14-12-755Z/mac/output',
  '.tmp_model_compare/b1-remainder-dual-gpu-2026-08-10T14-14-12-755Z/p920/output',
  '.tmp_model_compare/b2-dual-gpu-2026-08-10T14-46-29-693Z/mac/output',
  '.tmp_model_compare/b2-dual-gpu-2026-08-10T14-46-29-693Z/p920/output'
].map(item => path.join(root, item));
const stageRoots = args.stageRoot ? [args.stageRoot] : defaultStageRoots;
const allowedTypes = new Set([
  'subject', 'verb', 'object', 'predicative', 'object-complement',
  'clause-subject', 'clause-verb', 'clause-object', 'clause-predicative',
  'coord-subject', 'coord-verb', 'coord-object', 'coord-predicative',
  'conjunction', 'modifier', 'adverbial'
]);
const sourceById = new Map((manifest.articles || []).map(item => [item.id, item]));
const sources = args.batches.length
  ? (manifest.articles || []).filter(item => args.batches.some(batch => BATCH_FILTERS[batch].test(item.id)))
  : (manifest.articles || []);
const accepted = new Map();
const rejected = [];

const validate = (section) => {
  const issues = [];
  const rows = section?.article?.data;
  if (!Array.isArray(rows) || rows.length === 0) return ['missing_article_data'];
  if (section.generatedBy === 'local-fallback') issues.push('fallback_section');
  if (section.warnings?.length) issues.push('section_warnings');
  for (const sentence of rows) {
    const sourceText = String(sentence?.text || '').trim();
    const segments = Array.isArray(sentence?.segments) ? sentence.segments : [];
    if (!segments.length) issues.push(`${sentence?.id || '?'}:missing_segments`);
    else if (segments.map(segment => segment?.text || '').join('') !== sentence.text) issues.push(`${sentence?.id || '?'}:segments_do_not_reconstruct_text`);
    else if (segments.some(segment => !allowedTypes.has(String(segment?.type || '').trim()))) issues.push(`${sentence?.id || '?'}:invalid_segment_type`);
    if (/^(?:Paragraph\s*\d+|Directions|Answer Choices?)[:：]/i.test(sourceText) || /^(?:[A-D]|\d+)[.)]?$/.test(sourceText)) {
      issues.push(`${sentence?.id || '?'}:question_material_in_body`);
    }
    if (sentence?.generatedBy === 'local-fallback') issues.push(`${sentence?.id || '?'}:fallback_sentence`);
  }
  return issues;
};

for (const stageRoot of stageRoots) {
  if (!fs.existsSync(stageRoot)) continue;
  for (const entry of fs.readdirSync(stageRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const sectionDir = path.join(stageRoot, entry.name, 'sections');
    if (!fs.existsSync(sectionDir)) continue;
    for (const file of fs.readdirSync(sectionDir).filter(name => name.endsWith('.json')).sort()) {
      const filePath = path.join(sectionDir, file);
      let section;
      try { section = JSON.parse(fs.readFileSync(filePath, 'utf8')); }
      catch (error) { rejected.push({ id: entry.name, file: path.relative(root, filePath), issues: ['invalid_json'] }); continue; }
      const sourceId = path.basename(section.sourceFile || '', '.md');
      const issues = validate(section);
      if (!sourceById.has(sourceId)) {
        rejected.push({ id: sourceId || entry.name, file: path.relative(root, filePath), issues: ['not_in_manifest'] });
      } else if (issues.length) {
        rejected.push({ id: sourceId, file: path.relative(root, filePath), issues });
      } else if (!accepted.has(sourceId)) {
        accepted.set(sourceId, { section, file: path.relative(root, filePath) });
      }
    }
  }
}

const articles = [];
for (const source of sources) {
  const acceptedItem = accepted.get(source.id);
  if (!acceptedItem) continue;
  const questionsPath = path.join(root, 'data/tpo-source', source.questionsPath);
  const quiz = JSON.parse(fs.readFileSync(questionsPath, 'utf8'));
  articles.push({
    ...acceptedItem.section.article,
    id: source.id,
    title: `${source.section} / ${source.title}`,
    questions: quiz.questions || [],
    unsupportedQuestions: quiz.unsupported || [],
    footnotes: cleanEntriesById.get(source.id)?.footnotes || []
  });
}

const output = path.join(root, 'data/generated-reader-json/reader-articles-tpo.import.json');
const report = path.join(root, 'data/generated-reader-json/reader-articles-tpo.report.json');
const backupDir = path.join(root, '.tmp_model_compare', `tpo-pack-backup-${new Date().toISOString().replace(/[:.]/g, '-')}`);
fs.mkdirSync(backupDir, { recursive: true });
if (fs.existsSync(output)) fs.copyFileSync(output, path.join(backupDir, 'reader-articles-tpo.import.before-quality-filter.json'));
if (fs.existsSync(report)) fs.copyFileSync(report, path.join(backupDir, 'reader-articles-tpo.report.before-quality-filter.json'));
const approvedIds = new Set(articles.map(article => article.id));
const excluded = sources.filter(source => !approvedIds.has(source.id)).map(source => ({ id: source.id, title: `${source.section} / ${source.title}` }));
const payload = {
  generatedAt: new Date().toISOString(),
  policy: 'strict structural gate: exact reconstruction, non-empty segments, approved labels, no fallback',
  batch: args.batches.join(',') || 'all-staged',
  sourceExpectedCount: sources.length,
  approvedCount: articles.length,
  excludedCount: excluded.length,
  approved: articles.map(article => ({ id: article.id, title: article.title })),
  excluded,
  rejectedStageOutputs: rejected,
  stageRoots: stageRoots.map(item => path.relative(root, item)),
  backup: path.relative(root, backupDir)
};
fs.writeFileSync(output, `${JSON.stringify(articles, null, 2)}\n`);
fs.writeFileSync(report, `${JSON.stringify(payload, null, 2)}\n`);
console.log(JSON.stringify({ output, report, approvedCount: articles.length, excludedCount: excluded.length, backup: backupDir }, null, 2));
