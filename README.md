# 英语长难句交互阅读解析

可在浏览器（含 **iPad Safari**）直接使用的英语长难句阅读器。

## 在线访问

https://lesong36.github.io/reading/

在 iPad 上用 Safari 打开上述地址即可；也可「添加到主屏幕」当网页 App 用。

## 本版说明（GitHub Pages）

- **无需语音**：线上版已关闭 TTS / 听老师讲按钮。
- **无需本地 Ollama**：默认使用 OpenAI-compatible 云端接口；阅读内置示例与已导入文章的解析时，不需要配置任何模型。
- **预置书架**：首次打开会自动加载 RFD1/2/3、四上预置教材；若书架为空，也可点「加载预置教材」。
- **分析新文章 / AI 助教**：在「AI 设置」中自行填写兼容接口的 API Key、Base URL、Model。
- **跨设备同步**（可选）：通过 Supabase 同步学习记录；AI Key 仅以客户端加密密文保存。

## 本地打开

直接用浏览器打开 `index.html`（需能访问 esm.sh / Tailwind / unpkg CDN）。

## TPO 导入与做题

TPO 1–30 的抽取、Qwen 逐句解析和做题数据约定见 [TPO 管线说明](docs/TPO_PIPELINE.md) 与 [做题功能说明](docs/QUIZ_FEATURE.md)。

当前批次进度与可继续执行的命令见 [TPO 进度](data/tpo-source/PROGRESS.md)。TPO 解析固定使用 P920 的 llama.cpp OpenAI-compatible 服务 `http://100.121.25.47:8090/v1`，不使用本机 Ollama。

## 跨设备同步

GitHub Pages 只托管静态网页；学习记录使用 Supabase。首次启用请在 Supabase SQL Editor 运行 [`supabase/schema.sql`](supabase/schema.sql)，并在 Auth 中开启 Email 登录。完整操作和安全约束见 [Supabase 同步说明](docs/SUPABASE_SYNC.md)。
