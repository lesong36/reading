# AGENTS — cold start for AI tools

Read these in order before changing code or rerunning batches:

1. [README.md](./README.md) — product overview + Pages URL
2. [docs/COLD_MIGRATION.md](./docs/COLD_MIGRATION.md) — env, commands, do-not-commit
3. [docs/TPO_PIPELINE.md](./docs/TPO_PIPELINE.md) — extract → Qwen → merge
4. [docs/QUIZ_FEATURE.md](./docs/QUIZ_FEATURE.md) — quiz UX + data model
5. [data/tpo-source/PROGRESS.md](./data/tpo-source/PROGRESS.md) — batch status / next command

## Source of truth

| Path | Role |
|---|---|
| `index.html` | Main app (sync to App + Chinese alias via `npm run sync:app`) |
| `scripts/analyze-md-sections.mjs` | Ollama section → reader JSON |
| `scripts/extract-tpo-from-doc.mjs` | Word/txt → TPO passages + questions |
| `scripts/regenerate-tpo-reader-json.mjs` | Batch wrapper (resolves `qwen3.6:35b*`) |
| `scripts/merge-tpo-bundle.mjs` | Merge analyses + questions → import JSON |
| `data/tpo-source/` | Extracted MD/questions/manifest/progress |
| `data/generated-reader-json-tpo/` | Per-section Qwen outputs |

## Hard rules

- Never commit `local-config.js` or the original `.doc`.
- Do not use Word「参考译文」as article body.
- Quiz answers come from Word「参考答案」, not the model.
- TPO analysis uses P920 **llama.cpp** at `http://100.121.25.47:8090/v1` (not Ollama). Model id must be Qwen3.6 35B; resolve via `/v1/models`. Never fall back to local Mac Ollama for this pipeline.
