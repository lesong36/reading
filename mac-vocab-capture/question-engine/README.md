# Local screenshot question engine

The macOS app starts `question_engine.py` as a persistent helper and exchanges
NDJSON over private stdin/stdout pipes. Production packaging freezes it into
`Contents/Helpers/QuestionEngine/QuestionEngine`; users do not need Python or uv.
This is a direct LangChain model call, without an agent or tool loop.

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
