import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

const cwd = process.cwd();

const requiredSentenceFields = [
  'id',
  'para',
  'text',
  'translation',
  'grammarFocus',
  'pronounRef',
  'logicConnector',
  'sentenceCoach',
  'teachingFocus',
  'analysis',
  'segments'
];

const requiredTeachingFields = [
  'mainQuestion',
  'grammarQuestion',
  'modifierQuestion',
  'relationshipQuestion',
  'commonMistake',
  'thinkingPath',
  'encouragement'
];

const expectedCounts = {
  rfd1: 16,
  rfd2: 16,
  rfd3: 16,
  '四上英语课文_英文': 24
};

const tpoPackPath = path.resolve(cwd, 'data/generated-reader-json/reader-articles-tpo.import.json');
const questionTemplatePatterns = [
  { issue: 'question_contains_paragraph_marker', regex: /\bParagraph\s+\d+[：:]/i },
  { issue: 'question_contains_directions_block', regex: /^\s*Directions[:：]/i },
  { issue: 'question_contains_answer_choices_block', regex: /^\s*Answer Choices?\s*$/im }
];

const parseArgs = (argv) => {
  const args = {
    roots: [
      path.resolve(cwd, 'data/generated-reader-json'),
      path.resolve(cwd, 'data/generated-reader-json-remote-G4')
    ],
    useDefaultDatasets: true,
    summary: false,
    output: ''
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--root') {
      args.roots = [path.resolve(next())];
      args.useDefaultDatasets = false;
    } else if (arg === '--roots') {
      args.roots = next().split(',').map(item => path.resolve(item));
      args.useDefaultDatasets = false;
    } else if (arg === '--output') args.output = path.resolve(next());
    else if (arg === '--summary') args.summary = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return args;
};

const safeReadJson = (filePath) => {
  try {
    return { value: JSON.parse(fs.readFileSync(filePath, 'utf8')) };
  } catch (error) {
    return { error: error.message };
  }
};

const normalizeText = (value) => `${value ?? ''}`;

const isFallbackSentence = (sentence) =>
  sentence?.generatedBy === 'local-fallback' ||
  /本地兜底|模型失败后的本地兜底/.test(`${sentence?.translation || ''}\n${sentence?.analysis || ''}`);

const issueCounts = (issues) => issues.reduce((counts, issue) => {
  counts[issue.issue] = (counts[issue.issue] || 0) + 1;
  return counts;
}, {});

const summarizeIssues = (issues, limit = 10) => ({
  errorCount: issues.filter(issue => issue.severity === 'error').length,
  warningCount: issues.filter(issue => issue.severity === 'warning').length,
  issueCounts: issueCounts(issues),
  affectedItems: issues.slice(0, limit).map((issue) => ({
    issue: issue.issue,
    file: issue.file,
    sentenceId: issue.sentenceId,
    articleId: issue.articleId,
    questionId: issue.questionId,
    field: issue.field,
    markers: issue.markers
  }))
});

const detectQuestionMarkers = (text) => {
  const value = normalizeText(text);
  return questionTemplatePatterns
    .filter(({ regex }) => regex.test(value))
    .map(({ issue }) => issue);
};

