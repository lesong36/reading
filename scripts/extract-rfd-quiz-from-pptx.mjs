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

// A small number of question pages use a very thin red circle or have their
// question/answers split across decorative images.  Keep these recoveries
// explicit and reviewable instead of silently losing the page.  `answerSource`
// tells the reader that the answer was reconstructed from the reading when the
// PowerPoint ink could not be machine-verified.
const RECOVERED_QUESTIONS = {
  '1-1:31': ['What is the reading mainly about?', ['Farmers', 'Weather and animals', 'Winter'], 1],
  '1-1:33': ['What do cows and horses do before it rains?', ['They get fat.', 'They eat a lot.', 'They smell the air.'], 2],
  '1-2:30': ['What is the reading mainly about?', ['Kinds of clouds', 'Kinds of storms', 'Kinds of weather'], 0],
  '1-2:32': ['What is true about storm clouds?', ['They are dark and gray.', 'They are white and fluffy.', 'They are thin and long.'], 0],
  '1-3:31': ['What is the reading mainly about?', ['Water', 'Snow', 'Weather'], 0],
  '1-3:33': ['What happens when water moves up and down inside storm clouds?', ['It becomes rain.', 'It becomes snow.', 'It becomes hail.'], 2],
  '1-4:32': ['What can a tornado do?', ['It can fall from the sky.', 'It can carry things far.', 'It can make snow.'], 1],
  '1-5:31': ['What is the reading mainly about?', ['Africa', 'Building homes', 'Ice and snow'], 1],
  '1-5:32': ['Why do some people in Gabon use wood to make their homes?', ['They have many trees.', 'It is very hot.', 'They live far in the north.'], 0],
  '1-6:32': ['People keep fish in nets ______ their homes.', ['on', 'under', 'above'], 1],
  '1-6:33': ["How do people get fish if they don't live near the water?", ['They buy them.', 'They keep them in nets.', "They can't get fish."], 0],
  '1-8:31': ['What is the reading mainly about?', ['Drying food', 'Raising llamas', 'Living in the Andes'], 2],
  '1-8:32': ['Llamas are special animals that have long ______.', ['hair', 'meat', 'potatoes'], 0],
  '1-8:33': ['How do the people of the Andes make their food last a long time?', ['They cook it.', 'They dry it.', 'They grow it.'], 1],
  '1-9:32': ['What does moving do for your body?', ['It slows your blood.', 'It makes it happy and healthy.', 'It can hurt it.'], 1],
  '1-10:28': ['Doing things that make you feel good is a good idea.', ['True', 'False'], 0, 'true-false'],
  '1-10:33': ['What matters most?', ['How you feel', 'How you look', 'How you compare yourself to others'], 0],
  '1-11:32': ['How does oxygen move around your body?', ['It helps your brain.', 'It comes from food.', "It's carried by blood."], 2],
  '1-12:29': ['What is the reading mainly about?', ['Martial arts', 'Weapons', 'Fighting'], 0],
  '1-12:31': ['Why are martial arts still popular?', ["They're dangerous.", "They're great for exercise.", 'People use their hands and feet.'], 1],
  '1-13:33': ['What happened when Archimedes sat in the bath?', ['Water poured out.', 'He found the tub’s volume.', 'He found the king’s crown.'], 0],
  '1-15:32': ['How tall are most women?', ['They are about 160 cm.', 'They are about 174 cm.', 'They are about 251 cm.'], 0],
  '1-16:31': ['How fast can a horse and rider go?', ['45 km an hour', '72 km an hour', '80 km an hour'], 0],
  '2-2:25': ['Pythagoras thought the earth was flat.', ['True', 'False'], 1, 'true-false'],
  '2-4:26': ['The atmosphere helps rocks to burn before they hit the earth.', ['True', 'False'], 0, 'true-false'],
  '2-4:31': ['The word “huge” means ______.', ['big', 'hard', 'round'], 0],
  '3-3:33': ['The word “culture” means ______.', ['a language', 'a shared way of being', 'a way of dressing'], 1],
  '3-6:33': ['The word “over” in the reading means ______.', ['on top of', 'more than', 'done with'], 1],
  '3-7:32': ['The word “ugly” means ______.', ['not pretty', 'not delicious', 'not expensive'], 0]
};

