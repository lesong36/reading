# 阅读达人：Article Reading Model V1

## Status

> **Rejected as a product and model direction (2026-09-16).** This document
> remains as an archive of the V1 experiment only. Do not generate, attach,
> or extend V1 sidecars for new product work. The V1 model mixed expert text
> analysis, child answers, and Runtime heuristics; its six-activity routine
> was rejected in user review.
>
> The replacement discussion is in
> [`READING_COMPREHENSION_FRAMEWORK_V2_DISCUSSION.md`](./READING_COMPREHENSION_FRAMEWORK_V2_DISCUSSION.md),
> and the product plan is in
> [`ARTICLE_READING_PRODUCT_PLAN.md`](./ARTICLE_READING_PRODUCT_PLAN.md).

## Product decision

The existing sentence reader remains responsible for words, grammar, sentence
structure, and some local sentence-to-sentence support. This feature adds the
next reading unit:

```
sentence understanding → paragraph meaning → paragraph connection
                       → text structure → whole-text meaning
                       → evidence and inference
```

The child-facing routine uses concrete questions, rather than framework
names. Internally it practices four moves:

- compress: find what matters in a paragraph or text;
- connect: notice why the next paragraph is there;
- predict: use a signal or a completed section to anticipate direction;
- evidence: point to words in the article that support an idea.

V1 prioritizes informational text. Narrative gets a different routine later;
its story-map concepts must not be forced into this schema.

## Architecture boundary

```
article import
  └─ AI article parser (offline/development-time, deep structured output)
       └─ Article Reading Model JSON
            ├─ deterministic reading runtime: two-pass routine, prompts, answers, feedback
            └─ optional AI runtime: free voice/text response, a follow-up
               question, or a personalized explanation only
```

Anything knowable from the article—including distractors, paragraph links,
prediction points, source sentences, and the article map—is computed before a
child reads. The reader must not call an LLM just to decide an answer or draw
the map. The map is **not** a first screen or an answer key: it is rendered
from the child's completed paragraph notes during the second pass.

## Three non-overlapping layers

The model has exactly three meanings. Do not put a teaching prompt in
`analysis`, or an answer about article structure in `pedagogy`.

| Layer | Answers | Contains |
| --- | --- | --- |
| `content` | What did the author write? | immutable paragraph/sentence text and stable IDs |
| `analysis` | How is the text constructed? | paragraph and text meaning/structure |
| `pedagogy` | How will this particular child discover it? | activities, child wording, distractors, scaffolds |

`content` is copied from the current reader's `article.data` in V1. Existing
sentence IDs such as `s12` are stable IDs and remain canonical; a future
pipeline may emit `p1_s1`, but V1 must not renumber existing libraries.

## Canonical V1 shape

```json
{
  "schema_version": "1.0",
  "article": {
    "id": "existing-article-id",
    "title": "…",
    "text_type": "informational",
    "language": "en",
    "audience": { "grade_band": "upper_elementary" }
  },
  "content": { "paragraphs": [] },
  "analysis": { "paragraphs": [], "text": {} },
  "pedagogy": { "activities": [] }
}
```

### `analysis.paragraphs`

Each entry has an `id` matching a `content.paragraphs[].id`, plus:

- `topic.label`
- `main_idea.text`
- `key_details[]` with `source_ids` and a short `meaning`
- `function.type` (`introduce_topic`, `explain`, `develop`, `example`,
  `cause`, `effect`, `contrast`, `conclude`)
- `relation_to_previous` (`null` for the first paragraph; otherwise `type`
  and earlier `target`)
- `signals[]`, each tied to a source sentence and a discourse role

### `analysis.text`

V1 supports `sections`, `structure`, `central_idea`, and optional
`inferences`. An inference is an explicit chain of `claim`, `evidence`, and
`knowledge_bridge`, not an opaque answer.

### `pedagogy.activities`

Only these six activity types are in V1:

1. `choose_main_idea`
2. `choose_heading`
3. `identify_support`
4. `paragraph_connection`
5. `predict_direction`
6. `find_evidence`

An option's `role` is data for feedback and later diagnostics, never a label
shown to the child. Supported roles are `main_idea`, `supporting_detail`,
`minor_detail`, `too_broad`, `too_narrow`, `irrelevant`, and
`misinterpretation`.

`scaffold_level` moves from `high` (recognition/choice) through `medium`
(selection) and `low` (organizing/heading) to `independent` (optional voice
summary). Production is opt-in in V1; a young child is never required to type
a summary to proceed.