const auditSentence = ({ sentence, file }) => {
  const issues = [];
  for (const field of requiredSentenceFields) {
    if (sentence?.[field] === undefined || sentence?.[field] === null || sentence?.[field] === '') {
      issues.push({ severity: 'error', issue: 'missing_sentence_field', field, file, sentenceId: sentence?.id || '' });
    }
  }

  for (const field of requiredTeachingFields) {
    if (sentence?.teachingFocus?.[field] === undefined || sentence?.teachingFocus?.[field] === null || sentence?.teachingFocus?.[field] === '') {
      issues.push({ severity: 'error', issue: 'missing_teaching_field', field, file, sentenceId: sentence?.id || '' });
    }
  }

  if (!Array.isArray(sentence?.teachingFocus?.thinkingPath) || sentence.teachingFocus.thinkingPath.length < 2) {
    issues.push({ severity: 'error', issue: 'invalid_thinking_path', file, sentenceId: sentence?.id || '' });
  }

  const textMarkers = detectQuestionMarkers(sentence?.text);
  if (textMarkers.length > 0) {
    issues.push({
      severity: 'error',
      issue: 'sentence_text_contains_template_marker',
      markers: textMarkers,
      file,
      sentenceId: sentence?.id || ''
    });
  }

  const analysisMarkers = detectQuestionMarkers(sentence?.analysis);
  if (analysisMarkers.length > 0) {
    issues.push({
      severity: 'error',
      issue: 'sentence_analysis_contains_template_marker',
      markers: analysisMarkers,
      file,
      sentenceId: sentence?.id || ''
    });
  }

  if (!Array.isArray(sentence?.segments) || sentence.segments.length === 0) {
    issues.push({ severity: 'error', issue: 'missing_segments', file, sentenceId: sentence?.id || '' });
  } else {
    const segmentText = sentence.segments.map(segment => segment.text || '').join('');
    if (segmentText !== sentence.text) {
      issues.push({
        severity: 'error',
        issue: 'segments_do_not_reconstruct_text',
        file,
        sentenceId: sentence.id || '',
        text: sentence.text,
        segmentText
      });
    }
  }

  if (isFallbackSentence(sentence)) {
    issues.push({ severity: 'error', issue: 'local_fallback_not_model_deep_analysis', file, sentenceId: sentence?.id || '' });
  }

  if (typeof sentence?.analysis === 'string') {
    for (const heading of ['### 【主干结构】', '### 【主谓一致】', '### 【动词时态与原形】']) {
      if (!sentence.analysis.includes(heading)) {
        issues.push({ severity: 'warning', issue: 'analysis_missing_core_heading', heading, file, sentenceId: sentence.id || '' });
      }
    }
  }

  return issues;
};

const auditQuestion = ({ question, file, articleId, questionGroup }) => {
  const issues = [];
  const questionId = question?.id || '';
  const promptText = normalizeText(question?.prompt);
  const markers = detectQuestionMarkers(promptText);

  if (markers.includes('question_contains_paragraph_marker')) {
    issues.push({
      severity: 'error',
      issue: 'question_contains_paragraph_marker',
      markers: ['question_contains_paragraph_marker'],
      file,
      articleId,
      questionId
    });
  }

  if (questionGroup === 'questions' && question?.type === 'single') {
    if (markers.includes('question_contains_directions_block') || markers.includes('question_contains_answer_choices_block')) {
      issues.push({
        severity: 'error',
        issue: 'single_question_contains_template_block',
        markers,
        file,
        articleId,
        questionId
      });
    }

    if (!Array.isArray(question?.options) || question.options.length !== 4) {
      issues.push({
        severity: 'error',
        issue: 'single_question_option_count_mismatch',
        file,
        articleId,
        questionId,
        optionCount: Array.isArray(question?.options) ? question.options.length : null
      });
    }

    if (question?.answerIndex === undefined || question?.answerIndex === null || question?.answerIndex === '') {
      issues.push({
        severity: 'error',
        issue: 'single_question_missing_answer',
        file,
        articleId,
        questionId
      });
    } else if (!Number.isInteger(question.answerIndex)) {
      issues.push({
        severity: 'error',
        issue: 'single_question_answer_not_integer',
        file,
        articleId,
        questionId,
        answerIndex: question.answerIndex
      });
    } else if (Array.isArray(question?.options) && (question.answerIndex < 0 || question.answerIndex >= question.options.length)) {
      issues.push({
        severity: 'error',
        issue: 'single_question_answer_out_of_range',
        file,
        articleId,
        questionId,
        answerIndex: question.answerIndex,
        optionCount: question.options.length
      });
    }
  }

  return issues;
};

const auditSectionFile = (filePath) => {
  const relative = path.relative(cwd, filePath);
  const parsed = safeReadJson(filePath);
  if (parsed.error) {
    return {
      file: relative,
      title: '',
      sentenceCount: 0,
      fallback: false,
      issues: [{ severity: 'error', issue: 'invalid_json', file: relative, error: parsed.error }]
    };
  }

  const section = parsed.value;
  const data = section?.article?.data;
  const issues = [];
  if (section?.generatedBy === 'local-fallback') {
    issues.push({ severity: 'error', issue: 'section_generated_by_local_fallback', file: relative });
  }
  if (Array.isArray(section?.warnings) && section.warnings.length > 0) {
    issues.push({ severity: 'error', issue: 'section_has_warnings', file: relative, count: section.warnings.length });
  }
  if (!section?.article) {
    issues.push({ severity: 'error', issue: 'missing_article', file: relative });
  }
  if (!Array.isArray(data) || data.length === 0) {
    issues.push({ severity: 'error', issue: 'missing_article_data', file: relative });
  } else {
    data.forEach(sentence => issues.push(...auditSentence({ sentence, file: relative })));
  }

  return {
    file: relative,
    title: section?.sectionTitle || section?.article?.title || '',
    sentenceCount: Array.isArray(data) ? data.length : 0,
    fallback: section?.generatedBy === 'local-fallback' || (Array.isArray(data) && data.some(isFallbackSentence)),
    issues
  };
};

