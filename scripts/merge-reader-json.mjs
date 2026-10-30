import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();

const parseArgs = (argv) => {
  const args = {
    root: path.resolve(cwd, 'data/generated-reader-json'),
    stems: ['rfd1', 'rfd2', 'rfd3', 'rfd4', 'rfd5', 'rfd6', 'rfc1', 'rfc2', 'rfc3'],
    requireNoFallback: true
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--root') args.root = path.resolve(next());
    else if (arg === '--stems') args.stems = next().split(',').map(item => item.trim()).filter(Boolean);
    else if (arg === '--allow-fallback') args.requireNoFallback = false;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
};

const isFallbackSection = (section) =>
  section?.generatedBy === 'local-fallback' ||
  section?.article?.data?.some(sentence =>
    sentence?.generatedBy === 'local-fallback' ||
    /本地兜底|模型失败后的本地兜底/.test(`${sentence?.translation || ''}\n${sentence?.analysis || ''}`)
  );

const validateSection = ({ section, file, requireNoFallback }) => {
  const issues = [];
  if (!section?.article || !Array.isArray(section.article.data) || section.article.data.length === 0) {
    issues.push({ file, issue: 'missing_article_data' });
  }
  if (requireNoFallback && isFallbackSection(section)) {
    issues.push({ file, issue: 'fallback_section_not_allowed' });
  }
  if (Array.isArray(section?.warnings) && section.warnings.length > 0) {
    issues.push({ file, issue: 'section_has_warnings', count: section.warnings.length });
  }
  for (const sentence of section?.article?.data || []) {
    const segmentText = (sentence.segments || []).map(segment => segment.text || '').join('');
    if (segmentText !== sentence.text) {
      issues.push({
        file,
        sentenceId: sentence.id || '',
        issue: 'segments_do_not_reconstruct_text',
        text: sentence.text,
        segmentText
      });
    }
  }
  return issues;
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  const articles = [];
  const errors = [];
  const warnings = [];

  for (const stem of args.stems) {
    const sectionDir = path.join(args.root, stem, 'sections');
    if (!fs.existsSync(sectionDir)) {
      errors.push({ stem, issue: 'missing_section_dir', dir: sectionDir });
      continue;
    }

    const files = fs.readdirSync(sectionDir)
      .filter(name => name.endsWith('.json'))
      .sort((left, right) => left.localeCompare(right));

    for (const fileName of files) {
      const filePath = path.join(sectionDir, fileName);
      const relative = path.relative(cwd, filePath);
      try {
        const section = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        const issues = validateSection({ section, file: relative, requireNoFallback: args.requireNoFallback });
        if (issues.length > 0) {
          errors.push(...issues);
          continue;
        }
        articles.push(section.article);
      } catch (error) {
        errors.push({ file: relative, issue: 'invalid_json', error: error.message });
      }
    }
  }

  const report = {
    generatedAt: new Date().toISOString(),
    root: path.relative(cwd, args.root),
    stems: args.stems,
    sectionCount: articles.length + errors.filter(error => error.file).length,
    successCount: articles.length,
    errorCount: errors.length,
    warningCount: warnings.length,
    warnings,
    errors
  };

  const importPath = path.join(args.root, 'reader-articles.import.json');
  const reportPath = path.join(args.root, 'reader-articles.report.json');
  fs.writeFileSync(importPath, `${JSON.stringify(articles, null, 2)}\n`);
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

  console.log(`Combined import JSON: ${importPath}`);
  console.log(`Report: ${reportPath}`);
  if (errors.length > 0) process.exitCode = 1;
};

main();
