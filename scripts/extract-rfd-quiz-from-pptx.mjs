#!/usr/bin/env node
/**
 * Extract auto-gradable Reading Future Discover questions from classroom PPTX
 * decks. The courseware stores many question panels and their red answer
 * circles as images, so this intentionally renders slides before OCR rather
 * than trusting the native text layer alone.
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const DEFAULT_INPUT = path.join(cwd, 'docs/Reading Future Discover Classroom (PPT) 1-3');
const DEFAULT_SOURCE = path.join(cwd, 'data/rfd-quiz-source');
const DEFAULT_IMPORT = path.join(cwd, 'data/generated-reader-json/reader-articles.import.json');

const parseArgs = (argv) => {
  const args = { input: DEFAULT_INPUT, out: DEFAULT_SOURCE, importPath: DEFAULT_IMPORT, only: '', dryRun: false, noInstall: false, reports: '' };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--input') args.input = path.resolve(next());
    else if (arg === '--out') args.out = path.resolve(next());
    else if (arg === '--import') args.importPath = path.resolve(next());
    else if (arg === '--only') args.only = next();
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--no-install') args.noInstall = true;
    else if (arg === '--reports') args.reports = next();
    else if (arg === '--help') {
      console.log('Usage: node scripts/extract-rfd-quiz-from-pptx.mjs [--input pptx-dir] [--out data-dir] [--import import.json] [--only 1-1] [--no-install] [--reports report1,report2,report3] [--dry-run]');
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
};

const walk = (directory) => fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
  const target = path.join(directory, entry.name);
  if (entry.isDirectory()) return walk(target);
  return /\.pptx$/i.test(entry.name) && !entry.name.startsWith('~$') ? [target] : [];
});

const decodeXml = (value = '') => value
  .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'");

const normalize = (value = '') => decodeXml(value)
  .replace(/\s+/g, ' ')
  .replace(/\s+([,.;:!?])/g, '$1')
  .trim();

const slideEntries = (file) => execFileSync('unzip', ['-Z1', file], { encoding: 'utf8' })
  .split('\n')
  .filter((name) => /^ppt\/slides\/slide\d+\.xml$/.test(name))
  .sort((left, right) => Number(left.match(/slide(\d+)/)[1]) - Number(right.match(/slide(\d+)/)[1]));

const readNativeSlides = (file) => slideEntries(file).map((entry, index) => {
  const xml = execFileSync('unzip', ['-p', file, entry], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  return { number: index + 1, text: normalize([...xml.matchAll(/<a:t>([\s\S]*?)<\/a:t>/g)].map((match) => match[1]).join(' ')) };
});

const slidePictures = (file, slideNumber) => {
  const xml = execFileSync('unzip', ['-p', file, `ppt/slides/slide${slideNumber}.xml`], { encoding: 'utf8' });
  const relXml = execFileSync('unzip', ['-p', file, `ppt/slides/_rels/slide${slideNumber}.xml.rels`], { encoding: 'utf8' });
  const relations = new Map([...relXml.matchAll(/<Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"/g)].map((match) => [match[1], match[2]]));
  return [...xml.matchAll(/<p:pic>[\s\S]*?<\/p:pic>/g)].map((match) => {
    const picture = match[0];
    const rid = picture.match(/r:embed="([^"]+)"/)?.[1];
    const off = picture.match(/<a:off x="(\d+)" y="(\d+)"\/>/);
    const ext = picture.match(/<a:ext cx="(\d+)" cy="(\d+)"\/>/);
    const target = relations.get(rid);
    return target && off && ext ? {
      entry: path.posix.normalize(path.posix.join('ppt/slides', target)),
      x: Number(off[1]), y: Number(off[2]), width: Number(ext[1]), height: Number(ext[2])
    } : null;
  }).filter(Boolean);
};

const sourceId = (file) => {
  const match = path.basename(file).match(/Discover([123])_U(\d+)/i);
  if (!match) return null;
  return { book: Number(match[1]), unit: Number(match[2]), key: `${Number(match[1])}-${Number(match[2])}` };
};

const run = (command, args, options = {}) => execFileSync(command, args, {
  encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024, ...options
});

// Pillow is already bundled in the local Python runtime. It is used only to
// locate red ink in a rendered slide; OCR remains Tesseract-based.
const RED_COMPONENTS = String.raw`
from PIL import Image
import json, sys
im = Image.open(sys.argv[1]).convert('RGB')
original_w, original_h = im.size
scale = min(1, 560 / original_w)
if scale < 1: im = im.resize((round(original_w * scale), round(original_h * scale)))
w, h = im.size
pix = im.load(); seen=set(); comps=[]
for y in range(h):
  for x in range(w):
    if (x,y) in seen: continue
    r,g,b = pix[x,y]
    if not (r >= 170 and g <= 115 and b <= 115 and r >= g * 1.45 and r >= b * 1.45): continue
    stack=[(x,y)]; seen.add((x,y)); minx=maxx=x; miny=maxy=y; count=0
    while stack:
      cx,cy=stack.pop(); count+=1; minx=min(minx,cx); maxx=max(maxx,cx); miny=min(miny,cy); maxy=max(maxy,cy)
      for nx,ny in ((cx-1,cy),(cx+1,cy),(cx,cy-1),(cx,cy+1)):
        if nx < 0 or ny < 0 or nx >= w or ny >= h or (nx,ny) in seen: continue
        rr,gg,bb=pix[nx,ny]
        if rr >= 170 and gg <= 115 and bb <= 115 and rr >= gg * 1.45 and rr >= bb * 1.45:
          seen.add((nx,ny)); stack.append((nx,ny))
    if count >= 8 and (maxx-minx >= 4 or maxy-miny >= 4): comps.append([round(minx/scale),round(miny/scale),round(maxx/scale),round(maxy/scale),count])
print(json.dumps(comps))
`;

const redComponents = (image, workdir) => JSON.parse(run('python', ['-c', RED_COMPONENTS, image], { cwd: workdir }) || '[]')
  .filter(([left, top, right, bottom]) => right - left > 35 || bottom - top > 35)
  .map(([left, top, right, bottom]) => ({ left, top, right, bottom }));

const parseTsv = (image, workdir) => {
  const stdout = run('tesseract', [path.basename(image), 'stdout', '--psm', '6', 'tsv'], { cwd: workdir });
  const rows = stdout.split('\n').slice(1).map((line) => line.split('\t')).filter((fields) => fields.length >= 12);
  const words = rows.filter((fields) => fields[0] === '5' && fields[11].trim()).map((fields) => ({
    block: fields[2], paragraph: fields[3], line: fields[4],
    left: Number(fields[6]), top: Number(fields[7]), width: Number(fields[8]), height: Number(fields[9]),
    confidence: Number(fields[10]), text: fields[11].trim()
  }));
  const grouped = new Map();
  for (const word of words) {
    const key = `${word.block}-${word.paragraph}-${word.line}`;
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(word);
  }
  return [...grouped.values()].map((line) => {
    const sorted = line.sort((left, right) => left.left - right.left);
    return {
      words: sorted,
      text: normalize(sorted.map((word) => word.text).join(' ')),
      left: Math.min(...sorted.map((word) => word.left)), top: Math.min(...sorted.map((word) => word.top)),
      right: Math.max(...sorted.map((word) => word.left + word.width)), bottom: Math.max(...sorted.map((word) => word.top + word.height))
    };
  }).sort((left, right) => left.top - right.top || left.left - right.left);
};

const imageSize = (image, workdir) => JSON.parse(run('python', ['-c', 'from PIL import Image; import json,sys; print(json.dumps(Image.open(sys.argv[1]).size))', image], { cwd: workdir }));

const intersects = (a, b) => a.left <= b.right && a.right >= b.left && a.top <= b.bottom && a.bottom >= b.top;
const contains = (a, b) => a.left <= b.left && a.right >= b.right && a.top <= b.top && a.bottom >= b.bottom;
const optionText = (value) => normalize(value.replace(/^[a-ds]\s*[.)]?\s*/i, ''));

