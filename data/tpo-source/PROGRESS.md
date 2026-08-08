# TPO pipeline progress

Updated: 2026-08-05

## LLM endpoint (locked)

| Field | Value |
|---|---|
| Host | P920 Tailscale `100.121.25.47` (LAN `192.168.0.107`) |
| Port | **8090** |
| Runtime | **llama.cpp** OpenAI-compatible server (`owned_by: llamacpp`) |
| Base URL | `http://100.121.25.47:8090/v1` |
| Health | `GET /health` → `{"status":"ok"}` |
| Models | `GET /v1/models` |
| Chat | `POST /v1/chat/completions` |
| Model id | auto-pick name matching `qwen3.6` / `Qwen3.6` + `35B` (currently `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_P.gguf`) |
| Thinking | disabled via `chat_template_kwargs.enable_thinking=false` |

**Not used:** Ollama on `:11434` (refused / not listening). Local Mac Ollama is forbidden for this pipeline.

## Batch status

| Batch | Scope | Status | Notes |
|---|---|---|---|
| Extract | 104 passages + questions | done | 104/104 extracted; 1,129 official-answer single-choice items; 155 unsupported items |
| B0 | TPO-1 (3) | done | 3/3 Qwen analyses, no warnings/fallbacks; merge validation passed |
| B1 | OG + Online + Official + OG Test 2 | done | 17/17 analyses succeeded after retry; no warnings or fallbacks |
| B2 | TPO 1,3–10 | done | 27/27 analyses completed; 8 segment-alignment mismatches repaired losslessly before merge validation |
| B3 | TPO 11–20 | done | 30/30 analyses succeeded after retry; 16 segment-alignment mismatches repaired losslessly before merge validation |
| B4 | TPO 21–30 | done | 30/30 analyses completed; 7 segment-alignment mismatches repaired losslessly before merge validation |
| Quiz UI | index.html | done | 阅读/做题切换、判卷与 `reader_quiz_progress_{articleId}` 进度存储已实现 |
| Merge/ship | import JSON + sync | done | 104 篇合并包已生成并同步至正式 macOS App；TPO/OG 书架筛选已加入 |

## Next command

```bash
cd /Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new
curl -s http://100.121.25.47:8090/v1/models | jq -r '.data[].id'
npm run regenerate:tpo -- --batch B1
```