## Child experience: the two-pass routine

The six activities above are curriculum primitives, not a child-facing menu of
six unrelated questions. Informational reading V1 always begins with the first
pass; it never assumes that the learner has already understood each paragraph.

```
first pass: read → topic → main idea → tap evidence → paragraph note → predict
second pass: paragraph function → paragraph connection → group notes
             → text structure / central idea
```

The child sees concrete language such as “给这一段留一张小便签”, “下一段会写
什么”, and “哪些段落可以放在同一部分”. Internal labels such as Compress,
Connect, Predict, and Evidence are product-design vocabulary only. The first
MVP uses tap/select/click interactions; voice summary remains optional and is
never required for progress.

The runtime persists only learner progress (`notes`, selected evidence,
predictions, functions, connections, sections, whole-text answer) in a
per-article local record. It never writes learner answers back into `analysis`
or exposes an analysis answer before the child has acted.

## Current-project compatibility and migration

The present reader stores a flat sentence array in `article.data` and groups
it by `para` at render time. Its import parser (`scripts/analyze-md-sections.mjs`)
is deliberately sentence/chunk oriented. V1 therefore does not alter its
well-tested sentence contract or ask a chunked model call to infer whole-text
structure.

1. Keep `article.data`, sentence analysis, TTS, glossary, existing quiz, and
   existing local/cloud records unchanged.
2. Add an optional `article.readingModelPath` pointing to this document's
   complete JSON sidecar. Articles without it display exactly as before.
3. Generate this field in a **separate whole-article parser pass** after the
   sentence parser has completed. Its input must contain the canonical
   paragraphs and IDs; its output must pass the model validator before merge.
4. Use the existing merge scripts to attach only valid `readingModel` output.
   Do not make the reading UI invoke the import model.
5. Later, add teacher override provenance in this order: official answer,
   teacher revision, AI generation. V1 stores no learner diagnosis profile.

The first implementation uses existing informational sidecars for a deterministic
two-pass MVP. `analysis` provides the correct structural answer; the UI derives
high-scaffold topic/main-idea choices, paragraph evidence candidates, and
child-friendly function/connection labels locally. This proves the experience
before the batch parser is tightened to emit the finite child-facing labels
directly.

### Offline pipeline commands

The whole-article parser is intentionally separate from
`analyze-md-sections.mjs`: the latter is a sentence/chunk pipeline and must
not be overloaded with text-level inference.

```bash
# Inspect the exact deterministic input; this makes no network call or write.
npm run generate:article-reading-model -- \
  --only re-foundations-6a-planting-for-the-planet --dry-run

# Generate one sidecar using the configured OpenAI-compatible analysis model.
npm run generate:article-reading-model -- \
  --only re-foundations-6a-planting-for-the-planet --force

# Reject invalid references or content that diverges from article.data across
# the RFD and RE packs.
npm run validate:article-reading-model

# Attach a validated sidecar to the bookshelf pack (preview first).
npm run attach:article-reading-models -- \
  --only re-foundations-6a-planting-for-the-planet --dry-run
```

The generator sends canonical paragraph text and IDs to the model, but only
accepts `analysis` and `pedagogy` back. It reconstructs `content` itself, so a
model cannot silently renumber, omit, or rewrite the source article.

For the P920 batch priority (RFD1–6 and RE), use the serial, resume-safe
runner. Existing validated sidecars are skipped; `.batch-progress.json` records
completed and failed IDs after every article.

```bash
npm run generate:article-reading-model:batch -- --dry-run
npm run generate:article-reading-model:batch -- \
  --model /home/coty/models/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf
```

## V1 acceptance checks

- Model validation rejects broken references, duplicate IDs, invalid activity
  types, or answers not present in candidate options.
- The sample model validates and every source ID points to a real sentence.
- An article without `readingModel` retains the current three-tab reader.
- An informational article gains a fourth “篇章阅读” tab with no network/AI request.
- The child starts with the first paragraph, rather than a revealed map or
  whole-text answer.
- A paragraph note is created only after topic, main idea, and original-text
  evidence have been chosen.
- The second pass consumes the child's notes for function, connection, grouping,
  and the final whole-text decision.
- Evidence is completed by clicking original article sentences.

## Deferred work

- Narrative routine and story map
- whole-library model generation and editorial approval UI
- voice-summary evaluation and personalized AI feedback
- learner mastery / R0–R8 reporting, adaptive recommendations, and analytics
- automatic parser calls from the browser