const parseChoiceOptions = (lines) => {
  const output = [];
  for (const line of lines) {
    const markers = [...line.text.matchAll(/(?:^|\s)([b-d0])\s*[.)]\s*/gi)];
    const startsWithA = /^[as]\s+(?![A-Z]{2,}\b)/i.test(line.text) || /^a\s*[.)]\s*/i.test(line.text);
    if (markers.length || startsWithA) {
      const starts = [];
      if (startsWithA) starts.push({ index: 0, label: 'a' });
      for (const marker of markers) {
        const rawLabel = marker[1].toLowerCase();
        starts.push({ index: marker.index + marker[0].search(/[b-d0]/i), label: rawLabel === '0' ? 'b' : rawLabel });
      }
      starts.sort((left, right) => left.index - right.index);
      for (let index = 0; index < starts.length; index += 1) {
        const start = starts[index];
        const end = starts[index + 1]?.index ?? line.text.length;
        const text = optionText(line.text.slice(start.index, end));
        if (!text || text.length < 2) continue;
        const matchingWords = line.words.filter((word) => word.left + word.width >= line.left + (line.right - line.left) * (start.index / Math.max(line.text.length, 1))
          && word.left <= line.left + (line.right - line.left) * (end / Math.max(line.text.length, 1)));
        output.push({ label: start.label, text, left: Math.min(...matchingWords.map((word) => word.left)), top: line.top, right: Math.max(...matchingWords.map((word) => word.left + word.width)), bottom: line.bottom });
      }
    }
  }
  const unique = new Map();
  for (const option of output) if (!unique.has(option.label)) unique.set(option.label, option);
  return [...unique.values()].sort((left, right) => left.label.localeCompare(right.label));
};

