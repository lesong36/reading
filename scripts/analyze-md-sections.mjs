import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const cwd = process.cwd();
const defaultInput = '/Users/coty/Desktop/四上预习/英语/阅读_副本';
const defaultOutput = path.resolve(cwd, 'data/generated-reader-json');

const ANALYSIS_SYSTEM_PROMPT = `你是一款专业的英文长难句解析工具。请将用户提供的英文文本逐句、逐字进行深度解析，并严格按照 JSON 格式返回。
【绝对警告】：绝不允许缩写、总结、省略或修改任何原句内容。无论是带有序号的列表、短句还是长句，你必须按顺序解析用户输入的每一个句子，确保文章完整无缺！如果用户输入包含序号（如 1. 2.），请将其作为普通文本处理，确保正常解析。

要求：
1. 必须切分出正确的段落号 para 和句子 ID id。
2. 将整句拆分为片段 segments，片段拼接后必须与原句 text 完全一致（包括空格和标点）。
2.1 对于 segments 的 label，必须尽量使用统一、稳定的中文标签，避免同类结构反复换叫法：
   - subject -> 主语
   - verb -> 谓语；如果是 be / seem / become 等系动词，也可以写 系动词
   - object -> 宾语
   - object-complement -> 宾语补足语
   - predicative -> 表语
   - conjunction -> 连接词
   - adverbial -> 状语
   - modifier -> 不要机械统称为修饰语。请根据它实际修饰的对象细分：定语 / 同位语 / 补足语 / 补充说明 / 状语等。
   - clause-* -> 从句核心，专门用于从属子句。
   - coord-* -> 并列主句，专门用于并列连词 for/and/nor/but/or/yet/so 引导的第二个独立主句。
   不要输出像“同位语/定语”“修饰语”“附加成分”这类混合或过泛标签。
2.2 【结构正确性硬约束】绝不允许输出裸类型 clause、main clause、other、空 type 或未列出的 type。
   - 不能把完整主句或分句整体塞进一个 segment；每个独立分句都必须至少拆出主语和谓语。
   - 例如：“Most people consider the landscape to be unchanging, but Earth is a dynamic body.” 必须拆为
     “Most people” subject，“consider” verb，“the landscape” object，“to be unchanging” 补足语，“but” conjunction，
     “Earth” coord-subject，“is” coord-verb，“a dynamic body” coord-predicative。
   - clause-* 只能用于确有从属关系的从句内部成分，不能用于主句、并列句、主语片段或谓语片段。
   - 定语从句/状语从句可分别使用 clause-*；非谓语、同位语、补足语和状语不得伪装成从句。
3. analysis 字段必须使用中文 Markdown 深度剖析，至少包含：
   ### 【主干结构】
   ### 【主谓一致】
   ### 【动词时态与原形】
   ### 【从句剖析】若有
   ### 【代词指代】若有
   ### 【非谓语动词】若有
4. 每个句子都必须输出 teachingFocus 对象，服务老师直接给孩子讲：
   - mainQuestion
   - grammarQuestion
   - modifierQuestion
   - relationshipQuestion
   - commonMistake
   - thinkingPath：长度 2-4 的字符串数组
   - encouragement
5. teachingFocus 语气要温暖、清晰、适合低龄孩子；可以使用火车、积木、侦探、地图、衣服、骨架等类比。
6. 额外输出文章级 glossary 数组，但必须宁缺毋滥：只有满足以下至少一项的词条才能收录：
   - 生僻词：对目标读者确有学习价值的低频词；不能只因词长、看起来正式或属于普通学术词就收录。
   - 语境特殊义：在本文中具有不同于常见字面义的特定含义，包括真正的专业术语、学科概念和必要缩写。
   - 专有名词：人名、地名、组织、作品名、物种名，以及其他必须识别的特定名称。
   普通高频词、常见学术词、按字面即可理解的普通搭配，以及只因“放在本文中”才出现的普通短语，一律不要收录。词条可以为 0 条，不得为了凑数补充。translation 必须只给出最符合本文语境的简洁中文释义，不能机械直译或延伸成百科说明；note 仅在语境特殊义或名称背景确有必要时填写。

输出必须符合以下 JSON 格式，只输出 JSON，不要 Markdown 代码块，不要解释：
{
  "glossary": [
    {
      "term": "英文词条",
      "translation": "中文翻译",
      "kind": "rare_word | context_term | proper_noun | acronym",
      "note": "本文语境说明",
      "aliases": ["可选别名"]
    }
  ],
  "articleData": [
    {
      "id": "s1",
      "para": 1,
      "text": "完整英文原句",
      "translation": "精准中文翻译",
      "grammarFocus": "核心语法点",
      "pronounRef": "代词指代简要解释",
      "logicConnector": "逻辑连词解释",
      "sentenceCoach": {
        "summary": "可选：一句像老师带读的简短提示",
        "keyHint": "可选：最值得孩子先注意的一个提醒"
      },
      "teachingFocus": {
        "mainQuestion": "先抓主干时，老师讲给孩子听的一句话",
        "grammarQuestion": "看核心语法时，老师讲给孩子听的一句话",
        "modifierQuestion": "拆修饰语和从句时，老师讲给孩子听的一句话",
        "relationshipQuestion": "理顺句子关系时，老师讲给孩子听的一句话",
        "commonMistake": "这句最容易混淆的地方，用孩子听得懂的话解释",
        "thinkingPath": ["第一个观察动作", "第二个观察动作"],
        "encouragement": "一句伙伴式鼓励"
      },
      "analysis": "中文深度结构剖析，使用 Markdown 排版。",
      "segments": [
        {
          "text": "切分后的片段，必须包含周围标点及空格",
          "type": "subject | verb | object | predicative | object-complement | clause-subject | clause-verb | clause-object | clause-predicative | coord-subject | coord-verb | coord-object | coord-predicative | conjunction | modifier | adverbial",
          "label": "中文语法标签"
        }
      ]
    }
  ]
}`;

