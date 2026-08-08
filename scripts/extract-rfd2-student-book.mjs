#!/usr/bin/env node
/** Import every RFD2 Student Book exercise page as an open practice record.
 * The source PDF is scanned, so OCR is intentionally retained verbatim rather
 * than guessing missing words.  Four exercise pages per unit × 16 units gives
 * a mechanically verifiable 64-page coverage contract. */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const cwd = process.cwd();
const DEFAULT_INPUT = '/Users/coty/Downloads/Level 3 Reading Future Discover PDF Resources (A1+)/Reading Future Discover 2/Reading Future Discover 2 Student Book.pdf';
const DEFAULT_IMPORT = path.join(cwd, 'data/generated-reader-json/reader-articles.import.json');
const args = process.argv.slice(2).reduce((out, arg, index, all) => {
  if (arg === '--input') out.input = path.resolve(all[index + 1]);
  if (arg === '--import') out.importPath = path.resolve(all[index + 1]);
  return out;
}, { input: DEFAULT_INPUT, importPath: DEFAULT_IMPORT });

const run = (command, commandArgs, options = {}) => execFileSync(command, commandArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...options });
const clean = (value = '') => value.replace(/\r/g, '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
const pageText = (image, directory) => clean(run('tesseract', [path.basename(image), 'stdout', '--psm', '6'], { cwd: directory }));

const main = () => {
  if (!fs.existsSync(args.input)) throw new Error(`Student Book not found: ${args.input}`);
  const workdir = fs.mkdtempSync(path.join(os.tmpdir(), 'rfd2-student-book-'));
  try {
    // Student-book pages 10–73 are PDF pages 11–74; every unit has four pages.
    run('pdftoppm', ['-f', '11', '-l', '74', '-jpeg', '-scale-to', '1500', args.input, path.join(workdir, 'page')]);
    const articles = JSON.parse(fs.readFileSync(args.importPath, 'utf8'));
    let total = 0;
    for (let unit = 1; unit <= 16; unit += 1) {
      const article = articles.find((item) => String(item.id).startsWith(`rfd2-${String(unit).padStart(2, '0')}-`));
      if (!article) throw new Error(`RFD2 Unit ${unit} is missing from the import bundle`);
      const firstPdfPage = 11 + (unit - 1) * 4;
      const exercises = Array.from({ length: 4 }, (_, offset) => {
        const pdfPage = firstPdfPage + offset;
        const bookPage = pdfPage - 1;
        const text = pageText(path.join(workdir, `page-${String(pdfPage).padStart(2, '0')}.jpg`), workdir);
        if (!text) throw new Error(`OCR produced no text for Student Book page ${bookPage}`);
        return {
          id: `student-book-p${bookPage}`,
          index: 10_000 + bookPage,
          prompt: `Student Book · page ${bookPage}\n\n${text}`,
          options: [], answerIndex: null, rawAnswer: '', type: 'unsupported',
          kind: 'student-book-exercise-page', answerSource: 'student-book',
          sourceBookPage: bookPage, paragraphHint: null
        };
      });
      const existing = Array.isArray(article.questions) ? article.questions.filter((question) => question.kind !== 'student-book-exercise-page') : [];
      article.questions = [...existing, ...exercises];
      total += exercises.length;
    }
    fs.writeFileSync(args.importPath, `${JSON.stringify(articles, null, 2)}\n`);
    console.log(JSON.stringify({ units: 16, studentBookPages: total, expectedPages: 64 }));
  } finally { fs.rmSync(workdir, { recursive: true, force: true }); }
};
main();
