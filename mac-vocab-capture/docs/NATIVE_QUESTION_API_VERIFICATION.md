# 问一问原生模型接口验证（0.2.64）

2026-10-05，macOS / Apple Silicon。

## 问题与依据

用户保存的 DeepSeek 配置可以回答，但 aicodewith 的 GPT 和 Claude 配置返回 HTTP 401。原问答客户端对全部模型发送 Chat Completions 请求。aicodewith 文档说明服务透传原生格式，不进行格式转换；Codex 接入示例使用 Responses，Claude 桌面接入使用 Messages。因此客户端确实缺少所需协议支持；HTTP 401 本身仍不能证明密钥有效或无效。

参考官方资料：[格式转换说明](https://docs.aicodewith.ai/zh/docs/why-no-format-conversion)、[Codex 接入](https://docs.aicodewith.ai/zh/docs/codex-cli)、[Claude 桌面接入](https://docs.aicodewith.ai/zh/docs/claude-app)、[Responses 流式事件](https://developers.openai.com/api/docs/guides/streaming-responses)、[Responses 推理与输出预算](https://developers.openai.com/api/docs/guides/reasoning)、[Messages 流式事件](https://platform.claude.com/docs/en/build-with-claude/streaming)。

## 改动

- `Sources/VocabCapture/ScreenshotQuestionAPI.swift`：自动识别和三种显式协议，按协议构造请求路径。仅对 `api.aicodewith.com` 与 `api.aicodewith.ai` 的 Claude/GPT 模型自动选原生接口，其他服务维持 Chat Completions。不会把用户配置的域名改为另一个域名。
- `Sources/VocabCapture/ScreenshotQuestionClient.swift`：各协议独立的请求体、图片格式、认证头、流式和完整 JSON 响应解析。Responses 使用 Bearer，Messages 使用 `x-api-key` 与 `anthropic-version`。Responses 输出预算为 4096，包含推理与可见回答；其他接口保持 900。不自动重试其他服务、不回显服务端错误体。
- `Sources/VocabCapture/ScreenshotQuestionPreferences.swift`：每个配置保存独立协议。旧 JSON 缺少协议字段时默认为自动识别，保留配置 ID 与原 Keychain 账户。
- `Sources/VocabCapture/ScreenshotQuestionModelSettings.swift`：增加“接口协议”选择；窗口增高以完整显示表单和操作。
- `Sources/VocabCapture/VocabCaptureApp.swift`：提问使用当前配置的协议。取词释义保持原设置。
- 对应三个测试文件、`README.md` 与 `VERSION`：回归测试、用法和版本。

复用现有模型配置和回调，没有新依赖或第二套密钥存储。对失败或不完整流保持失败状态，不将其作为完整回答加入后续对话。

## 自动化验证

```sh
swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-multi-profile-tests -Xswiftc -warnings-as-errors
```

完整 **121 项测试、0 失败**。覆盖协议自动识别与手动覆盖、域名/路径保留、认证头、历史消息、图片、原生 SSE 和 JSON、Unicode/CRLF/多行事件、累计增量、截断和异常、取消、HTTP 401/403/404/429，以及旧配置解码、协议保存和设置面板恢复。流式提前显示测试由首次增量回调放行后续帧，避免把定时调度当作正确性依据。

本次涉及的三个生产组件、协议枚举与三个测试文件通过 `swift format lint --strict`；`git diff --check` 通过。Release 构建、应用深度严格签名校验通过。

## 原生 macOS 窗口验证

隔离应用 `/tmp/vocab-native-api-system/原生接口本地验证.app` 使用生产面板、生产客户端和应用编辑菜单；UserDefaults 隔离，凭据仅为内存测试占位值。本地服务仅绑定 `127.0.0.1:65430`，日志只记录路径、模型和认证头是否存在，不记录凭据、问题或原文。

| 界面配置 | 实际请求 | 原生窗口结果 |
|---|---|---|
| Claude Messages 本地验证 | `/v1/messages`，只有 x-api-key，版本头 2023-06-01 | 显示 Messages 本地验证回答；回答完成 |
| GPT Responses 本地验证 | `/v1/responses`，只有 Bearer | 显示 Responses 本地验证回答；回答完成 |
| DeepSeek 通用接口验证 | `/v1/chat/completions`，只有 Bearer | 显示 Chat Completions 本地验证回答；回答完成 |
| 401 鉴权提示验证 | `/rejected/v1/responses` | 说明模型认证失败，提示核对接口、地址与 Key；恢复问题供重试 |

切换配置清空旧对话。设置窗口显示全部字段和底部按钮，协议菜单包含自动识别及三种接口。视觉检查无字段重叠或裁切，评分 95，记录于 `.omx/state/vocab-native-api/ralph-progress.json`。

## 安装与验证边界

已安装并启动 `/Users/coty/Applications/拾词助手.app` **0.2.64**，正式应用运行进程只有一个。更新前后及重新启动后，生词 JSON 和偏好文件 SHA-256 一致。旧 0.2.63 保存在 `/Users/coty/.Trash/拾词助手-0.2.63-20261005-194642.app`，可恢复。

本次没有读取或导出真实 API Key，没有将其复制到测试程序，也没有验证真实 aicodewith 的认证、模型权限、网络可达性或回答。使用无认证请求探测原服务时未取得 HTTP 响应，不能作为云端验证成功的证据。原生窗口测试证明协议和交互适配，不能替代真实服务端验证。

用户仍需在正式应用中选择原 aicodewith 配置重试；默认自动识别即可。如服务提供了不同的原生 Base URL，应按该地址更新配置；若仍为 401，应核对 Key 和模型/渠道权限。本轮未重新验证全局截图快捷键、语音、云端生词同步；未提交或发布新 Release。

旧的用户填写真实密钥的验证应用和其内存状态保持不变。本轮新增的隔离窗口与本地服务在验证后停止。
