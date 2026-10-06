# 独立截图问一问快捷键验证

日期：2026-10-05。正式安装版本：0.2.66。

## 使用

默认全局组合键为 **⌥⌘A（Option + Command + A）**。框选截图后，本机 OCR 完成即直接打开“截图问一问”，聚焦问题输入框。无需先经过取词窗口，也不会在打开窗口时自动发送 AI 请求。

菜单栏有独立“截图问一问”入口。在“取词方式 → 设置取词与截图快捷键…”中可以分别录制选词、截图取词、截图问一问的快捷键。

已有选词和截图取词设置保持不变。新默认与已有两个组合键冲突时，读取时自动回退到 ⌥⌘Q 或 ⌃⌥A；仅读取旧配置不写入偏好。保存时检查三个快捷键是否重复，并尝试系统注册；注册失败不保存设置，取消后恢复已保存的热键。启动时保留成功注册的热键，并指出失败组合。

## 实现文件

- `Sources/VocabCapture/CaptureShortcuts.swift`：第三组合键、持久化、兼容回退、录制与校验。
- `Sources/VocabCapture/VocabCaptureApp.swift`：第三个 Carbon 热键、菜单入口，复用原生截图与 OCR 流程，独立问答窗口与模型设置更新。
- `Sources/VocabCapture/OCRLookupPanel.swift`：截图前隐藏取词及其问答窗口，取消时恢复原先可见窗口。
- `Sources/VocabCapture/main.swift`：显式保留应用委托直到事件循环结束。
- `Tests/VocabCaptureTests/CaptureShortcutTests.swift`、`CaptureShortcutSettingsTests.swift`、新增 `CaptureQuestionShortcutSettingsTests.swift`、`DirectScreenshotQuestionTests.swift`：偏好迁移、第三行录制、失败重试、直接问答、无文字图片、草稿恢复及窗口切换。
- `README.md`、`VERSION`、本记录：使用说明及版本。

复用同一截图、OCR 和问答客户端，未新增依赖。

## 验证证据及边界

- `swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-multi-profile-tests -Xswiftc -warnings-as-errors`：**141 项测试，0 失败**，包含本次新增 17 项。
- 快捷键实现、新增及修改快捷键测试、直接问答测试、启动入口的严格 Swift 格式检查通过；原有大型 AppKit 文件未整篇重排。`git diff --check -- mac-vocab-capture` 通过。
- 发布构建成功。安装包通过 `codesign --verify --deep --strict`；正式安装位置为 `/Users/coty/Applications/拾词助手.app`，版本 0.2.66。
- 隔离原生界面测试中，三行录制器均可见、未裁切；第三行从 ⌥⌘A 修改为 ⌃⌥Q 并保存，另外两行不变。使用测试偏好，未修改真实快捷键。
- 复用正式 AppDelegate 的系统测试入口成功启动 `/usr/sbin/screencapture` 原生区域截图进程。自动化工具发送的组合键未触发该系统路径，且框选操作返回 `noWindowsAvailable`，因此**物理全局按键 → 实际框选 → 问答的整条路径尚未完成系统实测**。
- 后续流程使用公开文字绘制的截图原图，调用真实 `OCRClient.recognize`，再进入正式问答展示路径。实际界面显示识别原文、模型选择器及已聚焦的“提问内容”输入框，没有中间取词窗口，也没有自动 AI 请求。该测试验证 OCR 与窗口衔接，不替代真实系统框选。
- 单元测试确认：取消时仅恢复原先可见窗口并保留草稿；无文字截图默认选中“参考原截图”；取词与问答切换关闭旧窗口，重新截图使用新语境。
- 安装前后生词本 JSON 和正式应用偏好 plist 的 SHA-256 均保持一致；未读取、导出或修改 API Key。旧版 0.2.65 保留在废纸篓中以便回退。

剩余验证项：实际按下 ⌥⌘A 并完成系统框选，核对它在常用前台应用中的触发行为。若被其他软件拦截或占用，可在第三行改为其他组合键。