const answerFromRed = (options, reds) => {
  let winner = null;
  for (const [index, option] of options.entries()) {
    for (const red of reds) {
      const score = (contains(red, option) ? 1_000_000 : 0)
        + Math.max(0, Math.min(red.right, option.right) - Math.max(red.left, option.left))
          * Math.max(0, Math.min(red.bottom, option.bottom) - Math.max(red.top, option.top));
      if (score > 0 && (!winner || score > winner.score)) winner = { index, score };
    }
  }
  return winner?.index ?? null;
};

const promptFromLines = (lines, options) => {
  const optionTops = options.map((option) => option.top);
  const beforeOptions = lines.filter((line) => optionTops.every((top) => line.bottom < top - 5));
  const candidates = beforeOptions.map((line) => line.text)
    .filter((text) => text.length >= 8)
    .filter((text) => !/^(?:reading|choose the right answer|main idea|detail|inference|reading comprehension)/i.test(text));
  return normalize(candidates.find((text) => /[?.]$/.test(text)) || candidates.at(-1) || '').replace(/^\d+\s*[.)]\s*/, '');
};

const promptFromNative = (native, options) => {
  const match = native.match(/(?:MAIN IDEA|DETAIL|INFERENCE)\s+(.+?)(?:\s+READING\s+COMPREHENSION|$)/i);
  if (!match) return '';
  let prompt = normalize(match[1]);
  for (const option of options) {
    if (prompt.toLowerCase().endsWith(` ${option.text.toLowerCase()}`)) prompt = prompt.slice(0, -option.text.length).trim();
  }
  return prompt;
};

