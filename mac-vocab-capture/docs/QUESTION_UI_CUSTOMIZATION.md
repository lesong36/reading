# 问答快捷问题、缩放与性能栏

适用于 0.2.69 的「截图问一问」，包括直接截图入口和取词窗口中的问答入口。

## 快捷问题

点击「编辑快捷问题…」新增、编辑或删除，最多保存 5 个；也可以删除全部。
按钮名称与完整提问内容分别设置：按钮名称为单行，最多 20 个字符，内容支持多行。
空白名称或内容不能保存。保存后立即更新；取消或关闭设置窗口不会保存草稿。
首次使用保留「解释这段话」「分析句子结构」「总结要点」。
设置独立保存在本机 `VocabCapture.questionQuickPrompts`，不写入模型配置或 Keychain。
不同问答窗口再次打开时读取最新列表；运行中的回答不会因为编辑快捷问题而重新发送。

## 阅读缩放

- `⌘+`（也支持 `⌘=`）：放大原文、回答和问题输入框文字。
- `⌘−`：缩小文字。
- `⌘0`：恢复 100%。

范围为 75%–150%，本机记住缩放比例（`VocabCapture.questionZoomScale`）。
也可通过「显示」菜单操作。缩放时保留问题草稿和回答，不重新调用模型。
长回答随字体与窗口宽度重新换行；快捷按钮按可用宽度换行，必要时增加最小窗口高度。

## 性能参数口径

- **首字 / TTFT**：点击提问到首个非空、可见回答文本的时间。包含引擎启动、模型排队、网络等待；隐藏思考片段不计作可见回答。
- **总耗时**：点击提问到回答完成、失败或停止，使用本机单调时钟。
- **输出 tokens**：服务通过 SDK 返回的输出 token 数，可能包含思考 token。
- **平均 TPS**：上述输出 token 数除以整个请求耗时，包含等待，不是纯解码速度。

悬停性能栏可查看口径说明。用量仅显示 SDK 返回的真实计数；未提供时 TPS 显示 `—`，不使用字符数估算 token。
GPT Responses 与 Claude Messages 从流中的 usage metadata 读取。
Chat Completions 只对已确认支持的 `api.openai.com` / `api.deepseek.com` 请求 `include_usage`；其他网关不增加该参数、不为统计重试请求，若自行返回用量则照常显示。
每次提问重新计时和清空用量；旧请求的迟到回调不会覆盖新请求。清空对话、切换模型或截图会重置性能栏。
统计在本机展示，不启用 LangSmith 追踪。

## 验证

单元测试覆盖：快捷问题保存/取消/删除/5 项上限、完整问题提交、最长标题的按钮换行、缩放草稿保留与长回答重新排版、统计口径、未知用量、停止后迟到回调隔离。
SDK 模拟服务覆盖三种接口用量、Claude 累计用量去重及未知用量省略；同时验证冻结打包的 Python 引擎。
原生界面通过独立测试 App 验证新增、编辑、验证提示、保存立即生效及输入框聚焦时的快捷键；回答和 token 数为明确标注的本地模拟数据，不是云端性能测量。

本轮验证：185 项 Swift 测试全部通过（warnings-as-errors）；34 项 Python 测试通过；正式安装后的签名版引擎另有 4 项进程测试通过。原生窗口验证了五项上限、空白校验、保存立即生效、完整提问内容提交，以及输入框聚焦时 `⌘=` / `⌘−` / `⌘0`。
正式版本 0.2.69 已安装并启动于 `~/Applications/拾词助手.app`，深度严格签名验证通过；替换前后本机生词数据和设置文件哈希一致。

主要实现文件：

- `Sources/VocabCapture/ScreenshotQuestionPanel.swift`：按配置生成快捷按钮、阅读缩放、请求性能栏；性能栏定时刷新，不逐 token 重排界面。
- `ScreenshotQuestionQuickPrompts.swift` / `ScreenshotQuestionQuickPromptSettings.swift`：独立配置存储与编辑器，复用 AppKit 和现有设置模式。
- `ScreenshotQuestionPerformance.swift`：真实用量解析和统一统计口径。
- `LangChainQuestionTransport.swift` / `ScreenshotQuestionBackend.swift` / `question-engine/question_engine.py`：复用 SDK 用量，通过既有管道传回；没有增加依赖或统计专用模型请求。
- `ApplicationEditingMenu.swift` / `VocabCaptureApp.swift` / `OCRLookupPanel.swift`：缩放菜单与两种问答入口的连接；同文件两处循环按现有格式检查要求改用 `for`，行为不变。

边界：原生界面测试采用模拟回答；本轮没有重新测量云端模型性能。第三方服务未返回 token 用量时无法给出 TPS，显示 `—`。
