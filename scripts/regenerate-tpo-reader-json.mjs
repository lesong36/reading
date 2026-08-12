#!/usr/bin/env node
/**
 * Batch runner for TPO passage analysis against P920 llama.cpp (OpenAI-compatible).
 * Never uses local Mac Ollama.
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const DEFAULT_BASE = process.env.LLM_BASE_URL || 'http://100.121.25.47:8090/v1';
const DEFAULT_PROVIDER = process.env.LLM_PROVIDER || 'openai';
const cleanPassagesRoot = path.resolve(cwd, 'data/tpo-source-clean/passages');
const outputRoot = path.resolve(cwd, 'data/generated-reader-json-tpo');
const sourceManifestPath = path.resolve(cwd, 'data/tpo-source/manifest.json');

const BATCHES = {
  // The analyzer's --only option is a title substring match, so "TPO-1"
  // would also select TPO-10 through TPO-19. Use filename filtering for an
  // exact smoke batch instead.
  B0: { label: 'TPO-1 smoke', only: '', filter: /^tpo-1-/i, expectedCount: 3 },
  B1: { label: 'OG + Online + Official', only: '', filter: /^(og|online-test|official-model-exam|og-test-2)-/i, expectedCount: 17 },
  B2: { label: 'TPO 1,3-10', only: '', filter: /^tpo-([1-9]|10)-/i, expectedCount: 27 },
  B3: { label: 'TPO 11-20', only: '', filter: /^tpo-(1[1-9]|20)-/i, expectedCount: 30 },
  B4: { label: 'TPO 21-30', only: '', filter: /^tpo-(2[1-9]|30)-/i, expectedCount: 30 }
};

const parseArgs = (argv) => {
  const args = {
    batch: 'B0',
    provider: DEFAULT_PROVIDER,
    baseUrl: DEFAULT_BASE,
    model: process.env.LLM_MODEL || '',
    timeoutMs: process.env.LLM_TIMEOUT_MS || '900000',
    // Eight sentences keep the legacy deep-analysis payload comfortably below
    // the P920 JSON truncation threshold while retaining paragraph context.
    chunkSentences: process.env.TPO_CHUNK_SENTENCES || '8',
    input: cleanPassagesRoot,
    ids: [],
    force: false,
    dryRun: false
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => argv[++i];
    if (arg === '--batch') args.batch = next();
    else if (arg === '--provider') args.provider = next();
    else if (arg === '--base-url') args.baseUrl = next();
    else if (arg === '--model') args.model = next();
    else if (arg === '--timeout-ms') args.timeoutMs = next();
    else if (arg === '--chunk-sentences') args.chunkSentences = next();
    else if (arg === '--input') args.input = path.resolve(cwd, next());
    else if (arg === '--ids') args.ids = next().split(',').map((id) => id.trim()).filter(Boolean);
    else if (arg === '--force') args.force = true;
    else if (arg === '--dry-run') args.dryRun = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
};

const assertRemoteHealthy = async (baseUrl) => {
  const root = baseUrl.replace(/\/+$/, '').replace(/\/v1$/, '');
  const healthUrl = `${root}/health`;
  const response = await fetch(healthUrl);
  if (!response.ok) throw new Error(`P920 health check failed: ${healthUrl} HTTP ${response.status}`);
  const payload = await response.json();
  if (payload?.status !== 'ok') throw new Error(`P920 health unexpected: ${JSON.stringify(payload)}`);
  if (/127\.0\.0\.1|localhost/.test(baseUrl)) {
    throw new Error('Refusing local Ollama/base URL for TPO pipeline. Use http://100.121.25.47:8090/v1');
  }
};

const loadCanonicalPassageIds = () => {
  if (!fs.existsSync(sourceManifestPath)) {
    throw new Error(`Missing source manifest: ${sourceManifestPath}`);
  }
  const manifest = JSON.parse(fs.readFileSync(sourceManifestPath, 'utf8'));
  const ids = manifest.articles?.map((article) => article.id).filter(Boolean);
  if (!Array.isArray(ids) || ids.length !== manifest.expectedArticles) {
    throw new Error('Source manifest has no complete canonical article-id list');
  }
  return new Set(ids);
};

const main = async () => {
  const args = parseArgs(process.argv.slice(2));
  const batch = BATCHES[args.batch];
  if (!batch) throw new Error(`Unknown batch ${args.batch}. Use ${Object.keys(BATCHES).join(', ')}`);

  await assertRemoteHealthy(args.baseUrl);
  console.log(`Batch ${args.batch}: ${batch.label}`);
  console.log(`provider=${args.provider} baseUrl=${args.baseUrl}`);

  if (!fs.existsSync(args.input)) {
    const command = args.input === cleanPassagesRoot
      ? 'node scripts/build-clean-tpo-passages.mjs'
      : 'npm run extract:tpo';
    throw new Error(`Missing passages dir: ${args.input}. Run: ${command}`);
  }

  const cmd = [
    'run',
    'analyze:md-sections',
    '--',
    '--input',
    args.input,
    '--output',
    outputRoot,
    '--provider',
    args.provider,
    '--base-url',
    args.baseUrl,
    '--timeout-ms',
    String(args.timeoutMs),
    '--chunk-sentences',
    String(args.chunkSentences),
    '--checkpoint',
    '--no-fallback'
  ];
  if (args.model) cmd.push('--model', args.model);
  if (batch.only) cmd.push('--only', batch.only);
  if (args.force) cmd.push('--force');
  if (args.dryRun) cmd.push('--dry-run');

  // For filter-based batches, temporarily copy matching md into a batch folder
  let inputPath = args.input;
  if (batch.filter) {
    // Keep derived input outside the clean source tree. This prevents a restart
    // from treating stale Finder/copied " 2" files as additional articles.
    const batchDir = path.join(cwd, '.tmp_model_compare', 'p920-batches', args.batch);
    fs.rmSync(batchDir, { recursive: true, force: true });
    fs.mkdirSync(batchDir, { recursive: true });
    const canonicalIds = loadCanonicalPassageIds();
    const files = fs.readdirSync(args.input)
      .filter((name) => name.endsWith('.md'))
      .filter((name) => canonicalIds.has(path.basename(name, '.md')))
      .filter((name) => batch.filter.test(name))
      .sort((a, b) => a.localeCompare(b));
    const selectedFiles = args.ids.length
      ? files.filter((name) => args.ids.includes(path.basename(name, '.md')))
      : files;
    if (args.ids.length && selectedFiles.length !== args.ids.length) {
      const selectedIds = new Set(selectedFiles.map((name) => path.basename(name, '.md')));
      throw new Error(`Requested canonical ids missing from ${args.batch}: ${args.ids.filter((id) => !selectedIds.has(id)).join(', ')}`);
    }
    if (selectedFiles.length === 0) throw new Error(`No passage files matched batch ${args.batch}`);
    if (!args.ids.length && selectedFiles.length !== batch.expectedCount) {
      throw new Error(`Batch ${args.batch} expected ${batch.expectedCount} canonical files, found ${selectedFiles.length}`);
    }
    for (const file of selectedFiles) {
      fs.copyFileSync(path.join(args.input, file), path.join(batchDir, file));
    }
    inputPath = batchDir;
    // replace --input value
    const idx = cmd.indexOf('--input');
    cmd[idx + 1] = inputPath;
    console.log(`Batch files: ${selectedFiles.length}`);
  }

  console.log(`$ npm ${cmd.join(' ')}`);
  const result = spawnSync('npm', cmd, { cwd, stdio: 'inherit', env: process.env });
  process.exit(result.status ?? 1);
};

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
