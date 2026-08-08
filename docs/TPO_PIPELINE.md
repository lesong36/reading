# TPO pipeline

Source DOC (local only, not in git):

`/Users/coty/Documents/Lei_MBP/Education/MBA/GT/toefl/阅读/TPO1-30阅读题、参考答案及译文.doc`

## Expected coverage

104 English passages:

- OG (10), OG Test 2 (3), Online Test (3), Official Model Exam (1)
- TPO 1, 3–30 × 3 each (87). **No TPO-2.**

Word「参考译文」is discarded. Sentence-level Chinese in reader JSON comes from Qwen analysis.

## LLM (P920 — not Ollama)

P920 serves **llama.cpp** OpenAI-compatible API:

- Base: `http://100.121.25.47:8090/v1`
- Model: auto-resolve any `Qwen3.6*35B*` id from `/v1/models`
- Do **not** use local Mac Ollama or `:11434`

## Commands

```bash
# Extract passages + questions
npm run extract:tpo

# Optional: only TPO-1
npm run extract:tpo -- --only TPO-1

# Analyze a batch on P920:8090
npm run regenerate:tpo -- --batch B0
npm run regenerate:tpo -- --batch B1

# Merge analyses + questions → import JSON
npm run merge:tpo
```

Env overrides:

```bash
export LLM_PROVIDER=openai
export LLM_BASE_URL=http://100.121.25.47:8090/v1
export LLM_MODEL='Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_P.gguf'  # optional pin
```

## Batches

| Batch | Scope | Approx |
|---|---|---|
| B0 | TPO-1 | 3 |
| B1 | OG + Online + Official + OG Test 2 | ~17 |
| B2 | TPO 1,3–10 | ~27 |
| B3 | TPO 11–20 | 30 |
| B4 | TPO 21–30 | 30 |

Resume-safe: existing successful section JSON is skipped unless `--force`.

## Outputs

| Path | Meaning |
|---|---|
| `data/tpo-source/passages/*.md` | English body only |
| `data/tpo-source/questions/*.json` | Quiz items + answers |
| `data/tpo-source/manifest.json` | Inventory + validation |
| `data/generated-reader-json-tpo/` | Per-section Qwen outputs |
| `data/generated-reader-json/reader-articles-tpo.import.json` | Merged bookshelf pack |

## Failure recovery

1. Read `data/tpo-source/PROGRESS.md` and latest `*.report.json`
2. Re-run the same batch (skips OK files)
3. Or: `npm run analyze:md-sections -- --only "Groundwater" --force ...`
4. `npm run merge:tpo` after repairs
