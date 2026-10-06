# 问答思考设置与性能复测（0.2.70）

2026-10-06：菜单、原文预览和思考选项一起调整；沿用 LangChain 1.4.3 与现有依赖。

## 使用变化

- 菜单“模型与服务”集中放置“取词释义模型…”与“问一问模型设置…”。“快捷键与取词”集中放置取词开关与快捷键设置。菜单项使用明确操作目标，应用内 ⌘, 仍打开取词模型设置。
- 问答窗口的模型旁增加思考选择：自动、关闭／最少思考、低、中、高。模型设置窗口也可保存；每个配置独立记忆，“沿用取词模型”另存强度。切换模型或强度停止当前回答、开始新对话，保留问题草稿。
- 未设置强度的旧配置默认使用“关闭／最少思考”；服务地址、模型、Key、快捷键和阅读缩放保持原值。修改强度只写元数据，不读取或重写 Key。
- 原文预览合并 OCR 物理行尾，随宽度和字体重排。发送给模型的原始文字保持完整。自然换行依然由窗口宽度决定。

## 参数规则

- DeepSeek 官方 Chat 接口：关闭发送 `thinking.type=disabled`；低启用思考并发送 `reasoning_effort=low`；中、高使用该服务支持的 `high`。依据：[DeepSeek 思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)。
- GPT-6.1 Sol：最低可用强度是 `low`；该模型没有完全关闭选项。其余已识别 GPT 型号按官方能力使用 `none`、`minimal` 或 `low`。依据：[GPT-6.1 Sol 模型文档](https://developers.openai.com/api/docs/models/gpt-6.1-sol)。
- Claude Sonnet 5.5：优先速度使用 `between_tools` + `effort=low`；本应用没有工具调用，不在回答前执行思考。不可关闭思考的已识别 Claude 型号使用 adaptive + low。较旧型号使用 disabled 或预算思考。依据：[Claude 思考兼容说明](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting)。
- 自动不发送思考控制。未识别模型的“关闭／最少思考”也保留服务默认值，避免升级后破坏兼容；手动选择低／中／高时提示无法识别，请改用自动或核对型号。服务方网关也可能改变实际行为。
- 客户端缓存包含强度，切换后不会复用旧参数。可见文字首段立即显示；思考内容不进入回答区。没有增加自动重试、额外付费请求或远程追踪。

## 真实请求对照

使用已保存的三个模型与原 Key。凭据只经过进程内存及输入管道，无凭据日志。相同公开语法题：`There's a new car in front of my sister and I.`，询问标准英语该使用 I 还是 me。相同提示、无图片、无历史；先预热，每种配置两轮，第二轮反转模型顺序。基线使用正式 0.2.69 内置引擎，优化使用打包后的新引擎。

| 模型 | 原默认首字中位数 | 关闭／最少思考首字中位数 | 总耗时中位数 |
| --- | ---: | ---: | ---: |
| deepseek-flash | 3.76 s | 1.04 s | 4.51 s → 1.73 s |
| gpt-6.1-sol | 2.20 s | 2.93 s | 3.43 s → 4.68 s |
| claude-sonnet-5-5 | 1.54 s | 1.65 s | 4.94 s → 4.18 s |

12 次请求全部成功，均正确建议改为 me。DeepSeek 首字约下降 72%；原默认响应还报告了 331／481 个推理 token。GPT 与 Claude 本轮没有首字改善，GPT 已报告 0 推理 token；不能据此承诺降低它们的服务端排队或网络耗时。仅每组两次，结果用于观察本次设置效果，不能作为稳定 SLA 或统计显著性结论。[逐次结果与统计](QUESTION_THINKING_PERFORMANCE.json)。

## 验证

- Swift 回归：190 项通过，warnings-as-errors；覆盖旧配置、强度与 Key 独立、设置加载保存、迟到的模型选择、菜单路由、预览与请求原文隔离。
- Python：37 项通过；实际 SDK 经过本地 HTTP 测试服务验证 DeepSeek／GPT／Claude 的请求参数与强度缓存，另含子进程、取消、流完整性、代理和用量统计测试。
- 原生界面：独立偏好域、假模型与模拟回答验证 150% 缩放、连续预览、长回答换行、强度切换、设置窗口与分组菜单打开设置。界面模拟耗时不计入上面的真实模型结果。
- 本机正式 App 已安装并启动 0.2.70；16 个内嵌 Mach-O 签名与 deep strict 校验通过，启动后常驻引擎已预热。生词文件与完整偏好文件在安装前、安装后及重新启动后 SHA-256 一致；旧 0.2.69 保留为可恢复备份。
- 未保证：所有第三方网关或未识别别名的思考控制、回答正确率、长时间服务端负载下的延迟。

## 相关文件

`VocabCaptureApp.swift`（菜单与参数）、`ScreenshotQuestionPanel.swift`（思考切换和预览）、`ScreenshotQuestionThinking.swift`、`ScreenshotQuestionPreferences.swift`、`ScreenshotQuestionModelSettings.swift`（独立强度设置）、`ScreenshotQuestionBackend.swift`、`LangChainQuestionTransport.swift`、`ScreenshotQuestionAPI.swift`、`question-engine/question_engine.py`（协议与服务参数），以及 Swift／Python 回归测试。复用已有配置、窗口刷新、取消和客户端缓存流程，没有引入新的模型调度层或依赖。