const pictureOptions = (file, slideNumber, workdir, pageRight, pageBottom, reds) => {
  const pictures = slidePictures(file, slideNumber);
  const slideWidth = 12_192_000;
  const slideHeight = 6_858_000;
  const candidates = [];
  for (const [index, picture] of pictures.entries()) {
    const ext = path.extname(picture.entry) || '.png';
    const asset = path.join(workdir, `asset-${slideNumber}-${index}${ext}`);
    fs.writeFileSync(asset, execFileSync('unzip', ['-p', file, picture.entry]));
    const lines = parseTsv(asset, workdir);
    const options = parseChoiceOptions(lines);
    if (options.length < 2) continue;
    const [imageWidth, imageHeight] = imageSize(asset, workdir);
    const mapped = options.map((option) => ({
      ...option,
      left: ((picture.x + picture.width * option.left / imageWidth) / slideWidth) * pageRight,
      right: ((picture.x + picture.width * option.right / imageWidth) / slideWidth) * pageRight,
      top: ((picture.y + picture.height * option.top / imageHeight) / slideHeight) * pageBottom,
      bottom: ((picture.y + picture.height * option.bottom / imageHeight) / slideHeight) * pageBottom
    }));
    candidates.push({ options: mapped, prompt: promptFromLines(lines, options), answerIndex: answerFromRed(mapped, reds) });
  }
  return candidates.sort((left, right) => right.options.length - left.options.length)[0] || null;
};

const trueFalseQuestion = (native, lines, reds) => {
  const match = native.match(/Circle\s+T\s+for\s+true\s+or\s+F\s+for\s+false\.\s*(.+?)\s+T\s+F(?:\s|$)/i);
  if (!match) return null;
  // The instruction line also contains a T and F. The large answer buttons
  // are always lower on the slide, so retain the bottom-most token for each.
  const tokens = lines.flatMap((line) => line.words).filter((word) => /^(?:T|F)$/i.test(word.text));
  const options = ['T', 'F'].map((label) => {
    const token = tokens.filter((item) => item.text.toUpperCase() === label)
      .sort((left, right) => right.top - left.top)[0];
    return token && { label, text: label === 'T' ? 'True' : 'False', left: token.left, top: token.top, right: token.left + token.width, bottom: token.top + token.height };
  }).filter(Boolean);
  const pageRight = Math.max(...lines.map((line) => line.right), ...reds.map((red) => red.right));
  const pageBottom = Math.max(...lines.map((line) => line.bottom), ...reds.map((red) => red.bottom));
  // Tesseract often omits the large coloured T/F glyphs inside a red circle.
  // In that case, the red circle's horizontal position is the answer key.
  const answerInk = reds.filter((red) => red.top > pageBottom * 0.45)
    .sort((left, right) => (right.right - right.left) * (right.bottom - right.top) - (left.right - left.left) * (left.bottom - left.top))[0];
  const answerIndex = answerInk
    ? ((answerInk.left + answerInk.right) / 2 < pageRight / 2 ? 0 : 1)
    : answerFromRed(options, reds);
  return options.length === 2 && Number.isInteger(answerIndex)
    ? { prompt: normalize(match[1]), options: options.map((option) => option.text), answerIndex, kind: 'true-false' }
    : null;
};

const choiceQuestion = (file, slideNumber, native, lines, reds, workdir, image) => {
  const [pageRight, pageBottom] = imageSize(image, workdir);
  const fromPicture = pictureOptions(file, slideNumber, workdir, pageRight, pageBottom, reds);
  const options = fromPicture?.options || parseChoiceOptions(lines);
  const answerIndex = fromPicture?.answerIndex ?? answerFromRed(options, reds);
  const prompt = fromPicture?.prompt || promptFromLines(lines, options) || promptFromNative(native, options);
  if (options.length < 2 || !Number.isInteger(answerIndex) || !prompt) return null;
  return { prompt, options: options.map((option) => option.text), answerIndex, kind: 'choice' };
};

const renderDeck = (file, workdir) => {
  const pdfDir = path.join(workdir, 'pdf');
  fs.mkdirSync(pdfDir, { recursive: true });
  run('soffice', ['--headless', '--convert-to', 'pdf', '--outdir', pdfDir, file]);
  const pdf = path.join(pdfDir, `${path.basename(file, '.pptx')}.pdf`);
  run('pdftoppm', ['-jpeg', '-r', '160', pdf, path.join(workdir, 'page')]);
};

