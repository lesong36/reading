#!/usr/bin/env node
/** Validate Article Reading Model V1 files before a merge attaches them to a library article. */
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const args = process.argv.slice(2);
const libraryPaths = args.reduce((all, arg, index) => arg === '--library' && args[index + 1] ? [...all, args[index + 1]] : all, []);
const libraryValueIndexes = new Set(args.flatMap((arg, index) => arg === '--library' ? [index + 1] : []));
const input = args.find((arg, index) => !arg.startsWith('--') && !libraryValueIndexes.has(index)) || 'data/article-reading-model-v1';
const allowedActivities = new Set(['choose_main_idea', 'choose_heading', 'identify_support', 'paragraph_connection', 'predict_direction', 'find_evidence']);
const allowedRoles = new Set(['main_idea', 'supporting_detail', 'minor_detail', 'too_broad', 'too_narrow', 'irrelevant', 'misinterpretation']);
const files = fs.statSync(path.resolve(root, input)).isDirectory()
  ? fs.readdirSync(path.resolve(root, input)).filter(file => file.endsWith('.json') && !file.startsWith('.')).map(file => path.join(input, file))
  : [input];
const libraryById = libraryPaths.length
  ? new Map(libraryPaths.flatMap(libraryPath => JSON.parse(fs.readFileSync(path.resolve(root, libraryPath), 'utf8')).map(article => [article.id, article])))
  : null;
let failures = 0;
const error = (file, message) => { failures += 1; console.error(`ERROR ${file}: ${message}`); };

for (const file of files) {
  let model;
  try { model = JSON.parse(fs.readFileSync(path.resolve(root, file), 'utf8')); }
  catch (cause) { error(file, `invalid JSON (${cause.message})`); continue; }
  if (model.schema_version !== '1.0') error(file, 'schema_version must be "1.0"');
  if (!model.article?.id || !model.article?.title || model.article?.language !== 'en') error(file, 'article requires id, title, and language "en"');
  if (!['informational', 'narrative'].includes(model.article?.text_type)) error(file, 'article.text_type must be informational or narrative');
  const paragraphs = model.content?.paragraphs;
  if (!Array.isArray(paragraphs) || !paragraphs.length) { error(file, 'content.paragraphs is required'); continue; }
  const paragraphIds = new Set(); const sentenceIds = new Set();
  paragraphs.forEach((paragraph, index) => {
    if (!paragraph?.id || paragraphIds.has(paragraph.id)) error(file, `duplicate or missing paragraph id at index ${index}`);
    paragraphIds.add(paragraph?.id);
    if (paragraph.order !== index + 1) error(file, `paragraph ${paragraph.id} must have order ${index + 1}`);
    if (!Array.isArray(paragraph.sentences) || !paragraph.sentences.length) error(file, `paragraph ${paragraph.id} has no sentences`);
    paragraph.sentences?.forEach(sentence => {
      if (!sentence?.id || sentenceIds.has(sentence.id) || !String(sentence.text || '').trim()) error(file, `invalid or duplicate sentence ${sentence?.id || '(missing)'}`);
      sentenceIds.add(sentence?.id);
    });
  });
  if (libraryById) {
    const source = libraryById.get(model.article.id);
    if (!source) error(file, `article ${model.article.id} is absent from supplied libraries`);
    else {
      const expected = new Map((source.data || []).map(sentence => [sentence.id, sentence]));
      const contentSentences = paragraphs.flatMap(paragraph => paragraph.sentences.map(sentence => ({ ...sentence, para: paragraph.order })));
      if (expected.size !== contentSentences.length) error(file, `content has ${contentSentences.length} sentences but library article has ${expected.size}`);
      contentSentences.forEach(sentence => {
        const original = expected.get(sentence.id);
        if (!original || original.text !== sentence.text || Number(original.para) !== sentence.para) error(file, `content sentence ${sentence.id} differs from canonical article.data`);
      });
    }
  }
  const analyses = model.analysis?.paragraphs;
  if (!Array.isArray(analyses) || analyses.length !== paragraphs.length) error(file, 'analysis.paragraphs must match content.paragraphs');
  analyses?.forEach(paragraph => {
    if (!paragraphIds.has(paragraph?.id) || !paragraph?.topic?.label || !paragraph?.main_idea?.text || !paragraph?.function?.type) error(file, `incomplete paragraph analysis ${paragraph?.id || '(missing)'}`);
    paragraph.key_details?.forEach(detail => detail.source_ids?.forEach(id => { if (!sentenceIds.has(id)) error(file, `key detail references unknown sentence ${id}`); }));
    const relation = paragraph.relation_to_previous;
    if (relation && (!paragraphIds.has(relation.target) || relation.target === paragraph.id || !relation.type)) error(file, `invalid relation for ${paragraph.id}`);
    paragraph.signals?.forEach(signal => { if (!sentenceIds.has(signal.source_id)) error(file, `signal references unknown sentence ${signal.source_id}`); });
  });
  const text = model.analysis?.text;
  if (!text?.central_idea?.text || !text?.structure?.type || !Array.isArray(text.sections)) error(file, 'analysis.text requires central_idea, structure, and sections');
  text?.sections?.forEach(section => section.paragraph_ids?.forEach(id => { if (!paragraphIds.has(id)) error(file, `section references unknown paragraph ${id}`); }));
  text?.inferences?.forEach(inference => inference.evidence?.forEach(evidence => { if (!sentenceIds.has(evidence.source_id)) error(file, `inference references unknown sentence ${evidence.source_id}`); }));
  const activities = model.pedagogy?.activities;
  if (!Array.isArray(activities) || !activities.length) error(file, 'pedagogy.activities is required');
  const activityIds = new Set();
  activities?.forEach(activity => {
    if (!activity?.id || activityIds.has(activity.id) || !allowedActivities.has(activity.type) || !activity.prompt || !['high', 'medium', 'low', 'independent'].includes(activity.scaffold_level)) error(file, `invalid activity ${activity?.id || '(missing)'}`);
    activityIds.add(activity?.id);
    activity.candidate_source_ids?.forEach(id => { if (!sentenceIds.has(id)) error(file, `activity ${activity.id} has unknown candidate sentence ${id}`); });
    const optionIds = new Set();
    activity.options?.forEach(option => {
      if (!option?.id || optionIds.has(option.id) || !option.text || !allowedRoles.has(option.role)) error(file, `invalid option in ${activity.id}`);
      optionIds.add(option?.id);
    });
    activity.answer?.option_ids?.forEach(id => { if (!optionIds.has(id)) error(file, `activity ${activity.id} answers unknown option ${id}`); });
    activity.answer?.source_ids?.forEach(id => { if (!sentenceIds.has(id)) error(file, `activity ${activity.id} answers unknown sentence ${id}`); });
    if (!activity.answer?.option_ids?.length && !activity.answer?.source_ids?.length) error(file, `activity ${activity.id} has no answer`);
  });
  if (!failures) console.log(`OK ${file} (${model.article.id})`);
}
if (failures) process.exitCode = 1;
