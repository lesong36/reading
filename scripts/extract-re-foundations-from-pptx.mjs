#!/usr/bin/env node
/**
 * Extract Reading Explorer Foundations readings from the supplied course PPTX
 * files. PPTX text is read from its native slide XML rather than from OCR.
 *
 * The quiz slides provide answer choices, but the course files do not expose a
 * reliable answer key in their text layer, so all imported questions are kept
 * as `unsupported` until an official key is supplied.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const DEFAULT_INPUT = '/Users/coty/Downloads/国家地理RE3版/第三版课件ppt/精品课件F-3级/RE F级别PPT精品课件';
const DEFAULT_OUTPUT = path.join(cwd, 'data/re-foundations-source');

const parseArgs = (argv) => {
  const args = { input: DEFAULT_INPUT, out: DEFAULT_OUTPUT, only: '', dryRun: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--input') args.input = path.resolve(next());
    else if (arg === '--out') args.out = path.resolve(next());
    else if (arg === '--only') args.only = next().toLowerCase();
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--help') {
      console.log('Usage: node scripts/extract-re-foundations-from-pptx.mjs [--input pptx-dir] [--out data-dir] [--only 1A] [--dry-run]');
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
};

const walkPptx = (directory) => fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
  const file = path.join(directory, entry.name);
  if (entry.isDirectory()) return walkPptx(file);
  return /\.pptx$/i.test(entry.name) && !entry.name.startsWith('~$') ? [file] : [];
});

const naturalCompare = (left, right) => left.localeCompare(right, 'zh-Hans-CN', { numeric: true, sensitivity: 'base' });

const decodeXml = (value = '') => value
  .replace(/&amp;/g, '&')
  .replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'");

const normalizeText = (value = '') => decodeXml(value)
  .replace(/\s+/g, ' ')
  .replace(/\s+([,.;:!?])/g, '$1')
  .replace(/([“‘(])\s+/g, '$1')
  .replace(/\s+([”’)])/g, '$1')
  .trim();

const isNoise = (line) => !line || /^(?:style\.visibility|ppt_[xy]|◄|►)$/i.test(line);
const isUpperTitleLine = (line) => /^[A-Z][A-Z0-9 '&,:;!?-]*$/.test(line) && /[A-Z]/.test(line);
const isParagraphLabel = (line) => /^[A-H]$/.test(line);
const hasSlideHeading = (slide, heading) => slide.lines
  .some((line) => line.toUpperCase().replace(/\s+/g, ' ').trim() === heading);
const ARTICLE_COLUMN_RIGHT = 7_000_000;
const paragraphStart = (line) => {
  if (isParagraphLabel(line)) return { label: line, text: '' };
  const match = line.match(/^([A-H])(?:[.)]\s*|\s+)(?=[A-Z“‘"'])\s*(.+)$/);
  return match ? { label: match[1], text: match[2] } : null;
};

const pptxSlides = (file) => {
  const entries = execFileSync('unzip', ['-Z1', file], { encoding: 'utf8' })
    .split('\n')
    .filter((name) => /^ppt\/slides\/slide\d+\.xml$/.test(name))
    .sort((left, right) => Number(left.match(/slide(\d+)/)[1]) - Number(right.match(/slide(\d+)/)[1]));

  return entries.map((entry, number) => {
    const xml = execFileSync('unzip', ['-p', file, entry], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    const shapes = [...xml.matchAll(/<p:sp>[\s\S]*?<\/p:sp>/g)].map((match) => {
      const shapeXml = match[0];
      const off = shapeXml.match(/<a:off x="(\d+)" y="(\d+)"/);
      const text = normalizeText([...shapeXml.matchAll(/<a:t>([\s\S]*?)<\/a:t>/g)].map((textMatch) => textMatch[1]).join(' '));
      return { x: Number(off?.[1] || 0), y: Number(off?.[2] || 0), hasPosition: Boolean(off), text };
    }).filter((shape) => !isNoise(shape.text));
    const lines = shapes.map((shape) => shape.text);
    return { number: number + 1, shapes, lines, text: lines.join('\n') };
  });
};

// On article slides the original passage is placed in the left column. The
// right column is teacher material (vocabulary, fill-in drills, and notes),
// which must never become part of a learner's article or LLM input.
const cleanArticleText = (text) => normalizeText(text
  // PPT authors often append a Chinese teaching callout or a fill-in drill to
  // the same left-column text box as the final article sentence.
  .split(/[\p{Script=Han}]|\bK\s*-\s*W\s*-\s*L\s+Chart\b|\bTopic\s*:|\s*\^\s*/u)[0]
  // Superscript footnote markers are separate PPT runs which flatten into a
  // literal digit. The definition is rendered separately below the reading.
  .replace(/(?<=[\p{L}”’])\s+[1-9](?=\s+(?:and|of|for|in|to|,|\.|;|—))/gu, '')
  .replace(/\s+\d+\s+(?:A|An|The|If)\s+[^.]+\.(?:\s+\d+\s+(?:A|An|The|If)\s+[^.]+\.)*/g, '')
  .replace(/_{3,}/g, ''));