const parseArgs = (argv) => {
  const args = {
    input: defaultInput,
    output: defaultOutput,
    // openai = OpenAI-compatible (llama.cpp / vLLM on P920:8090); ollama = legacy /api/chat
    provider: process.env.LLM_PROVIDER || 'openai',
    baseUrl: process.env.LLM_BASE_URL || process.env.OLLAMA_BASE_URL || 'http://100.121.25.47:8090/v1',
    model: process.env.LLM_MODEL || process.env.OLLAMA_MODEL || '',
    apiKey: process.env.LLM_API_KEY || '',
    headingLevel: 'auto',
    dryRun: false,
    force: false,
    fallback: true,
    only: '',
    limit: 0,
    chunkSentences: 0,
    chunkRetrySizes: '4,2,1',
    timeoutMs: 5 * 60 * 1000,
    segmentFallback: false,
    checkpoint: false,
    qualityRetries: 1,
    stopAtQuestions: false
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];
    if (arg === '--input') args.input = next();
    else if (arg === '--output') args.output = next();
    else if (arg === '--provider') args.provider = next();
    else if (arg === '--base-url') args.baseUrl = next();
    else if (arg === '--model') args.model = next();
    else if (arg === '--api-key') args.apiKey = next();
    else if (arg === '--heading-level') args.headingLevel = next();
    else if (arg === '--only') args.only = next();
    else if (arg === '--limit') args.limit = Number(next() || 0);
    else if (arg === '--chunk-sentences') args.chunkSentences = Number(next() || 0);
    else if (arg === '--chunk-retry-sizes') args.chunkRetrySizes = next();
    else if (arg === '--timeout-ms') args.timeoutMs = Number(next() || args.timeoutMs);
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--force') args.force = true;
    else if (arg === '--no-fallback') args.fallback = false;
    else if (arg === '--segment-fallback') args.segmentFallback = true;
    else if (arg === '--checkpoint') args.checkpoint = true;
    else if (arg === '--quality-retries') args.qualityRetries = Number(next() || 0);
    else if (arg === '--stop-at-questions') args.stopAtQuestions = true;
    else if (arg === '--help') {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!['openai', 'ollama'].includes(args.provider)) {
    throw new Error(`Unsupported --provider ${args.provider} (use openai|ollama)`);
  }

  return args;
};

const printHelp = () => {
  console.log(`Usage:
  npm run analyze:md-sections -- --input "/path/to/md-or-folder" [options]

Options:
  --output <dir>         Output directory. Default: data/generated-reader-json
  --provider <name>      openai (default, llama.cpp/vLLM) or ollama
  --base-url <url>       Default openai: http://100.121.25.47:8090/v1
  --model <name>         Model id; if empty, auto-pick an available Qwen model from /v1/models or /api/tags
  --api-key <key>        API key for an authenticated OpenAI-compatible endpoint (never logged)
  --heading-level <n>    Heading level to split on, or auto. Default: auto
  --only <text>          Only process files/sections whose title contains text.
  --limit <n>            Process at most n sections.
  --chunk-sentences <n>  Keep the same analysis protocol, but request long articles in contiguous groups of n sentences.
  --chunk-retry-sizes <n,...>  On any rejected chunk, redo the whole section with smaller contiguous groups (default: 4,2,1).
  --dry-run              Print split plan only; do not call model.
  --force                Re-run existing section outputs.
  --no-fallback          Fail sections instead of writing local fallback JSON when model output is invalid.
  --segment-fallback     Preserve model translation/analysis when only sentence text or segment roles fail; replace just those sentence segments with a protected full-sentence segment.
  --checkpoint           Persist completed sentence chunks and resume safely after an interrupted model process.
  --quality-retries <n>  Re-request an invalid chunk from the same model before splitting it (default: 1).
  --stop-at-questions    Keep only the article body before the first numbered quiz question.
`);
};

const normalizeBaseUrl = (baseUrl) => String(baseUrl || '').replace(/\/+$/, '');

const isDeepSeekEndpoint = (baseUrl) => /(^|\/\/)api\.deepseek\.com(?:\/|$)/i.test(normalizeBaseUrl(baseUrl));

