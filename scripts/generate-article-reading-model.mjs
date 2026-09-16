#!/usr/bin/env node
/**
 * Whole-article parser for Article Reading Model V1.
 *
 * It intentionally runs after the sentence pipeline: program code owns the
 * canonical content layer, while the model returns only analysis + pedagogy.
 */
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const args = process.argv.slice(2);
const valueAfter = (flag, fallback = '') => {
  const index = args.indexOf(flag);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const has = (flag) => args.includes(flag);
const libraryPath = path.resolve(root, valueAfter('--library', 'data/generated-reader-json/reader-articles-re-foundations.import.json'));
const outputDir = path.resolve(root, valueAfter('--output', 'data/article-reading-model-v1'));
const articleId = valueAfter('--only');
const provider = valueAfter('--provider', process.env.LLM_PROVIDER || 'openai');
const baseUrl = valueAfter('--base-url', process.env.LLM_BASE_URL || 'http://100.121.25.47:8090/v1').replace(/\/+$/, '');
const apiKey = valueAfter('--api-key', process.env.LLM_API_KEY || '');
let model = valueAfter('--model', process.env.LLM_MODEL || '');
const textType = valueAfter('--text-type', 'auto');
const gradeBand = valueAfter('--grade-band', 'upper_elementary');
const attempts = Math.max(1, Math.min(3, Number(valueAfter('--attempts', '3')) || 3));
const temperature = Math.max(0, Math.min(1, Number(valueAfter('--temperature', '0')) || 0));
const dryRun = has('--dry-run');
const force = has('--force');

if (!articleId) throw new Error('Use --only <article-id>. Whole-library generation must be an explicit batch decision.');
if (!['openai', 'ollama'].includes(provider)) throw new Error('--provider must be openai or ollama');
if (!['auto', 'informational', 'narrative'].includes(textType)) throw new Error('--text-type must be auto, informational, or narrative');

const SYSTEM_PROMPT = `You create a structured Article Reading Model for an English reading app for upper-elementary children.

Return ONE JSON object with exactly two top-level keys: analysis and pedagogy. Do not return article metadata or content. The program owns those fields and their stable sentence IDs.

analysis.paragraphs must contain one entry per supplied paragraph: id, topic {label}, main_idea {text}, key_details [{source_ids, meaning}], function {type}, relation_to_previous (null only for the first paragraph, otherwise {type,target}), and signals [{text,source_id,role}].
analysis.text must contain sections [{id,paragraph_ids,label,function}], structure {type}, central_idea {text}, and inferences [{id,claim,evidence:[{source_id,span}],knowledge_bridge,difficulty}]. Use structure.type "narrative" for a plot-focused narrative; otherwise use a descriptive informational structure such as description, sequence, cause_and_effect, compare_and_contrast, or problem_solution.

pedagogy.activities must use only these types: choose_main_idea, choose_heading, identify_support, paragraph_connection, predict_direction, find_evidence. Each activity requires id, type, scaffold_level (high|medium|low|independent), interaction, prompt, and answer. Choice activities provide options [{id,text,role}], where role is one of main_idea, supporting_detail, minor_detail, too_broad, too_narrow, irrelevant, misinterpretation, with answer.option_ids. Sentence-selection activities provide candidate_source_ids and answer.source_ids.

Use child-friendly Chinese prompts. Keep the article text and all sentence IDs unchanged: refer to evidence only by the supplied IDs. Do not ask for typed summaries. Prefer tap, choose, and select-sentence interactions. For informational texts, create all six activity types when the article permits. Distractors must be meaningful mistakes, not random facts.

Be concise: use at most 3 key details per paragraph, at most 2 text-level inferences, at most 4 options per choice activity, and short one-sentence Chinese prompts. Do not add fields beyond those requested.`;

const canonicalContent = (article) => {
  const groups = new Map();
  for (const sentence of article.data || []) {
    const para = Number(sentence.para);
    if (!Number.isInteger(para) || para < 1 || !sentence.id || !String(sentence.text || '').trim()) throw new Error(`Article ${article.id} has invalid sentence data.`);
    if (!groups.has(para)) groups.set(para, []);
    groups.get(para).push({ id: sentence.id, text: sentence.text });
  }
  return {
    paragraphs: [...groups.entries()].sort(([left], [right]) => left - right).map(([order, sentences]) => ({ id: `p${order}`, order, sentences }))
  };
};

const parseJson = (value) => {
  const source = String(value || '').trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  return JSON.parse(source.slice(source.indexOf('{'), source.lastIndexOf('}') + 1));
};

const resolveModel = async () => {
  if (model) return model;
  const url = provider === 'openai' ? `${baseUrl}/models` : `${baseUrl}/api/tags`;
  const response = await fetch(url, { headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : undefined });
  if (!response.ok) throw new Error(`Cannot list models: HTTP ${response.status}`);
  const payload = await response.json();
  const names = provider === 'openai' ? (payload.data || []).map(item => item.id) : (payload.models || []).map(item => item.name);
  model = names.find(name => /qwen/i.test(name)) || names[0] || '';
  if (!model) throw new Error('No model is available from the configured endpoint.');
  return model;
};

const requestModel = async ({ messages }) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8 * 60 * 1000);
  try {
    const url = provider === 'openai' ? `${baseUrl}/chat/completions` : `${baseUrl}/api/chat`;
    const body = provider === 'openai'
      ? { model, stream: false, temperature, max_tokens: 14000, response_format: { type: 'json_object' }, chat_template_kwargs: { enable_thinking: false }, messages }
      : { model, stream: false, think: false, options: { temperature, num_predict: 14000 }, messages };
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}) },
      body: JSON.stringify(body), signal: controller.signal
    });
    if (!response.ok) throw new Error(`${provider} HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    const payload = await response.json();
    return provider === 'openai' ? (payload.choices?.[0]?.message?.content || '') : (payload.message?.content || payload.response || '');
  } finally {
    clearTimeout(timer);
  }
};

const validateGeneratedLayers = ({ analysis, pedagogy }, content) => {
  const paragraphIds = new Set(content.paragraphs.map(paragraph => paragraph.id));
  const sentenceIds = new Set(content.paragraphs.flatMap(paragraph => paragraph.sentences.map(sentence => sentence.id)));
  const knownParagraphIds = new Set(paragraphIds);
  const allowedActivities = new Set(['choose_main_idea', 'choose_heading', 'identify_support', 'paragraph_connection', 'predict_direction', 'find_evidence']);
  const allowedRoles = new Set(['main_idea', 'supporting_detail', 'minor_detail', 'too_broad', 'too_narrow', 'irrelevant', 'misinterpretation']);
  if (!Array.isArray(analysis?.paragraphs) || analysis.paragraphs.length !== paragraphIds.size) throw new Error('analysis.paragraphs must cover every paragraph exactly once.');
  for (const paragraph of analysis.paragraphs) {
    if (!paragraphIds.delete(paragraph.id) || !paragraph.topic?.label || !paragraph.main_idea?.text || !paragraph.function?.type) throw new Error(`Invalid paragraph analysis: ${paragraph?.id || '(missing)'}`);
    for (const detail of paragraph.key_details || []) for (const id of detail.source_ids || []) if (!sentenceIds.has(id)) throw new Error(`Unknown key-detail sentence: ${id}`);
    for (const signal of paragraph.signals || []) if (!sentenceIds.has(signal.source_id)) throw new Error(`Unknown signal sentence: ${signal.source_id}`);
    if (paragraph.relation_to_previous && (!knownParagraphIds.has(paragraph.relation_to_previous.target) || paragraph.relation_to_previous.target === paragraph.id || !paragraph.relation_to_previous.type)) throw new Error(`Invalid paragraph relation: ${paragraph.id}`);
  }
  if (paragraphIds.size || !analysis?.text?.central_idea?.text || !analysis?.text?.structure?.type || !Array.isArray(analysis?.text?.sections)) throw new Error('Incomplete text analysis.');
  for (const section of analysis.text.sections) for (const id of section.paragraph_ids || []) if (!knownParagraphIds.has(id)) throw new Error(`Unknown section paragraph: ${id}`);
  for (const inference of analysis.text.inferences || []) for (const evidence of inference.evidence || []) if (!sentenceIds.has(evidence.source_id)) throw new Error(`Unknown inference sentence: ${evidence.source_id}`);
  if (!Array.isArray(pedagogy?.activities) || !pedagogy.activities.length) throw new Error('pedagogy.activities is required.');
  const activityIds = new Set();
  for (const activity of pedagogy.activities) {
    if (!activity?.id || activityIds.has(activity.id) || !allowedActivities.has(activity.type) || !activity.prompt || !activity.answer || !['high', 'medium', 'low', 'independent'].includes(activity.scaffold_level)) throw new Error(`Invalid activity: ${activity?.id || '(missing)'}`);
    activityIds.add(activity.id);
    for (const id of activity.candidate_source_ids || []) if (!sentenceIds.has(id)) throw new Error(`Unknown activity sentence: ${id}`);
    const optionIds = new Set();
    for (const option of activity.options || []) {
      if (!option?.id || optionIds.has(option.id) || !option.text || !allowedRoles.has(option.role)) throw new Error(`Invalid option in activity: ${activity.id}`);
      optionIds.add(option.id);
    }
    for (const id of activity.answer.option_ids || []) if (!optionIds.has(id)) throw new Error(`Unknown activity answer option: ${id}`);
    for (const id of activity.answer.source_ids || []) if (!sentenceIds.has(id)) throw new Error(`Unknown activity answer sentence: ${id}`);
    if (!activity.answer.option_ids?.length && !activity.answer.source_ids?.length) throw new Error(`Activity has no answer: ${activity.id}`);
  }
};

const articles = JSON.parse(fs.readFileSync(libraryPath, 'utf8'));
const article = articles.find(item => item.id === articleId);
if (!article) throw new Error(`Article not found: ${articleId}`);
const content = canonicalContent(article);
const outputPath = path.join(outputDir, `${articleId}.json`);
const request = { article: { id: article.id, title: article.title, text_type: textType, audience: { grade_band: gradeBand } }, content };

if (dryRun) {
  console.log(JSON.stringify({ dryRun: true, outputPath, article: request.article, paragraphCount: content.paragraphs.length, sentenceCount: article.data.length }, null, 2));
  process.exit(0);
}
if (fs.existsSync(outputPath) && !force) throw new Error(`Output exists: ${outputPath}. Pass --force to replace it.`);

await resolveModel();
let generated;
let lastError;
for (let attempt = 1; attempt <= attempts; attempt += 1) {
  try {
    const messages = [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: JSON.stringify(request) }];
    if (attempt > 1) messages.push({ role: 'user', content: 'Your previous response was rejected locally. Return complete, strict JSON only; use only the supplied sentence IDs and include no trailing commentary.' });
    generated = parseJson(await requestModel({ messages }));
    validateGeneratedLayers(generated, content);
    break;
  } catch (error) {
    lastError = error;
    if (attempt < attempts) console.warn(`Attempt ${attempt}/${attempts} rejected for ${article.id}; retrying with strict JSON reminder.`);
  }
}
if (!generated) throw lastError;
const resolvedTextType = textType === 'auto'
  ? (generated.analysis?.text?.structure?.type === 'narrative' ? 'narrative' : 'informational')
  : textType;
const result = { schema_version: '1.0', article: { ...request.article, text_type: resolvedTextType, language: 'en' }, content, analysis: generated.analysis, pedagogy: generated.pedagogy };
fs.mkdirSync(outputDir, { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`);
console.log(`Generated Article Reading Model: ${outputPath}`);