const articleLines = (slide) => slide.shapes
  .filter((shape) => shape.x < ARTICLE_COLUMN_RIGHT)
  .filter((shape) => !(/^[A-Z][A-Z\s]{1,}$/.test(shape.text) && shape.text.length < 80 && !isParagraphLabel(shape.text)))
  .filter((shape) => !/^\d+\s+(?:A\s+)?[A-Z][a-z]+\s+(?:are|is|has|means)\b/.test(shape.text))
  .filter((shape) => !(shape.y > 4_500_000 && shape.text.length < 320))
  .sort((left, right) => left.y - right.y || left.x - right.x)
  .map((shape) => cleanArticleText(shape.text))
  .filter(Boolean);

const extractTitle = (lines) => {
  const marker = lines.findIndex((line) => line.toUpperCase() === 'WHILE READING');
  const end = marker < 0 ? lines.length : marker;
  const tail = [];
  for (let index = end - 1; index >= 0; index -= 1) {
    if (!isUpperTitleLine(lines[index]) && !isParagraphLabel(lines[index])) break;
    tail.unshift(lines[index]);
  }
  const tailTitle = tail.filter((line) => !isParagraphLabel(line)).join(' ').trim();
  if (tailTitle) return tailTitle;

  // Some decks place a grammar callout between the visual title and the
  // “WHILE READING” tag. In those files, find the longest all-caps title run.
  const candidates = [];
  let current = [];
  for (const line of lines.slice(0, end)) {
    if (isUpperTitleLine(line) && !/^(?:WHILE|READING|VOCABULARY|LEARNING)$/i.test(line)) {
      current.push(line);
    } else {
      if (current.length >= 2) candidates.push(current.join(' '));
      current = [];
    }
  }
  if (current.length >= 2) candidates.push(current.join(' '));
  return candidates.sort((left, right) => right.length - left.length)[0] || '';
};

const stripSlideChrome = (lines) => {
  const marker = lines.findIndex((line) => line.toUpperCase() === 'WHILE READING');
  // Several decks omit the visual “WHILE READING” label from their native
  // text layer. In that case the slide itself is already the article body;
  // treating its whole content as chrome would silently drop every paragraph.
  if (marker < 0) return lines;
  let titleStart = marker;
  while (titleStart > 0 && (isUpperTitleLine(lines[titleStart - 1]) || isParagraphLabel(lines[titleStart - 1]))) titleStart -= 1;
  const content = lines.slice(0, titleStart);
  const callout = content.indexOf('^');
  const footnote = content.findIndex((line, index) =>
    index > 0 && /^\d+$/.test(line) && /^(?:If |[A-Z][a-z]+\s)/.test(content[index + 1] || '')
  );
  const end = [callout, footnote]
    .filter((index) => index >= 0)
    .reduce((minimum, index) => Math.min(minimum, index), content.length);
  return content.slice(0, end);
};

