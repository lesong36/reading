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
    }
  ]
}
```

- `type: "single"` — classic 4-choice; auto-gradable.
- `type: "unsupported"` — insert-text / multi-select etc.; shown in nav but excluded from auto score.

## Progress storage

`localStorage` key: `reader_quiz_progress_{articleId}`

```json
{
  "answers": { "q1": 2, "q3": 0 },
  "submitted": false,
  "submittedAt": null
}
```

## Answer source

Word「参考答案」lines like `1. ○3` → `answerIndex = 2` (1-based ○N → 0-based index).
Never invent answers with the LLM.
