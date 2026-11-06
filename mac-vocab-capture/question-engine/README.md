# Local screenshot question engine

The macOS app starts `question_engine.py` as a persistent helper and exchanges
NDJSON over private stdin/stdout pipes. Production packaging freezes it into
`Contents/Helpers/QuestionEngine/QuestionEngine`; users do not need Python or uv.
Ordinary English/screenshot and web answers remain direct LangChain calls.
Math method selection alone uses Deep Agents' real `SkillsMiddleware` inside a
bounded LangChain `create_agent` (which runs on LangGraph).

`uv.lock` fixes the tested versions: LangChain 1.4.3, langchain-openai 1.6.7,
langchain-anthropic 1.7.5, and PyInstaller 6.22.3 for packaging. Run from this
directory:

```sh
uv sync --frozen --extra build --python 3.13 --python-preference only-managed
uv run --frozen python -m unittest discover -s tests -v
uv run --frozen python -m py_compile question_engine.py tests/test_engine.py
```

To run the subprocess integration tests against the packaged executable, while
retaining the source SDK tests in the same suite:

```sh
QUESTION_ENGINE_EXECUTABLE=/absolute/path/to/QuestionEngine \
  uv run --frozen python -m unittest discover -s tests -v
```

The tests use an ephemeral localhost HTTP server and fake credentials only.
They exercise the actual SDKs, endpoint paths and authentication, image and
history encoding, stream completion, JSON and gzip compatibility, concurrent
requests, cancellation, EOF shutdown, and suppressed tracing.

## Pipe protocol

After imports complete, the helper emits
`{"type":"ready","protocol":1,"langchain_version":"1.4.3"}`. Each answer input
has `op`, `id`, `question`, `instructions`, `context`, `history`, and
`configuration`. The app supplies a fully resolved endpoint, protocol
(`chatCompletions`, `responses`, or `anthropicMessages`), model, and API key.
Screenshot data is bare base64 PNG/JPEG, with a 20 MiB decoded size limit.
History is limited to the latest six turns.

## Teaching skills

Send `task:"math_method_selection"` plus `teaching_skills`, a nonempty array of
immutable `{id,version_id,title,category,instructions}` snapshots. An optional
`description` supplies source-derived routing metadata, and an optional
`skill_name` preserves the canonical project skill name. These fields are used
only when the current version still matches its project bundle. They are not
a certification of mathematical correctness. The current limit is
512 skills and 300,000 UTF-8 bytes including metadata. No host directory path is
accepted. `question` contains the user's requirements only; never duplicate all
method bodies there. Web search and `response_mode` are rejected on this task.

Project methods live in `Sources/VocabCapture/Resources/MathSkills/`, with
a checked manifest and standard YAML frontmatter. The native app bundles and
imports them without reading an external Obsidian folder. User edits and
archived entries remain authoritative; historical versions are not rewritten.
See [the project skills specification](../docs/MATH_SKILLS_SPEC.md).

The framework discovers virtual `/teaching-skills/<skill-name>/SKILL.md`
files (version-hashed names for custom or edited methods), exposes metadata, and calls the sole `read_file` tool for complete chosen
methods. With legacy notes the metadata contains only title/category, so it does
not truncate essential applicability/exclusion conditions. These must be checked
after reading; routing accuracy still needs a reviewed real-question evaluation.

Selection does not solve the problem. It returns the same JSON text contract:
`{method_id,visual_method_ids,reason}`. Unknown/duplicate IDs, incomplete provider
output and unread chosen methods are rejected. There are at most five agent model
calls and twelve reads, within the existing 90-second overall request deadline.
No intermediate agent thoughts or partial JSON are emitted to the UI.

`done` also includes `skills_execution:{mode,loaded_skill_ids,fallback_reason?}`.
Only explicit HTTP 400/422 unsupported-tool validation, an unavailable model tool
binding, or a model selecting methods without reading them enables one direct
full-snapshot compatibility call. The reason visibly states this fallback; it
does not claim skill tools were used. Authentication/network/timeout failures,
malformed JSON and bad IDs do not retry. Selected method/version data must still
be frozen by the native app. Tool reads prove what was loaded, not mathematical
correctness or whether the model faithfully followed it.

Solver requests can separately send `response_mode:"math_diagrams"` to reserve
8192 output tokens. Their client profiles are separate from ordinary 900-token
Chat/Anthropic and 4096-token Responses profiles. The solver remains streaming;
diagram JSON validation/rendering belongs to the native app.

No writes, scripts, shell, subagents, permanent agent memory, remote skill lookup
or LangSmith upload is enabled. SQLite continues to own method versions and
human review. Skills matching state is per request, never shared across users or
requests. Inherited tracing is stripped before the framework is imported.

Output is incremental `{id,type:"delta",text}` followed by exactly one
`{id,type:"done",text}` or sanitized `{id,type:"error",code,status?}`. A cancel
input is `{op:"cancel",id}`. Cancellation produces no completion event. EOF
cancels outstanding requests and closes all cached clients.
Network failures use `code:"connection"`; deadlines use `code:"timeout"`;
unusable provider data uses `code:"response"`. `code:"server"` includes an
actual HTTP status and is never synthesized for a connection failure.

When the provider reports SDK token usage, the `done` event adds
`usage:{input_tokens,output_tokens,reasoning_tokens?}`. Counts are non-negative
integers; reasoning is included only when the provider supplies it. Output
tokens are the provider's inclusive total, which may include hidden reasoning;
reasoning is a breakdown, not an additional token count. Unknown usage omits
the entire `usage` object and retains the previous completion-event shape.

The helper aggregates LangChain chunk usage once. Claude cumulative deltas are
normalized to increments, with input/cache counts from the typed start event
retained when later usage omits them. Chat Completions `include_usage` is
requested only for verified OpenAI/DeepSeek API hosts. Other compatible
gateways keep their existing request options. No request is retried or resent
to obtain statistics; clients should show token throughput as unavailable when
usage is absent, instead of estimating it from characters.

## Transport and privacy

Four in-memory profiles reuse model/HTTP clients and keep-alive connections.
Cache keys include a credential hash; no credentials, prompts, screenshots,
history, or cache entries are persisted. Acquisition and eviction are locked
so simultaneous requests for a new profile share a client. The helper accepts
at most eight active requests. Requests have a 90-second deadline and no
automatic retries.

On macOS, external requests read the system's static HTTP/HTTPS proxy settings
and bypass rules directly through Python's SystemConfiguration bridge. Proxy
selection is explicit; inherited `http_proxy`/`no_proxy` variables do not replace
the user's macOS settings, and HTTPX keeps `trust_env=False`. Loopback addresses
and `localhost` always connect directly. The route is checked for each request
and included in the cache key, so changing the system proxy creates a new
client. Proxy URLs remain in memory and are never logged. PAC and SOCKS-only
system configurations are not supported by this adapter.

The adapters use `ChatOpenAI.astream` or `ChatAnthropic.astream`. The Anthropic
subclass injects the HTTPX client and observes already-parsed official SDK
events to require both `message_start` and `message_stop`, alongside a normal
stop reason. It does not parse SSE. A bounded wrapper converts complete JSON
responses from servers that ignore `stream=true` into SDK-readable events,
without sending a second request. HTTPX performs compressed-body decoding.

The helper strips inherited LangSmith/LangChain and provider environment
configuration, forces tracing off, and disables library logging. API keys come
only through the input pipe. Standard output contains protocol events only;
errors never include provider error bodies, credentials, or raw exception
messages. Local empty-key endpoints receive a dummy key rather than an
inherited provider key.