const isReadingBodySlide = (slide) => {
  if (['READING COMPREHENSION', 'READING SKILL', 'VOCABULARY PRACTICE', 'VOCABULARY LEARNING', 'BEFORE YOU READ'].some((heading) => hasSlideHeading(slide, heading))) return false;
  const lines = articleLines(slide);
  return lines.some((line, index) =>
    paragraphStart(line) && `${paragraphStart(line).text} ${lines.slice(index + 1, index + 6).join(' ')}`.length >= 40
  );
};

const isReadingContinuationSlide = (slide) =>
  hasSlideHeading(slide, 'WHILE READING')
  && !['READING COMPREHENSION', 'READING SKILL', 'VOCABULARY PRACTICE', 'VOCABULARY LEARNING', 'BEFORE YOU READ'].some((heading) => hasSlideHeading(slide, heading))
  && !slide.lines.some((line) => /(?:What We Know|Time of first discovery)/i.test(line))
  && slide.lines.join(' ').length >= 120;

const collectFootnotes = (slides) => {
  const footnotes = [];
  for (const slide of slides) {
    for (let index = 0; index < slide.lines.length - 1; index += 1) {
      const marker = slide.lines[index];
      const text = slide.lines[index + 1];
      const inline = [...marker.matchAll(/(?:^|\s)([1-9])\s+((?:If |An |The |Evidence ).+?)(?=\s+[1-9]\s+(?:If |An |The |Evidence )|$)/g)];
      if (inline.length) {
        footnotes.push(...inline.map((match) => ({ marker: match[1], text: normalizeText(match[2]) })));
        continue;
      }
      if (/^\d+$/.test(marker) && /^(?:If |An |The |Evidence )/.test(text || '')) {
        const parts = [];
        for (let next = index + 1; next < slide.lines.length; next += 1) {
          if (isParagraphLabel(slide.lines[next]) && isUpperTitleLine(slide.lines[next + 1] || '')) break;
          parts.push(slide.lines[next]);
        }
        footnotes.push({ marker, text: normalizeText(parts.join(' ')) });
      }
    }
  }
  return footnotes.filter((footnote, index, all) => all.findIndex((item) => item.marker === footnote.marker) === index);
};

const collectCompanions = (slides) => slides
  .filter((slide) => slide.lines.some((line) => /(?:What We Know|Time of first discovery)/i.test(line)))
  .map((slide) => ({
    kind: 'infographic',
    title: slide.lines.find((line) => /What We Know/i.test(line)) || '伴读信息图',
    text: normalizeText(slide.lines.filter((line) => !/^(?:WHILE READING|\^|[①②③➊➋➌])$/i.test(line)).join(' ')),
    sourceSlide: slide.number
  }));

const answerKeys = {
  '1A': {
    answers: [2, 0, 2, 1, 2],
    paragraphHints: [null, '2', '3', '3', null]
  }
};

// Titles are reconstructed from the PPT slide layout (not XML order). Some
// slides split a title across multiple text boxes, which otherwise produces
// incorrect sequences such as “THE OF WORLD SPEED EATING”.
const titleOverrides = {
  '1A': 'A Mysterious Visitor',
  '1B': 'The Lost City of Atlantis',
  '2A': 'The World of Speed Eating',
  '2B': 'The Hottest Chilies',
  '3A': 'Digging for the Past',
  '3B': 'An Interview with Joel Sartore',
  '4A': 'I’ve Found the Titanic!',
  '4B': 'My Descent into the Titanic',
  '5A': 'The Disease Detective',
  '5B': 'At the Crime Scene',
  '6A': 'Planting for the Planet',
  '6B': 'Fatal Attraction',
  '7A': 'Understanding Dreams',
  '7B': 'Seeing the Impossible',
  '8A': 'A Penguin’s Year',
  '9A': 'A Love Poem in Stone',
  '9B': 'The Great Dome of Florence',
  '10A': 'Wild Weather',
  '10B': 'When Weird Weather Strikes',
  '11A': 'The Mammoth’s Tale',
  '11B': 'Giants of the Past',
  '12A': 'The Robots Are Coming!',
  '12B': 'How Will We Live in 2045?'
};

