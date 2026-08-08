# Cold migration / handoff

For any AI tool or human picking up mid-flight.

## Machine deps

- macOS `textutil` (DOC → TXT)
- Node 18+
- P920 LLM is **llama.cpp** on port **8090** (OpenAI-compatible), **not** Ollama `:11434`
- Base URL: `http://100.121.25.47:8090/v1`
- Model: any id matching `Qwen3.6` + `35B` from `/v1/models`
- Local Mac Ollama must **not** be used for TPO batches

Resolve model:

```bash
curl -s http://100.121.25.47:8090/v1/models | jq -r '.data[].id'
curl -s http://100.121.25.47:8090/health
```

## Repo map

```
reading_new/
  AGENTS.md
  index.html                 # app
  scripts/
    extract-tpo-from-doc.mjs
    analyze-md-sections.mjs
    regenerate-tpo-reader-json.mjs
    merge-tpo-bundle.mjs
    sync-app-entry.mjs
  data/tpo-source/           # extracted (passages/questions/manifest)
  data/generated-reader-json-tpo/
  docs/
```

## Do not commit

- `local-config.js` (secrets)
- Original `TPO1-30*.doc`
- `node_modules/`, `*.log`, `*.pid`

## Where we are

Open [../data/tpo-source/PROGRESS.md](../data/tpo-source/PROGRESS.md). It lists batch status and the exact next command.

## Typical resume

```bash
cd /Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new

# 1) Ensure extract exists
npm run extract:tpo -- --dry-run   # or full extract if missing

# 2) Continue analysis (skips completed sections)
npm run regenerate:tpo -- --batch B0

# 3) Merge + sync app
npm run merge:tpo
npm run sync:app
```

## App install path

Formal macOS app: `~/Applications/英语长难句阅读器.app`  
Sync: `npm run sync:app`