// OCR gives us the answer cards reliably, but these prompts are wrapped inside
// raster artwork.  Preserve the complete wording rather than retaining only a
// final line such as "the sky?".
const PROMPT_REPAIRS = {
  '1-1:30': 'What do rabbits do when a long, cold winter is coming?',
  '1-4:29': 'What can fall from the sky?',
  '1-5:33': 'In the north of North America, snow and ice ______ the ground.',
  '1-7:29': 'What makes the Sami people different?',
  '1-8:29': 'What is the weather like in the Andes Mountains?',
  '1-9:29': 'What should you do if you sit for a long time?',
  '1-10:29': 'Who do people compare themselves to?',
  '1-11:28': 'What happens when you use your muscles?',
  '1-12:27': 'What did people use martial arts to protect before they had guns?',
  '1-15:29': 'Who is taller, Sultan Kosen or Junrey Balawing?',
  '2-3:28': 'What do people wonder about the moon?',
  '2-3:32': 'What can people say about the moon after reading the passage?',
  '2-9:28': 'What should you do with money for something?',
  '2-11:30': 'Why are holograms hard to copy?',
  '2-12:29': 'Why should you save money one coin at a time?',
  '2-13:30': 'What does less air make?',
  '2-15:29': 'Which two things can you do with your mouth?',
  '2-15:30': 'When did mouth music become popular?',
  '2-2:28': 'How did Pythagoras know the earth is round?',
  '2-2:29': 'Who thought the earth is round?',
  '3-2:30': "What helps deaf people communicate with people who don't know sign language?",
  '3-5:33': 'Most people ______ their straws ______ when they are done with them.',
  '3-5:32': 'What happens when people stop using plastic straws?',
  '3-6:29': 'What happens to people who do not have fresh water?',
  '3-8:32': "If people do not ______ shoes, they may get cuts on their feet.",
  '3-8:33': 'Why are The Shoe That Grows better than regular shoes?',
  '3-9:29': 'How long did it take to take a picture with the new camera?',
  '3-9:30': 'Who was the first person to be photographed?',
  '3-9:32': 'What happened to people in the photograph if they moved too fast?',
  '3-10:30': 'What kind of pictures did people use cameras to take in the 1990s?',
  '3-10:31': 'What did people do with cameras in the 1990s?',
  '3-12:30': 'How can you see an immersive picture?',
  '3-12:29': 'How are 360-degree cameras different from other cameras?',
  '3-13:29': 'What kind of jobs are common in the country?',
  '3-13:30': 'Why did governments stop children from working certain jobs?',
  '3-15:29': 'What job does the child want to have?',
  '3-15:30': 'What happens when child actors become successful actors?',
  '3-16:32': 'The word “require” means ______.'
};

const repairPrompt = (key, question) => PROMPT_REPAIRS[key]
  ? { ...question, prompt: PROMPT_REPAIRS[key] }
  : question;

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
  const runs = [...xml.matchAll(/<a:t>([\s\S]*?)<\/a:t>/g)].map((match) => normalize(match[1])).filter(Boolean);
  return { number: index + 1, text: normalize(runs.join(' ')), runs };
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
const optionText = (value) => normalize(value.replace(/^[a-ds]\s*[.)]?\s*/i, ''))
  .replace(/\bisa\b/gi, 'is a')
  .replace(/\s+[—-]\s*$/g, '')
  .trim();

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
  const options = [...unique.values()].sort((left, right) => left.label.localeCompare(right.label));
  // OCR commonly puts the last word of the left-most picture-card label on a
  // second line (for example, “How the earth” / “moves”). Attach such a line
  // to the horizontally nearest option instead of turning it into a fragment.
  for (const line of lines) {
    if (/[a-d0]\s*[.)]/i.test(line.text) || !line.text || options.length < 2) continue;
    const eligible = options.filter((option) => line.top >= option.top && line.top <= option.bottom + 180);
    if (!eligible.length) continue;
    const closest = eligible.reduce((best, option) =>
      Math.abs(option.left - line.left) < Math.abs(best.left - line.left) ? option : best);
    if (Math.abs(closest.left - line.left) < 180 && line.text.length <= 40) {
      closest.text = optionText(`${closest.text} ${line.text}`);
      closest.bottom = Math.max(closest.bottom, line.bottom);
    }
  }
  return options;
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
  if (winner) return winner.index;
  // Main-idea cards use a large red tick over the picture, not a circle around
  // the answer text. When options share one row, horizontal alignment remains
  // an unambiguous way to associate that tick with its card.
  if (options.length >= 2 && reds.length) {
    const rowLike = Math.max(...options.map((option) => option.top)) - Math.min(...options.map((option) => option.top)) < 120;
    if (rowLike) {
      const red = reds.sort((left, right) => (right.right - right.left) * (right.bottom - right.top) - (left.right - left.left) * (left.bottom - left.top))[0];
      const center = (red.left + red.right) / 2;
      return options.reduce((best, option, index) =>
        Math.abs((option.left + option.right) / 2 - center) < best.distance
          ? { index, distance: Math.abs((option.left + option.right) / 2 - center) }
          : best,
      { index: null, distance: Infinity }).index;
    }
  }
  return null;
};