// The courseware was authored by multiple teams. Navigation slides reuse A/B
// labels, so the verified article range is more reliable than guessing from
// text-box order. Ranges are inclusive PPT slide numbers.
const readingSlideRanges = {
  '1A': [13, 15], '1B': [13, 17], '2A': [14, 17], '2B': [15, 20],
  '3A': [13, 15], '3B': [13, 17], '4A': [16, 18], '4B': [11, 13],
  '5A': [13, 15], '5B': [12, 17], '6A': [14, 16], '6B': [11, 16],
  '7A': [14, 16], '7B': [12, 15], '8A': [30, 34], '8B': [21, 23],
  '9A': [13, 16], '9B': [14, 15], '10A': [14, 17], '10B': [15, 16],
  '11A': [14, 15], '11B': [8, 13], '12A': [14, 16], '12B': [12, 14]
};

const paragraphsFromSlides = (slides) => {
  const paragraphs = [];
  let current = null;
  for (const slide of slides) {
    for (const line of stripSlideChrome(articleLines(slide))) {
      const chunks = line.split(/\b(?=[A-H]\s+(?=[A-Z“‘"']))/g).filter(Boolean);
      for (const chunk of chunks) {
        const start = paragraphStart(chunk.trim());
        if (start) {
          if (current?.parts.length) paragraphs.push(current);
          current = { label: start.label, parts: start.text ? [start.text] : [] };
        } else if (current && !/^\d+$/.test(chunk.trim())) {
          current.parts.push(chunk.trim());
        }
      }
    }
  }
  if (current?.parts.length) paragraphs.push(current);
  return paragraphs
    .map((paragraph) => ({ ...paragraph, text: normalizeText(paragraph.parts.join(' ')) }))
    .filter((paragraph) => paragraph.text.length >= 40);
};

const stripInlineQuestions = (courseLabel, text) => {
  if (courseLabel !== '3B') return text;
  const cleaned = normalizeText(text
    .replace(/\b(?:How did you become a National Geographic photographer|What kind of photographers is National Geographic looking for|Is it difficult to get a job as a photographer today|I want to be a photographer\. Do you have any advice for me)\?\s*/gi, '')
    .replace(/\bQuestion\s+\d+\s*:\s*.*/gi, ''));
  return cleaned.replace(/(If so, you’ll enjoy the work much more\.)[\s\S]*/i, '$1');
};

const stripRepeatedTeachingTail = (paragraphs) => {
  const seen = new Set();
  return paragraphs.map((paragraph) => {
    let text = paragraph.text.replace(/([.!?”])\s+[1-9]\s*$/, '$1');
    const sentences = text.match(/[^.!?]+[.!?]+(?:[”’"])?/g) || [text];
    let retained = '';
    for (const sentence of sentences) {
      const normalized = normalizeText(sentence).toLowerCase();
      // Repeated full sentences after an article's ending are PPT teaching
      // examples, not a second part of the reading.
      if (normalized.length >= 20 && seen.has(normalized)) break;
      retained += sentence;
      if (normalized.length >= 20) seen.add(normalized);
    }
    return { ...paragraph, text: normalizeText(retained) };
  }).filter((paragraph) => paragraph.text.length >= 40);
};

const stripTeachingRecap = (paragraphs, title) => paragraphs.map((paragraph) => {
  const mainIdeaIndex = paragraph.text.search(/\bMain Idea\b/i);
  const beforeRecap = mainIdeaIndex < 0 ? '' : paragraph.text.slice(0, mainIdeaIndex).toLowerCase();
  const titleVariants = [title, title.replace(/^the\s+/i, '')].map((value) => value.toLowerCase());
  const titleIndex = mainIdeaIndex < 0 ? -1 : Math.max(...titleVariants.map((value) => beforeRecap.lastIndexOf(value)));
  // The recap begins by repeating the reading title, followed by keywords and
  // a "Main Idea" prompt. It is teacher material even when embedded in the
  // same shape as the article's final paragraph.
  return titleIndex > 0 ? { ...paragraph, text: paragraph.text.slice(0, titleIndex).trim() } : paragraph;
}).filter((paragraph) => paragraph.text.length >= 40);

const findReadingSlides = (slides) => {
  // The decks always introduce the reading after the last vocabulary page.
  // This avoids an earlier matching exercise (which also has A/B/C labels)
  // being mistaken for article paragraph A.
  const lastVocabulary = slides.reduce((latest, slide, index) =>
    hasSlideHeading(slide, 'VOCABULARY LEARNING') ? index : latest, -1);
  const start = slides.slice(lastVocabulary + 1).findIndex(isReadingBodySlide);
  const firstReading = start < 0 ? -1 : lastVocabulary + 1 + start;
  const firstComprehension = firstReading < 0 ? -1 : slides.findIndex((slide, index) =>
    index > firstReading && hasSlideHeading(slide, 'READING COMPREHENSION'));
  const readingSlides = firstReading < 0 ? [] : slides
    .slice(firstReading, firstComprehension === -1 ? slides.length : firstComprehension)
    .filter((slide) => isReadingBodySlide(slide) || isReadingContinuationSlide(slide));
  return { readingSlides, firstComprehension };
};

const questionFromSlide = (slide, index, answerKey = null) => {
  const lines = slide.lines.filter((line) => !/^(?:READING COMPREHENSION|[A-Z]\. Choose the best answer.*)$/i.test(line));
  const firstOption = lines.findIndex((line) => /^[a-d]\s*[.)]\s+/i.test(line));
  if (firstOption < 1) return null;
  const optionLines = lines.slice(firstOption).filter((line) => /^[a-d]\s*[.)]\s+/i.test(line));
  if (optionLines.length < 2) return null;
  const prompt = normalizeText(lines.slice(0, firstOption).join(' '))
    .replace(/^\d+\s*[.)]\s*/, '')
    .replace(/\s+(?:gist|detail|vocabulary|inference|reference)\s*$/i, '')
    .trim();
  if (prompt.length < 8 || !/[a-z]/i.test(prompt)) return null;
  return {
    id: `q${index}`,
    index,
    prompt,
    options: optionLines.slice(0, 4).map((line) => line.replace(/^[a-d]\s*[.)]\s*/i, '').trim()),
    answerIndex: Number.isInteger(answerKey?.answers?.[index - 1]) ? answerKey.answers[index - 1] : null,
    paragraphHint: answerKey?.paragraphHints?.[index - 1] || null,
    type: Number.isInteger(answerKey?.answers?.[index - 1]) ? 'single' : 'unsupported',
    reason: Number.isInteger(answerKey?.answers?.[index - 1]) ? '' : 'PPTX answer key not available in native slide text'
  };
};

const sourceLabel = (file) => {
  const name = path.basename(file, '.pptx');
  const match = name.match(/(?:RE\s*F级\s*)?(\d{1,2}[AB])/i);
  return match ? match[1].toUpperCase() : name;
};

const slugify = (value) => String(value)
  .normalize('NFKD')
  .replace(/[^\w]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .toLowerCase();

const extractArticle = (file) => {
  const slides = pptxSlides(file);
  const courseLabel = sourceLabel(file);
  const verifiedRange = readingSlideRanges[courseLabel];
  const { readingSlides: detectedSlides, firstComprehension } = findReadingSlides(slides);
  const readingSlides = verifiedRange
    ? slides.slice(verifiedRange[0] - 1, verifiedRange[1])
    : detectedSlides;
  if (!readingSlides.length) return { ok: false, reason: 'while_reading_marker_not_found' };
  const title = titleOverrides[courseLabel] || extractTitle(readingSlides[0].lines);
  const paragraphs = stripTeachingRecap(stripRepeatedTeachingTail(paragraphsFromSlides(readingSlides)
    .map((paragraph) => ({ ...paragraph, text: stripInlineQuestions(courseLabel, paragraph.text) }))
    .filter((paragraph) => paragraph.text.length >= 40)), title);
  if (!title || paragraphs.length < 2) {
    return { ok: false, reason: 'title_or_paragraphs_not_found', title, paragraphCount: paragraphs.length };
  }
  // In several decks the navigation headings use inconsistent spacing, which
  // makes an index-range based scan skip all question slides. The explicit
  // instruction below appears only on Reading Comprehension question slides.
  const questionSlides = slides
    .filter((slide) => slide.lines.some((line) => /\bA\.\s*Choose the best answer/i.test(line)));
  const questions = questionSlides.map((slide, index) => questionFromSlide(slide, index + 1, answerKeys[courseLabel])).filter(Boolean);
  const section = `RE Foundations / ${courseLabel}`;
  const id = `re-foundations-${slugify(courseLabel)}-${slugify(title)}`;
  const companions = collectCompanions(slides.slice(readingSlides[0].number - 1, firstComprehension === -1 ? slides.length : firstComprehension))
    .map((companion) => ({
      ...companion,
      imageSrc: courseLabel === '1A' && companion.sourceSlide === 16
        ? './data/generated-reader-json/re-foundations-assets/re-foundations-1a-oumuamua-companion-16.png'
        : courseLabel === '1A' && companion.sourceSlide === 17
          ? './data/generated-reader-json/re-foundations-assets/re-foundations-1a-oumuamua-companion-17.png'
          : ''
    }));
  return {
    ok: true,
    id,
    section,
    title,
    body: paragraphs.map(({ text }) => text).join('\n\n'),
    paragraphs: paragraphs.map(({ label }) => ({ label })),
    footnotes: collectFootnotes(readingSlides),
    companions,
    questions,
    source: { pptx: file, slideRange: `${readingSlides[0].number}-${readingSlides.at(-1).number}` },
    stats: { slideCount: slides.length, paragraphCount: paragraphs.length, questionCount: questions.length, chars: paragraphs.map((item) => item.text).join(' ').length }
  };
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  const files = walkPptx(args.input).sort(naturalCompare).filter((file) => !args.only || sourceLabel(file).toLowerCase() === args.only);
  if (!files.length) throw new Error(`No PPTX files found in ${args.input}`);
  const passagesDir = path.join(args.out, 'passages');
  const questionsDir = path.join(args.out, 'questions');
  if (!args.dryRun) {
    fs.mkdirSync(passagesDir, { recursive: true });
    fs.mkdirSync(questionsDir, { recursive: true });
  }
  const articles = [];
  const errors = [];
  for (const file of files) {
    const article = extractArticle(file);
    if (!article.ok) {
      errors.push({ file, ...article });
      console.warn(`MISS ${path.basename(file)}: ${article.reason}`);
      continue;
    }
    articles.push({
      id: article.id,
      section: article.section,
      title: article.title,
      mdPath: `passages/${article.id}.md`,
      questionsPath: `questions/${article.id}.json`,
      source: article.source,
      ...article.stats,
      paragraphs: article.paragraphs,
      footnotes: article.footnotes,
      companions: article.companions
    });
    if (!args.dryRun) {
      fs.writeFileSync(path.join(passagesDir, `${article.id}.md`), `# ${article.section} / ${article.title}\n\n${article.body}\n`, 'utf8');
      fs.writeFileSync(path.join(questionsDir, `${article.id}.json`), `${JSON.stringify({ id: article.id, section: article.section, title: article.title, questions: article.questions.filter((question) => question.type === 'single'), unsupported: article.questions.filter((question) => question.type !== 'single') }, null, 2)}\n`, 'utf8');
    }
    console.log(`OK ${sourceLabel(file)} ${article.id} paragraphs=${article.stats.paragraphCount} questions=${article.stats.questionCount}`);
  }
  const manifest = { generatedAt: new Date().toISOString(), sourceDir: args.input, expectedFiles: files.length, extractedCount: articles.length, errorCount: errors.length, articles, errors };
  if (!args.dryRun) fs.writeFileSync(path.join(args.out, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  console.log(`Done. extracted=${articles.length} errors=${errors.length}`);
  if (errors.length) process.exitCode = 2;
};

main();