const extractDeck = (file, workdir) => {
  const info = sourceId(file);
  const nativeSlides = readNativeSlides(file);
  renderDeck(file, workdir);
  const questions = [];
  const skipped = [];
  for (const slide of nativeSlides) {
    const isTf = /Circle\s+T\s+for\s+true\s+or\s+F\s+for\s+false/i.test(slide.text);
    const isChoice = /Choose the right answer/i.test(slide.text);
    if (!isTf && !isChoice) continue;
    const image = path.join(workdir, `page-${slide.number}.jpg`);
    if (!fs.existsSync(image)) { skipped.push({ slide: slide.number, reason: 'render_missing' }); continue; }
    const lines = parseTsv(image, workdir);
    const reds = redComponents(image, workdir);
    const parsed = isTf ? trueFalseQuestion(slide.text, lines, reds) : choiceQuestion(file, slide.number, slide.text, lines, reds, workdir, image);
    if (!parsed) { skipped.push({ slide: slide.number, reason: isTf ? 'true_false_not_resolved' : 'choice_not_resolved', native: slide.text, ocr: lines.map((line) => line.text) }); continue; }
    questions.push({ id: `q${questions.length + 1}`, index: questions.length + 1, ...parsed, paragraphHint: null, type: 'single', sourceSlide: slide.number });
  }
  return { ...info, file, slideCount: nativeSlides.length, questions, skipped };
};

const install = (importPath, deckResults) => {
  const articles = JSON.parse(fs.readFileSync(importPath, 'utf8'));
  const byKey = new Map(deckResults.map((result) => [result.key, result.questions]));
  let installed = 0;
  for (const article of articles) {
    const match = String(article.id).match(/^rfd([123])-(\d{2})-/);
    if (!match) continue;
    const questions = byKey.get(`${Number(match[1])}-${Number(match[2])}`);
    if (!questions) continue;
    article.questions = questions;
    article.unsupportedQuestions = [];
    installed += questions.length;
  }
  fs.writeFileSync(importPath, `${JSON.stringify(articles, null, 2)}\n`);
  return { articleCount: byKey.size, questionCount: installed };
};

const main = () => {
  const args = parseArgs(process.argv.slice(2));
  if (args.reports) {
    const results = args.reports.split(',').map((file) => JSON.parse(fs.readFileSync(path.resolve(file), 'utf8')).decks).flat();
    const installed = install(args.importPath, results);
    console.log(`Installed ${installed.questionCount} questions across ${installed.articleCount} RFD articles.`);
    return;
  }
  const files = walk(args.input).sort((left, right) => left.localeCompare(right, 'zh-Hans-CN', { numeric: true }))
    .filter((file) => !args.only || sourceId(file)?.key === args.only);
  if (!files.length) throw new Error(`No RFD PPTX files found in ${args.input}`);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rfd-quiz-'));
  const results = [];
  try {
    for (const file of files) {
      const deckDir = path.join(root, path.basename(file, '.pptx'));
      fs.mkdirSync(deckDir, { recursive: true });
      const result = extractDeck(file, deckDir);
      results.push(result);
      console.log(`OK RFD${result.book} U${result.unit}: questions=${result.questions.length} skipped=${result.skipped.length}`);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
  const report = {
    generatedAt: new Date().toISOString(), sourceDir: path.relative(cwd, args.input),
    deckCount: results.length, questionCount: results.reduce((sum, result) => sum + result.questions.length, 0),
    skippedCount: results.reduce((sum, result) => sum + result.skipped.length, 0), decks: results
  };
  if (!args.dryRun) {
    fs.mkdirSync(args.out, { recursive: true });
    fs.writeFileSync(path.join(args.out, 'rfd-quiz.report.json'), `${JSON.stringify(report, null, 2)}\n`);
    if (!args.noInstall) {
      const installed = install(args.importPath, results);
      console.log(`Installed ${installed.questionCount} questions across ${installed.articleCount} RFD articles.`);
    }
  }
  console.log(JSON.stringify({ deckCount: report.deckCount, questionCount: report.questionCount, skippedCount: report.skippedCount }));
};

main();
