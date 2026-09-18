# Quiz feature

## UX

1. Open an article that has `questions[]`.
2. Switch to **做题** mode (vs 阅读解析).
3. Layout: left = passage (highlight paragraph for current item when hinted); right = stem + 4 choices.
4. Top navigator: question numbers; filled = answered.
5. **交卷** enabled only when every *supported* question is answered.
6. After submit: show correct/wrong, correct option, score. Answers hidden until then.

## Data model (on bookshelf article)

```json
{
  "id": "tpo-1-groundwater",
  "title": "TPO-1 / Groundwater",
  "data": [ /* sentence analyses */ ],
  "questions": [
    {
      "id": "q1",
      "index": 1,
      "prompt": "Which of the following...",
      "options": ["A text", "B text", "C text", "D text"],
      "answerIndex": 2,
      "paragraphHint": "1",
      "type": "single"
    },
    {
      "id": "q14",
      "index": 14,
      "prompt": "...",
      "options": [],
      "answerIndex": null,
      "type": "unsupported",
      "rawAnswer": "Sediments that hold water…"
    },
    {
      "id": "q8",
      "prompt": "Complete the chart using the provided words.",
      "options": ["tomb", "study", "gold", "digging"],
      "blanks": [
        { "id": "blank-1", "prompt": "WHAT: The 1. ( ) was found.", "answerIndex": 0 },
        { "id": "blank-2", "prompt": "WHY: Experts 2. ( ) these objects.", "answerIndex": 1 }
      ],
      "type": "word-bank"
    }
  ]
}
```

- `type: "single"` — classic 4-choice; auto-gradable.
- `type: "multiple"` — select every correct option; auto-gradable.
- `type: "word-bank"` — one multi-blank activity. Learners drag a word to a blank (or tap a word, then a blank on iPad); every blank has its own answer key and is graded together as one question.
- `type: "unsupported"` — insert-text / multi-select etc.; shown in nav but excluded from auto score.

## Progress storage

`localStorage` key: `reader_quiz_progress_{articleId}`

```json
{
  "answers": { "q1": 2, "q3": 0, "q8": { "blank-1": 0, "blank-2": 1 } },
  "locatorSentenceIds": { "q1": "sentence-4", "q8::blank-1": "sentence-6", "q8::blank-2": "sentence-8" },
  "submitted": false,
  "submittedAt": null
}
```

`locatorSentenceIds` is an optional mapping. In quiz mode, learners can long-press a passage sentence with a mouse or iPad to save it as the active question's locator sentence. For `word-bank`, the key includes the blank ID (`q8::blank-1`), so each blank retains its own locator sentence in the same local and cloud-synced progress record.

## Answer source

Word「参考答案」lines like `1. ○3` → `answerIndex = 2` (1-based ○N → 0-based index).
Never invent answers with the LLM.