const promptFromLines = (lines, options) => {
  const optionTops = options.map((option) => option.top);
  const beforeOptions = lines.filter((line) => optionTops.every((top) => line.bottom < top - 5));
  const candidates = beforeOptions.map((line) => line.text)
    .filter((text) => text.length >= 2)
    .filter((text) => !/^(?:reading|choose the right answer|main idea|detail|inference|vocabulary|reading comprehension)/i.test(text));
  // Questions in the source artwork often wrap after the subject or verb. Join
  // the consecutive lines instead of taking only the last one (which produced
  // prompts such as "the sky?" and "fresh water?").
  return normalize(candidates.join(' ')).replace(/^\d+\s*[.)]\s*/, '');
};

const promptFromNative = (native, options) => {
  const match = native.match(/(?:MAIN IDEA|DETAIL|INFERENCE)\s+(.+?)(?:\s+READING\s+COMPREHENSION|$)/i);
  if (!match) return '';
  let prompt = normalize(match[1]);
  for (const option of options) {
    if (prompt.toLowerCase().endsWith(` ${option.text.toLowerCase()}`)) prompt = prompt.slice(0, -option.text.length).trim();
  }
  return /^(?:reading comprehension|choose the right answer|main idea|detail|inference|vocabulary)$/i.test(prompt)
    ? ''
    : prompt;
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
    ? { prompt: normalize(match[1]), options: options.map((option) => option.text), answerIndex, kind: 'true-false', answerSource: 'ppt-mark' }
    : null;
};

const correctionQuestion = (slide) => {
  const instruction = 'Correct the underlined word in the sentence. Write the correct word.';
  if (!/Correct the underlined words? in the sentence\. Write the correct word\./i.test(slide.text)) return null;
  const answer = slide.runs.at(-1);
  const marker = 'READING COMPREHENSION';
  const body = slide.text.slice(slide.text.indexOf(marker) + marker.length).trim();
  const sentence = answer && body.endsWith(answer) ? body.slice(0, -answer.length).trim() : body;
  if (!sentence || !answer || sentence === answer) return null;
  return {
    prompt: `${instruction}\n\n${sentence}`,
    options: [],
    answerIndex: null,
    rawAnswer: answer,
    kind: 'correction',
    answerSource: 'ppt-mark',
    type: 'unsupported'
  };
};