// Keep credentials out of CLI output and source control. This only reads the
// local browser config when the caller intentionally selects DeepSeek.
const loadDeepSeekApiKey = () => {
  const configPath = path.join(process.cwd(), 'local-config.js');
  if (!fs.existsSync(configPath)) return '';
  const source = fs.readFileSync(configPath, 'utf8');
  const match = source.match(/\bdeepseekApiKey\s*:\s*(['\"])(.*?)\1/s);
  return match?.[2]?.trim() || '';
};

// P920 is upgraded in place. Prefer its current Qwen-family model instead of
// pinning a retired version/parameter count, while retaining a safe fallback
// for other OpenAI-compatible endpoints.
const isQwenModelName = (name = '') => /qwen/i.test(name);

const resolveModelName = async ({ provider, baseUrl, model, apiKey }) => {
  if (model) return model;
  const root = normalizeBaseUrl(baseUrl);
  if (provider === 'openai') {
    const response = await fetch(`${root}/models`, {
      headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : undefined
    });
    if (!response.ok) throw new Error(`Failed to list models: HTTP ${response.status}`);
    const payload = await response.json();
    const names = [
      ...(payload?.data || []).map((item) => item.id || item.name),
      ...(payload?.models || []).map((item) => item.name || item.model || item.id)
    ].filter(Boolean);
    const hit = names.find(isQwenModelName) || names[0];
    if (!hit) throw new Error(`No models found at ${root}/models`);
    return hit;
  }

  const response = await fetch(`${root}/api/tags`);
  if (!response.ok) throw new Error(`Failed to list ollama tags: HTTP ${response.status}`);
  const payload = await response.json();
  const names = (payload?.models || []).map((item) => item.name).filter(Boolean);
  const hit = names.find(isQwenModelName) || names[0];
  if (!hit) throw new Error(`No models found at ${root}/api/tags`);
  return hit;
};

const slugify = (value) =>
  String(value || '')
    .normalize('NFKD')
    .replace(/[^\w\u4e00-\u9fff]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'section';

const collectMarkdownFiles = (inputPath) => {
  const resolved = path.resolve(inputPath);
  const stat = fs.statSync(resolved);
  if (stat.isFile()) return [resolved];
  return fs.readdirSync(resolved)
    .filter(name => name.toLowerCase().endsWith('.md'))
    .sort((left, right) => left.localeCompare(right, 'zh-Hans-CN'))
    .map(name => path.join(resolved, name));
};

const chooseHeadingLevel = (headings, requested) => {
  if (requested !== 'auto') return Number(requested);
  const hasLevelTwo = headings.some(heading => heading.level === 2);
  return hasLevelTwo ? 2 : 1;
};

const cleanSectionText = (lines) =>
  lines
    .filter(line => !/^\s*#{1,6}\s+/.test(line))
    .filter(line => !/^\s*---+\s*$/.test(line))
    .filter(line => !/^\s*Reading Future Discover \d+ Transcripts\s*$/i.test(line))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

const splitMarkdownSections = (filePath, requestedHeadingLevel, stopAtQuestions = false) => {
  const text = fs.readFileSync(filePath, 'utf8').replace(/\r\n/g, '\n');
  const lines = text.split('\n');
  const headings = lines
    .map((line, index) => {
      const match = line.match(/^(#{1,6})\s+(.+?)\s*$/);
      return match ? { index, level: match[1].length, title: match[2].trim() } : null;
    })
    .filter(Boolean);

  const splitLevel = chooseHeadingLevel(headings, requestedHeadingLevel);
  const sections = [];
  const parentByLevel = {};

  for (let i = 0; i < headings.length; i += 1) {
    const heading = headings[i];
    parentByLevel[heading.level] = heading.title;
    Object.keys(parentByLevel)
      .map(Number)
      .filter(level => level > heading.level)
      .forEach(level => delete parentByLevel[level]);

    if (heading.level !== splitLevel) continue;

    const next = headings.slice(i + 1).find(item => item.level <= splitLevel);
    const endIndex = next ? next.index : lines.length;
    const rawLines = lines.slice(heading.index + 1, endIndex);
    let body = cleanSectionText(rawLines);
    if (stopAtQuestions) body = body.replace(/^\d+\.\s+[\s\S]*$/m, '').trim();
    if (!body) continue;

    const parentTitle = splitLevel > 1 ? parentByLevel[splitLevel - 1] : '';
    const fullTitle = parentTitle ? `${parentTitle} / ${heading.title}` : heading.title;
    sections.push({
      sourceFile: filePath,
      sourceName: path.basename(filePath),
      sectionTitle: fullTitle,
      headingTitle: heading.title,
      headingLevel: splitLevel,
      text: body
    });
  }

  return sections;
};

const extractJsonCandidate = (text) => {
  const trimmed = String(text || '').trim()
    .replace(/^```(?:json)?\s*/i, '')
    .replace(/\s*```$/i, '')
    .trim();

  const start = trimmed.indexOf('{');
  const end = trimmed.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return trimmed;
  return trimmed.slice(start, end + 1);
};

const removeTrailingCommasOutsideStrings = (value) => {
  let output = '';
  let inString = false;
  let escaped = false;

  for (let index = 0; index < value.length; index += 1) {
    const char = value[index];

    if (inString) {
      output += char;
      if (escaped) {
        escaped = false;
      } else if (char === '\\') {
        escaped = true;
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }

    if (char === '"') {
      inString = true;
      output += char;
      continue;
    }

    if (char === ',') {
      let lookahead = index + 1;
      while (/\s/.test(value[lookahead] || '')) lookahead += 1;
      if (value[lookahead] === '}' || value[lookahead] === ']') continue;
    }

    output += char;
  }

  return output;
};

const parseModelJson = (content) => {
  const candidate = extractJsonCandidate(content);
  const attempts = [
    candidate,
    removeTrailingCommasOutsideStrings(candidate)
  ];
  let lastError;

  for (const attempt of attempts) {
    try {
      return JSON.parse(attempt);
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError;
};

const makeParseError = ({ message, rawContent, repairContent, originalError }) => {
  const error = new Error(message);
  error.rawContent = rawContent;
  error.repairContent = repairContent;
  error.originalError = originalError;
  return error;
};

const requestChat = async ({ provider, baseUrl, body, timeoutMs, apiKey }) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const root = normalizeBaseUrl(baseUrl);
  const url = provider === 'openai' ? `${root}/chat/completions` : `${root}/api/chat`;
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}) },
    signal: controller.signal,
    body: JSON.stringify(body)
  }).finally(() => clearTimeout(timeout));

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`${provider} HTTP ${response.status}${detail ? `: ${detail}` : ''}`);
  }

  const payload = await response.json();
  if (provider === 'openai') {
    const message = payload?.choices?.[0]?.message || {};
    return message.content || message.reasoning_content || '';
  }
  return payload?.message?.content || payload?.response || '';
};

// 20k preserves full sentence-level analysis while preventing one malformed
// response from monopolising the P920 queue for an unbounded time.
const buildChatBody = ({ provider, model, messages, temperature = 0.1, maxTokens = 20000 }) => {
  if (provider === 'openai') {
    return {
      model,
      stream: false,
      temperature,
      max_tokens: maxTokens,
      // Both P920 llama.cpp and the hosted OpenAI-compatible endpoint support
      // JSON-object mode. The legacy schema/prompt remains authoritative; this
      // only prevents empty prose and truncated non-JSON response envelopes.
      response_format: { type: 'json_object' },
      // llama.cpp needs this switch; hosted OpenAI-compatible APIs such as
      // DeepSeek reject provider-specific chat-template options.
      ...(/^deepseek-/i.test(model)
        ? { thinking: { type: 'disabled' } }
        : { chat_template_kwargs: { enable_thinking: false } }),
      messages
    };
  }
  return {
    model,
    stream: false,
    think: false,
    options: {
      temperature,
      num_predict: maxTokens,
      num_ctx: 32768
    },
    messages
  };
};

const callModelJson = async ({ provider, baseUrl, model, section, timeoutMs, apiKey }) => {
  // Do not include the whole article beside a chunk. The historic prompt treats
  // every user-supplied sentence as output work, so duplicate source material
  // makes the model emit the article as well as the target chunk. A continuous
  // 8-sentence slice preserves the original analysis contract without inviting
  // duplicate output or JSON truncation.
  const sentenceContract = (section.requiredSentences || [])
    .map((sentence, index) => `${index + 1}. ${sentence.text}`)
    .join('\n');
  const userContent = `【章节标题】${section.sectionTitle}\n\n【章节正文】\n${section.text}\n\n【本批不可变句界】\n本批 articleData 必须且只能输出以下 ${section.requiredSentences?.length || '全部'} 条，顺序和 text 必须逐字符一致。冒号、分号、破折号、缩写（如 St. / U.S.）均不构成新的 articleData；它们仍属于清单中的同一原句。\n${sentenceContract}`;
  const content = await requestChat({
    provider,
    baseUrl,
    timeoutMs,
    apiKey,
    body: buildChatBody({
      provider,
      model,
      // Deterministic decoding is important when a rejected chunk must be
      // retried with the identical historical analysis protocol.
      temperature: 0,
      messages: [
        { role: 'system', content: ANALYSIS_SYSTEM_PROMPT },
        { role: 'user', content: userContent }
      ]
    })
  });

  try {
    return parseModelJson(content);
  } catch (parseError) {
    const repaired = await requestChat({
      provider,
      baseUrl,
      timeoutMs,
      apiKey,
      body: buildChatBody({
        provider,
        model,
        temperature: 0,
        messages: [
          {
            role: 'system',
            content: '你是 JSON 修复器。只返回一个可被 JSON.parse 解析的 JSON 对象，不要 Markdown，不要解释。保留原有字段和英文原句内容；只修复引号、逗号、转义、括号等 JSON 语法问题。'
          },
          {
            role: 'user',
            content: `下面这段模型输出不是合法 JSON。\n解析错误：${parseError.message}\n\n请修复为合法 JSON：\n${extractJsonCandidate(content)}`
          }
        ]
      })
    });

    try {
      return parseModelJson(repaired);
    } catch (repairError) {
      throw makeParseError({
        message: `${repairError.message} (repair retry also failed; original parse error: ${parseError.message})`,
        rawContent: content,
        repairContent: repaired,
        originalError: parseError
      });
    }
  }
};

const repairGrammarRoles = async ({ provider, baseUrl, model, parsed, qualityErrors, timeoutMs, apiKey }) => {
  const allowed = 'subject, verb, object, predicative, object-complement, clause-subject, clause-verb, clause-object, clause-predicative, coord-subject, coord-verb, coord-object, coord-predicative, conjunction, modifier, adverbial';
  const invalidSentenceIds = new Set(qualityErrors.map(item => item.sentenceId));
  const sentenceRepairs = (parsed.articleData || [])
    .filter(sentence => invalidSentenceIds.has(sentence.id))
    .map(sentence => ({
      id: sentence.id,
      text: sentence.text,
      segments: (sentence.segments || []).map(segment => ({ text: segment.text, type: segment.type }))
    }));

  if (sentenceRepairs.length === 0) {
    throw new Error('Grammar-role repair could not find the invalid sentence(s) in model output.');
  }

  const content = await requestChat({
    provider,
    baseUrl,
    timeoutMs,
    apiKey,
    body: buildChatBody({
      provider,
      model,
      temperature: 0,
      maxTokens: 8000,
      messages: [
        { role: 'system', content: `You are an English syntax JSON corrector. Return valid JSON only in this exact shape: {"sentenceRepairs":[{"id":"...","segments":[{"text":"...","type":"..."}]}]}. Return exactly one repair for every supplied id. Preserve every segment.text unless changing a boundary is essential; segments must concatenate exactly to the supplied sentence text. Repair only segment types and necessary boundaries. Allowed types only: ${allowed}. Never output clause, main clause, other, empty types, or unlisted types. Split every independent clause into subject and verb; use coord-* for coordinated independent clauses; use clause-* only for subordinate clauses.` },
        { role: 'user', content: `Fix these invalid segment roles: ${qualityErrors.map(item => `${item.sentenceId}:${item.type || '(empty)'}`).join(', ')}.\n${JSON.stringify(sentenceRepairs)}` }
      ]
    })
  });
  const repairPayload = parseModelJson(content);
  const repairs = Array.isArray(repairPayload?.sentenceRepairs) ? repairPayload.sentenceRepairs : [];
  const repairsById = new Map(repairs.map(repair => [repair?.id, repair]));
  const missing = sentenceRepairs.filter(sentence => !repairsById.has(sentence.id)).map(sentence => sentence.id);
  if (missing.length > 0) {
    throw new Error(`Grammar-role repair omitted sentence(s): ${missing.join(', ')}`);
  }

  return {
    ...parsed,
    articleData: (parsed.articleData || []).map(sentence => {
      const repair = repairsById.get(sentence.id);
      return repair ? { ...sentence, segments: repair.segments } : sentence;
    })
  };
};

const alignSegmentsToText = (sentence) => {
  if (!Array.isArray(sentence.segments) || sentence.segments.length === 0 || typeof sentence.text !== 'string') {
    return sentence.segments;
  }

  const joined = sentence.segments.map(segment => segment.text || '').join('');
  if (joined === sentence.text) return sentence.segments;
  if (joined.replace(/\s+/g, '') !== sentence.text.replace(/\s+/g, '')) return sentence.segments;

  let cursor = 0;
  return sentence.segments.map((segment, segmentIndex) => {
    const nonSpaceTarget = String(segment.text || '').replace(/\s+/g, '').length;
    const start = cursor;
    let seen = 0;

    while (cursor < sentence.text.length && seen < nonSpaceTarget) {
      if (!/\s/.test(sentence.text[cursor])) seen += 1;
      cursor += 1;
    }

    if (segmentIndex < sentence.segments.length - 1) {
      while (cursor < sentence.text.length && /\s/.test(sentence.text[cursor])) cursor += 1;
    } else {
      cursor = sentence.text.length;
    }

    return {
      ...segment,
      text: sentence.text.slice(start, cursor)
    };
  });
};

const normalizeSentenceShape = (sentence) => {
  sentence.pronounRef ??= '无';
  sentence.logicConnector ??= '无';
  sentence.sentenceCoach ??= {};
  sentence.sentenceCoach.summary ??= '先抓主干，再看补充信息。';
  sentence.sentenceCoach.keyHint ??= '注意主语、动词和后面的核心内容。';
  sentence.teachingFocus ??= {};
  sentence.teachingFocus.mainQuestion ??= '这句话主要在说谁或什么？';
  sentence.teachingFocus.grammarQuestion ??= '先找主语和动词，再看后面的核心内容。';
  sentence.teachingFocus.modifierQuestion ??= '注意时间、地点、方式和补充说明。';
  sentence.teachingFocus.relationshipQuestion ??= '把主干和修饰语连起来，就能读懂整句话。';
  sentence.teachingFocus.commonMistake ??= '不要只按中文顺序猜，要先找英文句子的主干。';
  sentence.teachingFocus.encouragement ??= '很好，按步骤拆句子就会越来越稳。';
  if (!Array.isArray(sentence.teachingFocus.thinkingPath) || sentence.teachingFocus.thinkingPath.length < 2) {
    sentence.teachingFocus.thinkingPath = ['找到主语', '找到动词', '看补充说明'];
  }
  sentence.analysis ||= [
    '### 【主干结构】',
    '先抓句子的主语和动词，再看后面的补充信息。',
    '',
    '### 【主谓一致】',
    '根据主语单复数判断谓语形式。',
    '',
    '### 【动词时态与原形】',
    '根据原句动词形式判断时态。',
    '',
    '### 【从句剖析】',
    '无明显从句或需结合连接词进一步判断。',
    '',
    '### 【代词指代】',
    sentence.pronounRef,
    '',
    '### 【非谓语动词】',
    '如有 to do 或 -ing 结构，需要判断其作用。'
  ].join('\n');
  sentence.segments = alignSegmentsToText(sentence);
  return sentence;
};

const normalizeGlossary = (glossary = []) => {
  if (!Array.isArray(glossary)) return [];
  const byKey = new Map();
  glossary.forEach((raw) => {
    const term = String(raw?.term || raw?.word || '').trim();
    if (!term) return;
    const key = term.toLowerCase();
    const entry = {
      term,
      translation: String(raw?.translation || raw?.meaning || '').trim(),
      kind: String(raw?.kind || raw?.type || 'term').trim() || 'term',
      note: String(raw?.note || raw?.context || '').trim(),
      aliases: Array.isArray(raw?.aliases)
        ? raw.aliases.map(alias => String(alias || '').trim()).filter(Boolean)
        : []
    };
    if (!byKey.has(key) || (entry.translation && !byKey.get(key).translation)) {
      byKey.set(key, entry);
    }
  });
  return Array.from(byKey.values()).sort((a, b) => b.term.length - a.term.length || a.term.localeCompare(b.term));
};

const normalizeArticleData = (parsed) => {
  if (!Array.isArray(parsed?.articleData) || parsed.articleData.length === 0) {
    throw new Error('Model output does not contain a non-empty articleData array.');
  }

  return parsed.articleData.map((sentence, index) => normalizeSentenceShape({
    ...sentence,
    id: sentence.id || `s${index + 1}`,
    para: Number(sentence.para || 1),
    segments: Array.isArray(sentence.segments) ? sentence.segments : []
  }));
};

const ABBREVIATION_WORDS = new Set([
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'mt', 'vs', 'etc', 'e.g', 'i.e',
  'fig', 'eq', 'no', 'vol', 'inc', 'ltd', 'co', 'corp', 'jan', 'feb', 'mar', 'apr',
  'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec'
]);

const isSentenceBoundary = (line, index) => {
  const char = line[index];
  if (/[!?。！？]/.test(char)) return true;
  if (char !== '.') return false;

  const before = line.slice(0, index + 1);
  const after = line.slice(index + 1);
  const nextVisible = after.match(/^\s*([^\s"'”’)]?)/)?.[1] || '';
  if (/\d$/.test(line.slice(0, index)) && /^\d/.test(after)) return false;
  // Do not split an initialism at its first period: B.C., A.D., U.S., etc.
  // The existing backward check only sees `B.` at this point, so it cannot
  // recognize the complete abbreviation until it is already too late.
  if (/^[A-Za-z]\./.test(after)) return false;

  // Abbreviations such as St. Denis, Dr. Smith, U.S. policy and e.g. are not
  // independent sentences. Only suppress them when more text follows.
  if (nextVisible) {
    const word = (before.match(/([A-Za-z]+)\.$/) || [])[1]?.toLowerCase();
    if (word && ABBREVIATION_WORDS.has(word)) return false;
    if (/(?:\b[A-Za-z]\.){2,}$/.test(before)) return false;
    if (/\b(?:e\.g|i\.e)\.$/i.test(before)) return false;
  }
  return true;
};

const splitParagraphSentences = (paragraph) => {
  const lines = paragraph
    .split('\n')
    .map(line => line.trim())
    // Some converted OG source files contain a standalone lowercase `n`
    // between the heading and body. It is a conversion artefact, never a
    // sentence, and forcing the model to return it shifts every later id.
    .filter(line => line && line !== 'n');
  const sentences = [];

  for (const line of lines) {
    let start = 0;
    for (let index = 0; index < line.length; index += 1) {
      const char = line[index];
      if (!isSentenceBoundary(line, index)) continue;

      let end = index + 1;
      while (/["'”’)]/.test(line[end] || '')) end += 1;
      const sentence = line.slice(start, end).trim();
      if (sentence) sentences.push(sentence);
      start = end;
      while (line[start] === ' ') start += 1;
      index = start - 1;
    }

    const rest = line.slice(start).trim();
    if (rest) sentences.push(rest);
  }

  return sentences;
};

const collectSourceSentences = (section) => {
  const records = [];
  section.text
    .split(/\n\s*\n/)
    .map(paragraph => paragraph.trim())
    .filter(Boolean)
    .forEach((paragraph, paragraphIndex) => {
      splitParagraphSentences(paragraph).forEach((text) => {
        records.push({
          id: `s${records.length + 1}`,
          para: paragraphIndex + 1,
          text
        });
      });
    });
  if (records.length === 0) throw new Error(`No sentences found in ${section.sectionTitle}.`);
  return records;
};

const chunkSectionBySentences = (section, chunkSentences) => {
  const expected = collectSourceSentences(section);
  if (!Number.isInteger(chunkSentences) || chunkSentences <= 0 || expected.length <= chunkSentences) {
    return [makeSectionChunk(section, expected)];
  }

  const chunks = [];
  for (let start = 0; start < expected.length; start += chunkSentences) {
    chunks.push(makeSectionChunk(section, expected.slice(start, start + chunkSentences)));
  }
  return chunks;
};

function makeSectionChunk(section, expected) {
  const text = expected.reduce((value, record, index) => {
    const separator = index === 0 ? '' : (record.para === expected[index - 1].para ? ' ' : '\n\n');
    return `${value}${separator}${record.text}`;
  }, '');
  return { expected, section: { ...section, text, requiredSentences: expected } };
}

// Qwen occasionally normalizes typography while otherwise returning the exact
// source sentence (for example, curly quotes to straight quotes, or spacing
// around a cloze number).  That is not an alignment failure: the immutable
// source still wins when we write the result.  Do not relax word order or
// content checks here; this compatibility form intentionally handles only
// whitespace and equivalent quote glyphs.
const comparableSentenceText = (value) => String(value || '')
  .replace(/[“”]/g, '"')
  .replace(/[‘’]/g, "'")
  .replace(/\s+/g, '');

// When the model's segments differ only by typography/whitespace that the
// source binder already accepts for sentence.text, copy the exact immutable
// source characters back into the same segment boundaries.  This never
// creates a grammar decision: it is permitted only when every model segment
// can be matched, in order, to a contiguous source substring by the strict
// compatibility form above.
const reanchorEquivalentSegments = (segments, sourceText) => {
  if (!Array.isArray(segments) || !segments.length) return segments;
  if (comparableSentenceText(segments.map(segment => segment?.text || '').join('')) !== comparableSentenceText(sourceText)) return segments;
  let cursor = 0;
  const anchored = [];
  for (const segment of segments) {
    const target = comparableSentenceText(segment?.text || '');
    if (!target) return segments;
    let end = cursor + 1;
    while (end <= sourceText.length && comparableSentenceText(sourceText.slice(cursor, end)) !== target) end += 1;
    if (end > sourceText.length) return segments;
    anchored.push({ ...segment, text: sourceText.slice(cursor, end) });
    cursor = end;
  }
  return cursor === sourceText.length ? anchored : segments;
};

const bindModelSentencesToSource = (articleData, expected, allowSourceOverride = false) => {
  if (articleData.length !== expected.length) {
    const actualPreview = articleData
      .slice(0, Math.min(articleData.length, expected.length + 2))
      .map(sentence => String(sentence?.text || '').replace(/\s+/g, ' ').slice(0, 120))
      .join(' | ');
    throw new Error(`Model returned ${articleData.length} sentence(s), expected ${expected.length}. Returned: ${actualPreview}`);
  }
  return articleData.map((sentence, index) => {
    const source = expected[index];
    if (!allowSourceOverride && sentence.text !== source.text && comparableSentenceText(sentence.text) !== comparableSentenceText(source.text)) {
      throw new Error(`Model changed or reordered sentence ${source.id}. Expected: ${source.text}`);
    }
    // ids and paragraph numbers come from the immutable source stream, never
    // from a model guess. The model still supplies all learning content.
    return {
      ...sentence,
      id: source.id,
      para: source.para,
      text: source.text,
      segments: reanchorEquivalentSegments(sentence.segments, source.text)
    };
  });
};

const makeFallbackArticleData = (section) => {
  const paragraphs = section.text
    .split(/\n\s*\n/)
    .map(paragraph => paragraph.trim())
    .filter(Boolean);
  const articleData = [];

  paragraphs.forEach((paragraph, paragraphIndex) => {
    splitParagraphSentences(paragraph).forEach((text) => {
      const id = `s${articleData.length + 1}`;
      articleData.push({
        id,
        para: paragraphIndex + 1,
        text,
        translation: '（本地兜底生成）请结合英文原句理解，建议后续用模型补充精译。',
        grammarFocus: '基础句子结构识别',
        pronounRef: '本地兜底未做深度代词消解。',
        logicConnector: '本地兜底未做深度逻辑连接分析。',
        sentenceCoach: {
          summary: '先完整读原句，再抓主语、动词和补充信息。',
          keyHint: '这是模型失败后的本地兜底结果，原句内容已保留。'
        },
        teachingFocus: {
          mainQuestion: '这句话主要在说谁或什么？',
          grammarQuestion: '先找主语和动词，再看后面的补充内容。',
          modifierQuestion: '注意时间、地点、方式和对象等补充信息。',
          relationshipQuestion: '把原句按顺序读完，再判断各部分怎样连成一个意思。',
          commonMistake: '不要跳过原句中的标点和短语，兜底结果保留了原句文本。',
          thinkingPath: ['读完整句', '找核心动词', '看补充信息'],
          encouragement: '先把原句读顺，后面再精修解析就容易多了。'
        },
        analysis: [
          '### 【主干结构】',
          '本句由本地兜底生成，保留原句并提供基础结构入口。',
          '',
          '### 【主谓一致】',
          '请根据主语单复数和动词形式进一步确认。',
          '',
          '### 【动词时态与原形】',
          '请根据原句动词形式判断一般现在时、过去时、进行时或情态动词结构。',
          '',
          '### 【从句剖析】',
          '本地兜底未做深度从句拆解。',
          '',
          '### 【代词指代】',
          '本地兜底未做深度代词指代分析。',
          '',
          '### 【非谓语动词】',
          '如原句含 to do 或 -ing，请结合上下文判断其作用。'
        ].join('\n'),
        segments: [
          {
            text,
            type: 'modifier',
            label: '原句'
          }
        ],
        generatedBy: 'local-fallback'
      });
    });
  });

  return articleData;
};

const validateArticleData = (articleData) => {
  const warnings = [];
  const allowedTypes = new Set([
    'subject', 'verb', 'object', 'predicative', 'object-complement',
    'clause-subject', 'clause-verb', 'clause-object', 'clause-predicative',
    'coord-subject', 'coord-verb', 'coord-object', 'coord-predicative',
    'conjunction', 'modifier', 'adverbial'
  ]);
  articleData.forEach((sentence, index) => {
    const segmentText = (sentence.segments || []).map(segment => segment.text || '').join('');
    if (segmentText && segmentText !== sentence.text) {
      warnings.push({
        sentenceId: sentence.id || `s${index + 1}`,
        issue: 'segments_do_not_reconstruct_text',
        text: sentence.text,
        segmentText
      });
    }
    (sentence.segments || []).forEach((segment, segmentIndex) => {
      const type = String(segment?.type || '').trim();
      if (!allowedTypes.has(type)) {
        warnings.push({
          sentenceId: sentence.id || `s${index + 1}`,
          segmentIndex,
          issue: 'invalid_segment_type',
          type,
          label: String(segment?.label || ''),
          text: String(segment?.text || '')
        });
      }
    });
  });
  return warnings;
};

const makeArticle = ({ section, articleData, sectionIndex, glossary = [] }) => ({
  id: `${path.basename(section.sourceFile, '.md')}-${String(sectionIndex + 1).padStart(2, '0')}-${slugify(section.headingTitle)}`,
  title: section.sectionTitle,
  timestamp: Date.now() + sectionIndex,
  glossary: normalizeGlossary(glossary),
  data: articleData,
  source: {
    file: section.sourceName,
    section: section.sectionTitle
  }
});

const main = async () => {
  const args = parseArgs(process.argv.slice(2));
  if (isDeepSeekEndpoint(args.baseUrl) && !args.apiKey) args.apiKey = loadDeepSeekApiKey();
  if (isDeepSeekEndpoint(args.baseUrl) && !args.apiKey) {
    throw new Error('DeepSeek API key not found. Set deepseekApiKey in local-config.js or pass LLM_API_KEY/--api-key.');
  }
  args.model = await resolveModelName({
    provider: args.provider,
    baseUrl: args.baseUrl,
    model: args.model,
    apiKey: args.apiKey
  });
  console.log(`LLM provider=${args.provider} baseUrl=${args.baseUrl} model=${args.model}`);
  const files = collectMarkdownFiles(args.input);
  const sections = files.flatMap(file => splitMarkdownSections(file, args.headingLevel, args.stopAtQuestions))
    .filter(section => {
      if (!args.only) return true;
      const needle = args.only.toLowerCase();
      return `${section.sourceName} ${section.sectionTitle}`.toLowerCase().includes(needle);
    })
    .slice(0, args.limit > 0 ? args.limit : undefined);

  if (sections.length === 0) {
    throw new Error('No markdown sections found.');
  }

  console.log(`Found ${sections.length} section(s).`);
  sections.forEach((section, index) => {
    const words = section.text.split(/\s+/).filter(Boolean).length;
    console.log(`${String(index + 1).padStart(2, '0')}. ${section.sourceName} :: ${section.sectionTitle} (${words} words)`);
  });

  if (args.dryRun) {
    if (args.chunkSentences > 0) {
      sections.forEach((section, index) => {
        const chunks = chunkSectionBySentences(section, args.chunkSentences);
        console.log(`${String(index + 1).padStart(2, '0')}. ${section.sectionTitle}: ${chunks.length} chunk(s) (${chunks.map(chunk => `${chunk.expected[0].id}–${chunk.expected.at(-1).id}`).join(', ')})`);
      });
    }
    return;
  }

  fs.mkdirSync(args.output, { recursive: true });
  const articles = [];
  const errors = [];
  const warningsBySection = [];
  const fallbacks = [];

  for (let index = 0; index < sections.length; index += 1) {
    const section = sections[index];
    const sourceStem = path.basename(section.sourceFile, '.md');
    const sectionDir = path.join(args.output, sourceStem, 'sections');
    fs.mkdirSync(sectionDir, { recursive: true });
    const sectionPath = path.join(
      sectionDir,
      `${String(index + 1).padStart(3, '0')}-${slugify(section.headingTitle)}.json`
    );
    const checkpointPath = `${sectionPath}.partial.json`;

    if (!args.force && fs.existsSync(sectionPath)) {
      const cached = JSON.parse(fs.readFileSync(sectionPath, 'utf8'));
      articles.push(cached.article);
      console.log(`Skip existing: ${section.sectionTitle}`);
      continue;
    }

    console.log(`Analyzing ${index + 1}/${sections.length}: ${section.sectionTitle}`);
    try {
      const runChunk = async (chunk) => {
        let parsed = await callModelJson({
          provider: args.provider,
          baseUrl: args.baseUrl,
          model: args.model,
          section: chunk.section,
          timeoutMs: args.timeoutMs,
          apiKey: args.apiKey
        });
        let chunkData = bindModelSentencesToSource(normalizeArticleData(parsed), chunk.expected, args.segmentFallback);
        parsed = { ...parsed, articleData: chunkData };
        let chunkWarnings = validateArticleData(chunkData);
        let qualityErrors = chunkWarnings.filter(warning =>
          warning.issue === 'invalid_segment_type' || warning.issue === 'segments_do_not_reconstruct_text'
        );
        if (qualityErrors.length > 0) {
          parsed = await repairGrammarRoles({ provider: args.provider, baseUrl: args.baseUrl, model: args.model, parsed, qualityErrors, timeoutMs: args.timeoutMs, apiKey: args.apiKey });
          chunkData = bindModelSentencesToSource(normalizeArticleData(parsed), chunk.expected, args.segmentFallback);
          chunkWarnings = validateArticleData(chunkData);
          qualityErrors = chunkWarnings.filter(warning =>
            warning.issue === 'invalid_segment_type' || warning.issue === 'segments_do_not_reconstruct_text'
          );
        }
        if (qualityErrors.length > 0 && args.segmentFallback) {
          const protectedSentenceIds = new Set(qualityErrors.map(item => item.sentenceId));
          chunkData = chunkData.map(sentence => protectedSentenceIds.has(sentence.id)
            ? {
                ...sentence,
                segments: [{
                  text: sentence.text,
                  type: 'modifier',
                  label: '完整句（自动保护，详见下方解析）'
                }],
                autoSegmentFallback: true
              }
            : sentence);
          chunkWarnings = validateArticleData(chunkData);
        }
        if (qualityErrors.length > 0 && !args.segmentFallback) {
          const error = new Error(`Model returned ${qualityErrors.length} invalid segment(s): ${qualityErrors.map(item => `${item.sentenceId || '?'}:${item.type || item.issue}`).join(', ')}`);
          // Persist the P920 response when a deterministic quality gate rejects
          // it.  This is diagnostic evidence only; it is never used to alter
          // the source or synthesize a replacement analysis.
          error.rawContent = JSON.stringify(parsed, null, 2);
          throw error;
        }
        return { articleData: chunkData, glossary: parsed?.glossary || [], warnings: chunkWarnings };
      };
      const runChunkWithRetries = async (chunk) => {
        let lastError;
        for (let attempt = 0; attempt <= args.qualityRetries; attempt += 1) {
          try {
            return await runChunk(chunk);
          } catch (error) {
            lastError = error;
            if (attempt < args.qualityRetries) {
              console.warn(`  Re-requesting ${chunk.expected[0].id}–${chunk.expected.at(-1).id} after quality rejection (${attempt + 1}/${args.qualityRetries}): ${error.message}`);
            }
          }
        }
        throw lastError;
      };
      const runChunkAdaptively = async (chunk) => {
        try {
          return await runChunkWithRetries(chunk);
        } catch (error) {
          if (chunk.expected.length === 1) throw error;
          const pivot = Math.ceil(chunk.expected.length / 2);
          console.warn(`  Rejected ${chunk.expected[0].id}–${chunk.expected.at(-1).id}; split into ${pivot} + ${chunk.expected.length - pivot}: ${error.message}`);
          const left = await runChunkAdaptively(makeSectionChunk(section, chunk.expected.slice(0, pivot)));
          const right = await runChunkAdaptively(makeSectionChunk(section, chunk.expected.slice(pivot)));
          return {
            articleData: [...left.articleData, ...right.articleData],
            glossary: [...left.glossary, ...right.glossary],
            warnings: [...left.warnings, ...right.warnings]
          };
        }
      };
      const initialChunks = chunkSectionBySentences(section, args.chunkSentences);
      let result = { articleData: [], glossary: [], warnings: [] };
      let startChunkIndex = 0;
      if (args.checkpoint && fs.existsSync(checkpointPath)) {
        const checkpoint = JSON.parse(fs.readFileSync(checkpointPath, 'utf8'));
        const expectedText = section.text;
        const completed = Number(checkpoint.completedChunks || 0);
        if (checkpoint.sourceText === expectedText && completed >= 0 && completed <= initialChunks.length) {
          result = checkpoint.result || result;
          startChunkIndex = completed;
          console.log(`  Resume checkpoint: ${completed}/${initialChunks.length} chunk(s)`);
        } else {
          console.warn('  Ignoring stale checkpoint with a different source text.');
          fs.rmSync(checkpointPath, { force: true });
        }
      }
      for (let chunkIndex = startChunkIndex; chunkIndex < initialChunks.length; chunkIndex += 1) {
        const chunk = initialChunks[chunkIndex];
        if (initialChunks.length > 1) console.log(`  Chunk ${chunkIndex + 1}/${initialChunks.length} (${chunk.expected.length} sentences): ${chunk.expected[0].id}–${chunk.expected.at(-1).id}`);
        const chunkResult = await runChunkAdaptively(chunk);
        result.articleData.push(...chunkResult.articleData);
        result.glossary.push(...chunkResult.glossary);
        result.warnings.push(...chunkResult.warnings);
        if (args.checkpoint) {
          fs.writeFileSync(checkpointPath, JSON.stringify({
            sourceText: section.text,
            completedChunks: chunkIndex + 1,
            result
          }, null, 2));
        }
      }
      const { articleData, glossary, warnings } = result;
      const article = makeArticle({
        section,
        articleData,
        sectionIndex: index,
        glossary
      });
      const output = {
        sourceFile: section.sourceName,
        sectionTitle: section.sectionTitle,
        generatedAt: new Date().toISOString(),
        warnings,
        article
      };
      fs.writeFileSync(sectionPath, JSON.stringify(output, null, 2));
      if (args.checkpoint) fs.rmSync(checkpointPath, { force: true });
      articles.push(article);
      if (warnings.length > 0) {
        warningsBySection.push({
          sourceFile: section.sourceName,
          sectionTitle: section.sectionTitle,
          warnings
        });
      }
      console.log(`Wrote ${sectionPath}${warnings.length ? ` (${warnings.length} warning(s))` : ''}`);
    } catch (error) {
      if (error.rawContent) {
        fs.writeFileSync(`${sectionPath}.raw.txt`, error.rawContent);
      }
      if (error.repairContent) {
        fs.writeFileSync(`${sectionPath}.repair.txt`, error.repairContent);
      }

      if (!args.fallback) {
        errors.push({
          sourceFile: section.sourceName,
          sectionTitle: section.sectionTitle,
          error: error.message
        });
        console.error(`Failed: ${section.sectionTitle}: ${error.message}`);
        continue;
      }

      const articleData = makeFallbackArticleData(section);
      const warnings = validateArticleData(articleData);
      const article = makeArticle({ section, articleData, sectionIndex: index });
      const output = {
        sourceFile: section.sourceName,
        sectionTitle: section.sectionTitle,
        generatedAt: new Date().toISOString(),
        generatedBy: 'local-fallback',
        modelError: error.message,
        warnings,
        article
      };
      fs.writeFileSync(sectionPath, JSON.stringify(output, null, 2));
      articles.push(article);
      fallbacks.push({
        sourceFile: section.sourceName,
        sectionTitle: section.sectionTitle,
        error: error.message
      });
      if (warnings.length > 0) {
        warningsBySection.push({
          sourceFile: section.sourceName,
          sectionTitle: section.sectionTitle,
          warnings
        });
      }
      console.warn(`Fallback wrote ${sectionPath} (model failed: ${error.message})`);
    }
  }

  const combinedPath = path.join(args.output, 'reader-articles.import.json');
  const reportPath = path.join(args.output, 'reader-articles.report.json');
  fs.writeFileSync(combinedPath, JSON.stringify(articles, null, 2));
  fs.writeFileSync(reportPath, JSON.stringify({
    generatedAt: new Date().toISOString(),
    input: args.input,
    provider: args.provider,
    model: args.model,
    baseUrl: args.baseUrl,
    sectionCount: sections.length,
    successCount: articles.length,
    errorCount: errors.length,
    fallbackCount: fallbacks.length,
    warningCount: warningsBySection.reduce((sum, item) => sum + item.warnings.length, 0),
    warnings: warningsBySection,
    fallbacks,
    errors
  }, null, 2));

  console.log(`\nCombined import JSON: ${combinedPath}`);
  console.log(`Report: ${reportPath}`);
  if (errors.length > 0) process.exitCode = 1;
};

main().catch(error => {
  console.error(error.message);
  process.exit(1);
});