const auditDataset = ({ root, stem }) => {
  const sectionDir = path.join(root, stem, 'sections');
  const issues = [];
  if (!fs.existsSync(sectionDir)) {
    const failure = { severity: 'error', issue: 'missing_section_dir', dir: path.relative(cwd, sectionDir) };
    return {
      root: path.relative(cwd, root),
      stem,
      expectedSections: expectedCounts[stem] || null,
      sectionCount: 0,
      sentenceCount: 0,
      fallbackSections: 0,
      pass: false,
      sections: [],
      issues: [failure],
      ...summarizeIssues([failure])
    };
  }

  const files = fs.readdirSync(sectionDir)
    .filter(name => name.endsWith('.json'))
    .sort((left, right) => left.localeCompare(right))
    .map(name => path.join(sectionDir, name));
  const sections = files.map(auditSectionFile);
  const expected = expectedCounts[stem] || null;
  if (expected !== null && files.length !== expected) {
    issues.push({ severity: 'error', issue: 'section_count_mismatch', expected, actual: files.length });
  }
  sections.forEach(section => issues.push(...section.issues));
  const summary = summarizeIssues(issues);
  return {
    root: path.relative(cwd, root),
    stem,
    expectedSections: expected,
    sectionCount: files.length,
    sentenceCount: sections.reduce((sum, section) => sum + section.sentenceCount, 0),
    fallbackSections: sections.filter(section => section.fallback).length,
    pass: summary.errorCount === 0,
    sections,
    issues,
    ...summary
  };
};

const auditImportPack = (filePath) => {
  const relative = path.relative(cwd, filePath);
  const parsed = safeReadJson(filePath);
  if (parsed.error) {
    return {
      file: relative,
      articleCount: 0,
      questionCount: 0,
      unsupportedQuestionCount: 0,
      autoGradableQuestionCount: 0,
      fallbackArticles: 0,
      issues: [{ severity: 'error', issue: 'invalid_json', file: relative, error: parsed.error }],
      articles: [],
      ...summarizeIssues([{ severity: 'error', issue: 'invalid_json', file: relative }])
    };
  }

  const articles = Array.isArray(parsed.value) ? parsed.value : [];
  const articleResults = [];
  const issues = [];
  let questionCount = 0;
  let unsupportedQuestionCount = 0;
  let autoGradableQuestionCount = 0;
  let fallbackArticles = 0;

  for (const article of articles) {
    const articleId = article?.id || '';
    const articleIssues = [];
    const data = article?.data;

    if (isFallbackSentence({ translation: article?.translation, analysis: article?.analysis, generatedBy: article?.generatedBy })) {
      fallbackArticles += 1;
    }

    if (!Array.isArray(data) || data.length === 0) {
      articleIssues.push({
        severity: 'error',
        issue: 'missing_article_data',
        file: relative,
        articleId
      });
    } else {
      for (const sentence of data) {
        articleIssues.push(...auditSentence({ sentence, file: relative }));
      }
    }

    for (const question of article?.questions || []) {
      questionCount += 1;
      const questionIssues = auditQuestion({
        question,
        file: relative,
        articleId,
        questionGroup: 'questions'
      });
      articleIssues.push(...questionIssues);
      if (
        question?.type === 'single' &&
        Array.isArray(question?.options) &&
        question.options.length === 4 &&
        Number.isInteger(question?.answerIndex) &&
        question.answerIndex >= 0 &&
        question.answerIndex < question.options.length &&
        detectQuestionMarkers(question?.prompt).length === 0 &&
        detectQuestionMarkers(question?.rawAnswer).length === 0
      ) {
        autoGradableQuestionCount += 1;
      }
    }

    for (const question of article?.unsupportedQuestions || []) {
      unsupportedQuestionCount += 1;
      articleIssues.push(...auditQuestion({
        question,
        file: relative,
        articleId,
        questionGroup: 'unsupportedQuestions'
      }));
    }

    const summarized = summarizeIssues(articleIssues, 5);
    articleResults.push({
      articleId,
      title: article?.title || '',
      sentenceCount: Array.isArray(data) ? data.length : 0,
      questionCount: Array.isArray(article?.questions) ? article.questions.length : 0,
      unsupportedQuestionCount: Array.isArray(article?.unsupportedQuestions) ? article.unsupportedQuestions.length : 0,
      autoGradableQuestionCount: Array.isArray(article?.questions)
        ? article.questions.filter((question) =>
          question?.type === 'single' &&
          Array.isArray(question?.options) &&
          question.options.length === 4 &&
          Number.isInteger(question?.answerIndex) &&
          question.answerIndex >= 0 &&
          question.answerIndex < question.options.length &&
          detectQuestionMarkers(question?.prompt).length === 0 &&
          detectQuestionMarkers(question?.rawAnswer).length === 0
        ).length
        : 0,
      fallback: false,
      ...summarized
    });
    issues.push(...articleIssues);
  }

  const summary = summarizeIssues(issues);
  return {
    file: relative,
    articleCount: articles.length,
    questionCount,
    unsupportedQuestionCount,
    autoGradableQuestionCount,
    fallbackArticles,
    pass: summary.errorCount === 0,
    articles: articleResults,
    issues,
    ...summary
  };
};

