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
- Model: auto-resolve an available Qwen model from `/v1/models` (currently `Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf`)
- Do **not** use local Mac Ollama or `:11434`

## Commands

```bash
# Extract passages + questions
npm run extract:tpo

# Optional: only TPO-1
npm run extract:tpo -- --only TPO-1

# Build immutable, audit-backed clean copies for the model. This must run
# before every TPO/OG batch; raw passages and quiz material stay untouched.
npm run clean:tpo

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
export LLM_MODEL='Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf'  # optional pin; omit to auto-resolve
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
| `data/tpo-source/passages/*.md` | Immutable raw Word extraction (may retain quiz source material) |
| `data/tpo-source-clean/passages/*.md` | Deterministic body-only derivative used by P920; never manually edit |
| `data/tpo-source-clean/manifest.json` | Hashes, cutoff evidence, and audit outcome for every clean passage |
| `data/tpo-source/questions/*.json` | Quiz items + answers |
| `data/tpo-source/manifest.json` | Inventory + validation |
| `data/generated-reader-json-tpo/` | Per-section Qwen outputs |
| `data/generated-reader-json/reader-articles-tpo.import.json` | Merged bookshelf pack |

## Failure recovery

1. Read `data/tpo-source/PROGRESS.md` and latest `*.report.json`
2. Re-run the same batch (skips OK files)
3. Or: `npm run analyze:md-sections -- --only "Groundwater" --force ...`
4. `npm run merge:tpo` after repairs

## Source fidelity gate

`npm run clean:tpo` never changes `data/tpo-source/passages`. It evaluates a
possible `Paragraph 1:`-style boundary using deterministic evidence before it
is removed: either the tail is represented in the extracted question data, or
it repeats the start of the article verbatim (allowing the heading title that
may have been lost by the Word exporter). A marker without either proof is
quarantined in the audit manifest, rather than silently truncating prose.

P920 receives only `data/tpo-source-clean/passages`. This prevents a malformed
quiz extraction from consuming GPU time and creating an otherwise
structurally-valid but semantically invalid analysis.
