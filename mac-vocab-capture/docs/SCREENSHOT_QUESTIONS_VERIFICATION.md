# 截图问一问试用验证

日期：2026-10-05；版本：0.2.59；平台：Apple Silicon macOS。

## 功能与范围

截图取词窗口新增“问一问…”，无需先选择单词即可询问整段 OCR 原文；选择词后会同时提供所选内容。支持流式文字回答、最近六轮完整问答、回车提交、建议问题、停止、失败重试和清空对话。原文或选词变化后取消旧请求并开始新对话。

默认只发送识别文字；勾选“参考原截图”后才发送图片，切换模式会清空旧对话。未识别到文字的截图也能进入问答，默认启用图片。生产应用把图片缩放为最长边不超过 1600 像素的 PNG，仅保存在内存中。配置的服务需要支持图像输入。问答不会保存生词或触发云端同步，当前没有语音入口。

## 自动化验证

`swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-ask-final-tests -Xswiftc -warnings-as-errors`：74 项测试全部通过，0 失败。

新增测试覆盖文本与图片请求、最近六轮历史、SSE 分片和中文、非流式响应、HTTP/格式错误、截断回答、取消任务、过期结果隔离、回车提交、输入保留、图片选择、修改来源和问答不保存生词。六个新建或修改的小型 Swift 文件严格格式检查通过，`git diff --check` 通过。发布构建与签名另在安装时校验。

## 原生系统联调

使用独立原生测试应用编译实际生产源文件，生成测试图片，再通过生产 OCRClient、OCRLookupPanel、ScreenshotQuestionPanel 和 ScreenshotQuestionClient 调用本机正在运行的模型。操作通过 CUA 完成；测试词库与用户词库隔离。没有使用用户截图或云端账号。

模型：本机 llama.cpp，Qwen3.6-35B-A3B Q6_K_P；服务报告支持 vision，不支持 audio。

合成原文：The researchers were cautious. Had they known about the contamination, they would have discarded the samples. 图片含左红、右蓝两个色块。

| 场景 | 首段可见 | 完整回答 | 验证结果 |
|---|---:|---:|---|
| 解释第二句为何省略 if | 887 ms | 2269 ms | 解释 had 倒装与 If they had known 的对应关系 |
| 回车追问补回 if 的句子 | 406 ms | 1726 ms | 返回完整句子，携带一轮历史 |
| 勾选原图，询问两个色块 | 1750 ms | 1901 ms | 回答红色和蓝色，图片实际进入请求 |
| 追问右边色块 | 286 ms | 402 ms | 回答蓝色，继续包含图片与一轮历史 |
| 要求详细语法解释 | 286 ms | 7594 ms | 长回答持续显示；完整时间随输出长度增加 |

上述时间是本机当次观测，不代表性能保证；图片追问可能受服务缓存影响。测试应用的图像直接编码合成图，生产路径另有缩放。停止按钮的点击发生在详细回答完成之后，原生联调未据此宣称中断成功；取消与重试行为由自动化测试验证。

界面截图检查：原生深色面板，来源、记录、输入与操作区无重叠或裁切；视觉评估 94/100，pass。参考原截图的视觉类别和风格，未进行像素一致比较。

## 实际限制

当前试用依赖已有 AI 服务与模型配置，没有新增依赖或改变模型设置。简单文字和图像问题可用，但回答仍需核对：首个解释使用“原句完整形式”措辞不够准确；详细语法回答把介词短语描述为宾语补足，分析也存在过度推断。此次没有验证复杂图表、跨截图对话或语音。

会话只保留在当前窗口，关闭来源窗口后结束；不提供持久会话或云端历史。图片和文字都发送到 AI 设置指定的服务，纯文字问答也会包含整段识别原文。

## 本机安装结果

发布构建成功，Apple Development 签名经 `codesign --verify --deep --strict` 校验。安装到 `~/Applications/拾词助手.app`，版本 0.2.59；安装前后词库与偏好文件哈希一致。旧版本已移到废纸篓，可恢复。临时测试应用和构建 App 已清理，避免重复登记。更新后目标可执行文件只有一个运行进程，无最近崩溃报告。

CUA 启动请求因菜单栏应用没有窗口而超时；随后通过目标进程路径确认启动成功。本机安装后的真实区域截图快捷键未再次自动化验证，问答系统联调使用上文独立原生测试应用。此试用尚未提交或发布到 GitHub Releases。

## 修改文件与复用

- `Sources/VocabCapture/ScreenshotQuestionClient.swift`：截图问答请求与流式读取。
- `Sources/VocabCapture/ScreenshotQuestionPanel.swift`：原生问答界面与会话状态。
- `Sources/VocabCapture/OCRLookupPanel.swift`、`VocabCaptureApp.swift`：截图入口、来源更新和图片缩放。
- `Tests/VocabCaptureTests/ScreenshotQuestionClientTests.swift`、`ScreenshotQuestionPanelTests.swift`、`OCRLookupPanelTests.swift`：请求、状态和原取词流程回归测试。
- `README.md`、`VERSION`、本记录：使用说明、版本与验证证据。

复用原 AI 设置、OCR、取词窗口及系统框架，没有新增依赖、独立账号或网络服务；词典释义和生词保存继续走已有流程。