const discoverDatasets = (root) => {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root)
    .filter(name => fs.existsSync(path.join(root, name, 'sections')))
    .sort((left, right) => left.localeCompare(right, 'zh-Hans-CN'))
    .map(stem => ({ root, stem }));
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  const datasetInputs = args.useDefaultDatasets
    ? [
      { root: path.resolve(cwd, 'data/generated-reader-json'), stem: 'rfd1' },
      { root: path.resolve(cwd, 'data/generated-reader-json'), stem: 'rfd2' },
      { root: path.resolve(cwd, 'data/generated-reader-json'), stem: 'rfd3' },
      { root: path.resolve(cwd, 'data/generated-reader-json-remote-G4'), stem: '四上英语课文_英文' }
    ]
    : args.roots.flatMap(discoverDatasets);

  const datasets = datasetInputs.map(auditDataset);
  const packs = fs.existsSync(tpoPackPath) ? [auditImportPack(tpoPackPath)] : [];

  const summary = {
    generatedAt: new Date().toISOString(),
    datasetCount: datasets.length,
    passCount: datasets.filter(dataset => dataset.pass).length,
    failCount: datasets.filter(dataset => !dataset.pass).length,
    packCount: packs.length,
    packPassCount: packs.filter(pack => pack.pass).length,
    packFailCount: packs.filter(pack => !pack.pass).length,
    datasets,
    packs
  };

  const json = JSON.stringify(summary, null, 2);
  if (args.output) {
    fs.mkdirSync(path.dirname(args.output), { recursive: true });
    fs.writeFileSync(args.output, `${json}\n`);
  }
  if (args.summary) {
    console.log(JSON.stringify({
      generatedAt: summary.generatedAt,
      datasetCount: summary.datasetCount,
      passCount: summary.passCount,
      failCount: summary.failCount,
      packCount: summary.packCount,
      packPassCount: summary.packPassCount,
      packFailCount: summary.packFailCount,
      datasets: summary.datasets.map(dataset => ({
        root: dataset.root,
        stem: dataset.stem,
        expectedSections: dataset.expectedSections,
        sectionCount: dataset.sectionCount,
        sentenceCount: dataset.sentenceCount,
        fallbackSections: dataset.fallbackSections,
        errorCount: dataset.errorCount,
        warningCount: dataset.warningCount,
        pass: dataset.pass
      })),
      packs: summary.packs.map(pack => ({
        file: pack.file,
        articleCount: pack.articleCount,
        questionCount: pack.questionCount,
        unsupportedQuestionCount: pack.unsupportedQuestionCount,
        autoGradableQuestionCount: pack.autoGradableQuestionCount,
        errorCount: pack.errorCount,
        warningCount: pack.warningCount,
        pass: pack.pass,
        issueCounts: pack.issueCounts,
        affectedItems: pack.affectedItems
      }))
    }, null, 2));
  } else {
    console.log(json);
  }
  if (summary.failCount > 0 || summary.packFailCount > 0) process.exitCode = 1;
};

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) main();

export {
  auditDataset,
  auditImportPack,
  auditQuestion,
  auditSectionFile,
  detectQuestionMarkers,
  main
};
