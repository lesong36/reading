import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const slice = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
const dictionaryEntry = { lemma: 'available', partOfSpeech: 'adjective', meaning: '可获得的', pronunciation: '', note: '' };

function harness({ privateKey = '', cloudKey = '', baseUrl = 'https://api.deepseek.com', content = JSON.stringify(dictionaryEntry), error } = {}) {
  const requests = [];
  const context = vm.createContext({
    LOCAL_PRIVATE_CONFIG: { deepseekApiKey: privateKey },
    cloudApiKey: cloudKey,
    cloudBaseUrl: baseUrl,
    AbortController, setTimeout, clearTimeout,
    parseAiJsonOrThrow: JSON.parse,
    decodeOpenAICompatStream: async () => 'streamed reply',
    fetch: async (url, options) => {
      requests.push({ url, ...options, body: JSON.parse(options.body) });
      if (error) throw error;
      return { ok: true, json: async () => ({ choices: [{ message: { content } }], usage: { total_tokens: 90 } }) };
    }
  });
  vm.runInContext([
    slice('    const DEEPSEEK_BASE_URL', '    const OLLAMA_PRESETS'),
    slice('    const DICTIONARY_PARTS_OF_SPEECH', '    const formatDictionaryMeaning'),
    slice('    const sanitizeApiCredential', '    const LOCAL_DATA_FILE_NAME'),
    slice('    const fetchOpenAICompatResponse', '    // 长文解析可能持续'),
    slice('    const fetchDictionaryJson', '    const saveAiLog'),
    slice('      const lookupContextualDictionary', '      const openContextualDictionary'),
    'globalThis.lookup = lookupContextualDictionary; globalThis.normalizeModel = normalizeCloudModel; globalThis.chat = fetchOpenAICompatResponse;'
  ].join('\n'), context);
  return { context, requests };
}

test('lookup calls DeepSeek directly with thinking disabled and keeps validated context meaning', async () => {
  const { context, requests } = harness({ privateKey: 'test-private-key' });
  const result = await context.lookup('available', 'Groundwater is available in many regions.');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://api.deepseek.com/chat/completions');
  assert.equal(requests[0].body.model, 'deepseek-flash');
  assert.equal(requests[0].body.thinking.type, 'disabled');
  assert.equal(requests[0].body.response_format.type, 'json_object');
  assert.equal(requests[0].body.chat_template_kwargs, undefined);
  assert.match(requests[0].body.messages[1].content, /Groundwater is available/);
  assert.equal(result.meaning, '可获得的');
  assert.equal(result.partOfSpeech, '形容词');
  assert.equal(result.usage.totalTokens, 90);
});

test('lookup accepts the saved key for an official DeepSeek endpoint', async () => {
  const { context, requests } = harness({ cloudKey: 'test-settings-key', baseUrl: 'https://api.deepseek.com/v1' });
  await context.lookup('available', 'It is available.');
  assert.equal(requests[0].headers.Authorization, 'Bearer test-settings-key');
});

test('missing DeepSeek key fails immediately and does not send another provider key', async () => {
  const { context, requests } = harness({ cloudKey: 'other-provider-key', baseUrl: 'https://api.deepseek.com.other.example/v1' });
  await assert.rejects(context.lookup('available', 'It is available.'), /未配置 API Key/);
  assert.equal(requests.length, 0);
});

test('timeout reports a DeepSeek error without falling back to P920', async () => {
  const { context, requests } = harness({ privateKey: 'test-key', error: Object.assign(new Error('aborted'), { name: 'AbortError' }) });
  await assert.rejects(context.lookup('available', 'It is available.'), /deepseek-flash.*请求超时/);
  assert.equal(requests.length, 1);
});

test('invalid model meanings still fail validation', async () => {
  const { context } = harness({ privateKey: 'test-key', content: JSON.stringify({ ...dictionaryEntry, meaning: '未知' }) });
  await assert.rejects(context.lookup('available', 'It is available.'), /泛化释义/);
});

test('stored DeepSeek model names migrate while other endpoints keep their models', () => {
  const { context } = harness();
  assert.equal(context.normalizeModel('old-model', 'https://api.deepseek.com/v1'), 'deepseek-flash');
  assert.equal(context.normalizeModel('custom-model', 'https://another.example/v1'), 'custom-model');
});

test('batch DeepSeek model resolution uses Flash without fetching a model list', async () => {
  const batch = fs.readFileSync(new URL('../scripts/analyze-md-sections.mjs', import.meta.url), 'utf8');
  const start = batch.indexOf('const resolveModelName = async');
  const context = vm.createContext({ isDeepSeekEndpoint: url => /^https:\/\/api\.deepseek\.com(?:\/|$)/.test(url), fetch: () => { throw new Error('Unexpected network call'); } });
  vm.runInContext(batch.slice(start, batch.indexOf('const slugify', start)) + '\nglobalThis.resolve = resolveModelName;', context);
  assert.equal(await context.resolve({ provider: 'openai', baseUrl: 'https://api.deepseek.com', model: 'retired-model' }), 'deepseek-flash');
  assert.equal(await context.resolve({ provider: 'openai', baseUrl: 'http://100.121.25.47:8090/v1', model: 'qwen-model' }), 'qwen-model');
});


test('general AI requests use Flash and the private DeepSeek key when settings key is empty', async () => {
  const { context, requests } = harness({ privateKey: 'test-private-key' });
  assert.equal(await context.chat({ userPrompt: 'Explain this sentence.', systemPrompt: 'You are a teacher.', model: 'retired-model' }), 'streamed reply');
  assert.equal(requests[0].body.model, 'deepseek-flash');
  assert.equal(requests[0].body.thinking.type, 'disabled');
  assert.equal(requests[0].headers.Authorization, 'Bearer test-private-key');
});

test('general AI requests never send the private DeepSeek key to another endpoint', async () => {
  const { context, requests } = harness({ privateKey: 'test-private-key' });
  await assert.rejects(context.chat({ userPrompt: 'Explain.', systemPrompt: 'Teacher.', baseUrl: 'https://another.example/v1', model: 'other-model' }), /请先填写云端模型 API Key/);
  assert.equal(requests.length, 0);
});
