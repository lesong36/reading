#!/usr/bin/env node
/**
 * Build a derived, P920-ready passage corpus without changing the raw TPO
 * extraction.  The Word extractor deliberately retains question material for
 * quiz generation; that material must never be sent to the sentence analyser.
 *
 * Every truncation is deterministic and recorded with raw/clean SHA-256
 * hashes, the exact boundary line and the removed tail hash.  This gives the
 * release pipeline a reproducible source of truth and makes unsafe files
 * visible instead of silently editing them.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const defaults = {
  input: path.join(cwd, 'data/tpo-source/passages'),
  output: path.join(cwd, 'data/tpo-source-clean/passages'),
  report: path.join(cwd, 'data/tpo-source-clean/manifest.json'),
  sourceManifest: path.join(cwd, 'data/tpo-source/manifest.json'),
  dryRun: false
};

const parseArgs = (argv) => {
  const args = { ...defaults };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    const next = () => argv[++i];
    if (value === '--input') args.input = path.resolve(cwd, next());
    else if (value === '--output') args.output = path.resolve(cwd, next());
    else if (value === '--report') args.report = path.resolve(cwd, next());
    else if (value === '--source-manifest') args.sourceManifest = path.resolve(cwd, next());
    else if (value === '--dry-run') args.dryRun = true;
    else throw new Error(`Unknown argument: ${value}`);
  }
  return args;
};

const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
const lineNumberAt = (source, offset) => source.slice(0, offset).split('\n').length;

// These markers occur at the start of the post-reading exercise in the source
// Word export.  They are intentionally anchored to a new line; prose such as
// "paragraph 1" cannot trigger a truncation in the middle of article text.
const boundaryPatterns = [
  { id: 'paragraph_prompt', pattern: /(?:^|\n)\s*Paragraph\s*\d+\s*:/ig },
  { id: 'question_prompt', pattern: /(?:^|\n)\s*Questions?\s*\d+\s*[:.]/ig },
  { id: 'directions', pattern: /(?:^|\n)\s*Directions?\s*[:：]/ig },
  { id: 'answer_choices', pattern: /(?:^|\n)\s*Answer\s+Choices?\s*[:：]/ig },
  // A terminal numbered "term: definition" block is a textbook footnote
  // block, not a reading sentence. It is retained as structured metadata.
  { id: 'footnote_block', pattern: /(?:^|\n)\s*1\.\s+[A-Za-z][^\n]*:\s+[^\n]+(?:\n\s*\d+\.\s+[A-Za-z][^\n]*:\s+[^\n]+)*\s*$/ig }
];

const findBoundary = (source) => {
  const matches = [];
  for (const candidate of boundaryPatterns) {
    candidate.pattern.lastIndex = 0;
    const match = candidate.pattern.exec(source);
    if (match) {
      // Preserve the preceding newline in the match but truncate before it.
      const offset = match.index + (match[0].startsWith('\n') ? 1 : 0);
      matches.push({ id: candidate.id, offset, marker: match[0].trim() });
    }
  }
  return matches.sort((a, b) => a.offset - b.offset)[0] || null;
};

const normalize = (value) => value.toLowerCase().replace(/\s+/g, ' ').trim();
const parseFootnotes = (tail) => [...String(tail || '').matchAll(/^\s*(\d+)\.\s+(.+)$/gm)]
  .map((match) => ({ marker: match[1], text: match[2].trim() }));

const assess = (source, file, questionText) => {
  const boundary = findBoundary(source);
  const removedTail = boundary ? source.slice(boundary.offset) : '';
  const bodyBeforeBoundary = (boundary ? source.slice(0, boundary.offset) : source).replace(/^#\s+.+\n*/, '');
  const tailWithoutMarker = boundary ? removedTail.replace(/^\s*Paragraph\s*\d+\s*:/i, '') : '';
  const headingTitle = (source.match(/^#\s+[^/]+\/\s*(.+)$/m)?.[1] || '').trim();
  const evidenceFromQuestionData = boundary
    ? normalize(questionText).includes(normalize(removedTail).slice(0, 120))
    : false;
  // In three Word exports the exercise repeats the article paragraph verbatim
  // after Paragraph1 rather than embedding it in the question prompt.  A long
  // prefix match against the pre-boundary body is a deterministic proof of a
  // duplicate, not a heuristic about what prose "looks like".
  const normalizedBody = normalize(bodyBeforeBoundary);
  const normalizedTail = normalize(tailWithoutMarker);
  const tailWithoutRepeatedTitle = headingTitle && normalizedTail.startsWith(normalize(headingTitle))
    ? normalizedTail.slice(normalize(headingTitle).length).trim()
    : normalizedTail;
  const evidenceFromRepeatedBody = boundary
    ? normalizedBody.startsWith(normalizedTail.slice(0, 160)) || normalizedBody.startsWith(tailWithoutRepeatedTitle.slice(0, 160))
    : false;
  const footnotes = boundary?.id === 'footnote_block' ? parseFootnotes(removedTail) : [];
  const evidenceFromFootnotes = boundary?.id === 'footnote_block' && footnotes.length > 0;
  const markerEvidence = evidenceFromQuestionData || evidenceFromRepeatedBody || evidenceFromFootnotes;
  // Only a marker that is also present in this article's extracted question
  // data is a confirmed duplicate exercise block.  A natural "Paragraph 1:"
  // in article prose remains untouched and is quarantined for review.
  const shouldStrip = Boolean(boundary && markerEvidence);
  const clean = (shouldStrip ? source.slice(0, boundary.offset) : source).replace(/\s+$/, '') + '\n';
  const heading = /^#\s+.+$/m.test(clean);
  const body = clean.replace(/^#\s+.+\n*/, '').trim();
  const issues = [];
  if (!heading) issues.push('missing_markdown_heading');
  if (body.length < 180) issues.push('too_short_after_cleaning');
  if (boundary && !markerEvidence) issues.push('unverified_boundary_marker');
  return {
    id: path.basename(file, '.md'),
    rawPath: path.relative(cwd, file),
    rawSha256: sha256(source),
    cleanSha256: sha256(clean),
    rawChars: source.length,
    cleanChars: clean.length,
    removedChars: source.length - clean.length,
    footnotes,
    disposition: shouldStrip ? 'stripped_verified_quiz_duplicate' : boundary ? 'quarantined_unverified_marker' : 'accepted_unchanged',
    boundary: boundary && {
      kind: boundary.id,
      marker: boundary.marker,
      line: lineNumberAt(source, boundary.offset),
      verification: markerEvidence
        ? { questionData: evidenceFromQuestionData, repeatedArticlePrefix: evidenceFromRepeatedBody, terminalFootnotes: evidenceFromFootnotes }
        : null,
      removedTailSha256: sha256(removedTail)
    },
    issues,
    clean
  };
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.input)) throw new Error(`Input directory not found: ${args.input}`);
  const sourceManifest = JSON.parse(fs.readFileSync(args.sourceManifest, 'utf8'));
  const questionsById = new Map((sourceManifest.articles || []).map((article) => {
    const questionFile = path.join(cwd, 'data/tpo-source', article.questionsPath);
    const questions = JSON.parse(fs.readFileSync(questionFile, 'utf8'));
    return [article.id, (questions.questions || []).map(question => question.prompt || '').join('\n')];
  }));
  const files = fs.readdirSync(args.input).filter(name => name.endsWith('.md')).sort();
  const entries = files.map((name) => {
    const file = path.join(args.input, name);
    return assess(fs.readFileSync(file, 'utf8'), file, questionsById.get(path.basename(name, '.md')) || '');
  });
  const report = {
    generatedAt: new Date().toISOString(),
    policy: 'raw passages are immutable; clean passages are a deterministic body-only derivative for P920 analysis',
    input: path.relative(cwd, args.input),
    output: path.relative(cwd, args.output),
    expectedArticles: files.length,
    boundaryFoundCount: entries.filter(entry => entry.boundary).length,
    strippedVerifiedCount: entries.filter(entry => entry.disposition === 'stripped_verified_quiz_duplicate').length,
    acceptedUnchangedCount: entries.filter(entry => entry.disposition === 'accepted_unchanged').length,
    reviewRequiredCount: entries.filter(entry => entry.issues.length).length,
    entries: entries.map(({ clean, ...entry }) => entry)
  };
  if (!args.dryRun) {
    fs.rmSync(args.output, { recursive: true, force: true });
    fs.mkdirSync(args.output, { recursive: true });
    for (const entry of entries) fs.writeFileSync(path.join(args.output, `${entry.id}.md`), entry.clean);
    fs.mkdirSync(path.dirname(args.report), { recursive: true });
    fs.writeFileSync(args.report, `${JSON.stringify(report, null, 2)}\n`);
  }
  console.log(JSON.stringify({
    expectedArticles: report.expectedArticles,
    boundaryFoundCount: report.boundaryFoundCount,
    strippedVerifiedCount: report.strippedVerifiedCount,
    acceptedUnchangedCount: report.acceptedUnchangedCount,
    reviewRequiredCount: report.reviewRequiredCount,
    quarantined: report.entries.filter(entry => entry.issues.length).map(entry => entry.id)
  }, null, 2));
};

main();