const choiceQuestion = (file, slideNumber, native, lines, reds, workdir, image) => {
  const [pageRight, pageBottom] = imageSize(image, workdir);
  const fromPicture = pictureOptions(file, slideNumber, workdir, pageRight, pageBottom, reds);
  const options = fromPicture?.options || parseChoiceOptions(lines);
  const answerIndex = fromPicture?.answerIndex ?? answerFromRed(options, reds);
  const prompt = promptFromNative(native, options) || fromPicture?.prompt || promptFromLines(lines, options);
  if (options.length < 2 || !Number.isInteger(answerIndex) || !prompt) return null;
  return { prompt, options: options.map((option) => option.text), answerIndex, kind: 'choice', answerSource: 'ppt-mark' };
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
    const isCorrection = /Correct the underlined words? in the sentence\. Write the correct word\./i.test(slide.text);
    if (!isTf && !isChoice && !isCorrection) continue;
    if (isCorrection) {
      const parsed = correctionQuestion(slide);
      if (!parsed) { skipped.push({ slide: slide.number, reason: 'correction_not_resolved', native: slide.text }); continue; }
      questions.push({ id: `q${questions.length + 1}`, index: questions.length + 1, ...parsed, paragraphHint: null, sourceSlide: slide.number });
      continue;
    }
    const image = path.join(workdir, `page-${slide.number}.jpg`);
    if (!fs.existsSync(image)) { skipped.push({ slide: slide.number, reason: 'render_missing' }); continue; }
    const lines = parseTsv(image, workdir);
    const reds = redComponents(image, workdir);
    const parsed = isTf ? trueFalseQuestion(slide.text, lines, reds) : choiceQuestion(file, slide.number, slide.text, lines, reds, workdir, image);
    const recovered = RECOVERED_QUESTIONS[`${info.key}:${slide.number}`];
    const finalQuestion = (recovered && {
      prompt: recovered[0], options: recovered[1], answerIndex: recovered[2], kind: recovered[3] || 'choice',
      answerSource: 'inferred-from-passage'
    }) || parsed;
    if (!finalQuestion) { skipped.push({ slide: slide.number, reason: isTf ? 'true_false_not_resolved' : 'choice_not_resolved', native: slide.text, ocr: lines.map((line) => line.text) }); continue; }
    questions.push(repairPrompt(`${info.key}:${slide.number}`, {
      id: `q${questions.length + 1}`, index: questions.length + 1, ...finalQuestion, paragraphHint: null, type: 'single', sourceSlide: slide.number
    }));
  }
  return { ...info, file, slideCount: nativeSlides.length, questions, skipped };
};

const collectCorrectionQuestions = (input) => {
  const byKey = new Map();
  for (const file of walk(input)) {
    const info = sourceId(file);
    if (!info) continue;
    const questions = readNativeSlides(file)
      .map((slide) => ({ slide, question: correctionQuestion(slide) }))
      .filter(({ question }) => question)
      .map(({ slide, question }) => ({ ...question, sourceSlide: slide.number, paragraphHint: null }));
    if (questions.length) byKey.set(info.key, questions);
  }
  return byKey;
};

const install = (importPath, deckResults) => {
  const articles = JSON.parse(fs.readFileSync(importPath, 'utf8'));
  const byKey = new Map(deckResults.map((result) => [result.key, result.questions]));
  const correctionByKey = collectCorrectionQuestions(DEFAULT_INPUT);
  let installed = 0;
  for (const article of articles) {
    const match = String(article.id).match(/^rfd([123])-(\d{2})-/);
    if (!match) continue;
    const key = `${Number(match[1])}-${Number(match[2])}`;
    const questions = byKey.get(key);
    if (!questions) continue;
    const recovered = Object.entries(RECOVERED_QUESTIONS)
      .filter(([recoveryKey]) => recoveryKey.startsWith(`${key}:`))
      .map(([recoveryKey, values]) => ({
        sourceSlide: Number(recoveryKey.split(':')[1]), prompt: values[0], options: values[1], answerIndex: values[2],
        kind: values[3] || 'choice', answerSource: 'inferred-from-passage', paragraphHint: null, type: 'single'
      }));
    const corrections = correctionByKey.get(key) || [];
    const merged = [...questions, ...recovered, ...corrections]
      .filter((item, index, all) => all.findIndex((question) => question.sourceSlide === item.sourceSlide) === index)
      .sort((left, right) => left.sourceSlide - right.sourceSlide)
      .map((question, index) => repairPrompt(`${key}:${question.sourceSlide}`, { ...question, id: `q${index + 1}`, index: index + 1 }));
    article.questions = merged;
    article.unsupportedQuestions = [];
    installed += merged.length;
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
