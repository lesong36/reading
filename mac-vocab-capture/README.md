# 拾词助手（macOS）

一个原生菜单栏应用：在任意支持文字选择的 App 中选中英文，按 `⌥⌘D`，生成语境释义并保存。

## 当前 MVP

- `⌥⌘D` 全局快捷键；
- 鼠标左右键在 0.22 秒内同时按下即可拾词（默认开启，可在菜单关闭）；
- `⌥⌘O` 截图 OCR 取词：框选图片或不可选文字后，在本机识别英文并确认目标词；
- `⌥⌘A` 直接截图问一问：框选后打开问答窗口，输入问题或选择快捷问题；
- 截图取词使用同一窗口完成选词、查词与保存：单击选择单词，拖动选择词组，释义自动显示，回车加入生词本后可继续选下一个词；
- 中文释义会先显示，词性、音标和说明随后补齐；完整结果校验通过后才允许保存。等待期间回车不会重启查询，同一原句、同一服务与模型的已完成查询可复用本次运行的缓存（最多 100 条）；
- 识别有误时，可修改目标词后重新查询，或点击“修正原文”编辑识别结果；保存反馈留在窗口内，云端同步在后台进行；
- 截图窗口的“问一问…”支持文字提问、流式回答和连续追问；可选用识别原文或原截图作为依据；
- Edge / Chrome 网页扩展：右键“拾词助手：查词”可从网页 DOM 精确取得选词所在句；
- 可在菜单中切换为 `⌃⌥D` 或 `⌃⌥W`；
- 菜单栏 →“取词方式”→“设置取词与截图快捷键…”可分别录制选词、截图取词、截图问一问三个快捷键；截图可一键选用 `⌥D`、`⌃⌥S` 或原来的 `⌥⌘O`。设置会检查重复与系统注册冲突，保存失败或取消时保留原设置；
- 通过 macOS Accessibility 读取前台选区及其所在完整句子，读取失败时使用剪贴板；
- 调用任何 OpenAI-compatible `/chat/completions` API；
- 以与阅读器兼容的词条字段保存到 `~/Library/Application Support/VocabCapture/vocabulary.json`；
- 使用同一阅读达人账号登录后，将本机词库与 Supabase `reader_sync_state.vocabulary` 读、合并、写回；
- 预留了 macOS Service 的 `Info.plist` 定义，用于右键选词菜单。

## 本地开发

安装完整 Xcode 和 [uv](https://docs.astral.sh/uv/getting-started/installation/) 后，在本目录执行：

```bash
swift build
./scripts/build-question-engine.sh
swift run
```

生成发布用 App 包（包含 Services 注册所需的 `Info.plist`）：

```bash
./scripts/package-app.sh
```

打包脚本从 `question-engine/uv.lock` 安装锁定依赖，将 LangChain 1.4.3、模型适配库和 Python 运行时一起放入 App。安装发布包的用户无需另外安装 Python 或 uv。开发时更改 Python 引擎后，需要重新运行 `build-question-engine.sh`。

`build/` 中的 App 仅用于压缩发布，不要直接打开；macOS 可能将它额外登记到启动台。

日常使用应安装到固定位置（不要从 `build/` 目录反复启动，以免 macOS 创建多个启动台条目）：

```bash
./scripts/install-app.sh
```

## 版本与签名

- `VERSION` 是唯一版本来源；应用包的版本号从这里生成。
- 每次发布前运行 `./scripts/bump-version.sh patch`（或 `minor` / `major`），再运行 `./scripts/install-app.sh`。
- 应用只从 `~/Applications/拾词助手.app` 启动；构建产物会在安装后删除，避免启动台发现多个历史副本。
- 发布脚本会自动使用钥匙串中的 Apple Development 证书；也可通过 `VOCAB_CAPTURE_SIGNING_IDENTITY` 指定签名身份。这是跨版本稳定保留 macOS 辅助功能授权的正式发布方案。

## 安装发布包

从 GitHub Releases 下载同一版本的两个附件：

- `拾词助手-<版本>-macOS.zip`：解压后把“拾词助手”拖入“应用程序”或 `~/Applications`，再打开一次；首次使用按提示授予“辅助功能”权限。
- `拾词助手-网页取句扩展.zip`：解压后，在 Edge 的 `edge://extensions` 或 Chrome 的 `chrome://extensions` 中打开“开发人员模式”，选择“加载解压缩的扩展”，并选择解压后的文件夹。

网页扩展仅将当前选区及其所在句短暂传给本机的拾词助手，不会上传网页内容。

首次使用时，在菜单栏图标中配置 API Base URL、模型与 Key（Key 保存到 macOS Keychain）；随后在「系统设置 → 隐私与安全性 → 辅助功能」授予“拾词助手”权限。

截图 OCR 使用 macOS 自带的区域截图工具，再在本机通过 macOS Vision OCR 识别。查词发送目标词和所在句；“问一问”发送问题、识别原文和最近六轮完整对话。只有勾选“参考原截图”后，问答请求才包含图片；没有识别文字时会默认使用图片。

截图时建议包含完整句子。识别后，点词即会将该词与所在句发送给已配置的 AI 服务查询；只有按“加入生词本”或回车确认才保存。修改原文或目标词会作废旧释义，需重新查询。Esc 可退出截图或关闭取词窗口；重新截图后取消会回到原窗口。历史取词快捷键保持不变，截图默认仍为 `⌥⌘O`。

## 截图问一问（试用）

问答通过 App 内置的常驻 LangChain 1.4.3 引擎调用所选模型，启动时预热，后续问题复用进程和模型连接。截图、OCR 与问答窗口仍使用 macOS 原生实现；不额外启用跟踪服务或云端中转。迁移与验证见 [LangChain 实施记录](docs/LANGCHAIN_MIGRATION.md)。

0.2.68 起，问答引擎遵守 macOS 手动 HTTP/HTTPS 系统代理与绕过规则，代理变化后使用新客户端；回环服务直连。网络异常与真实 HTTP 错误分别提示。最新真实调用对照见 [LangChain 性能复测](docs/LANGCHAIN_CLOUD_PERFORMANCE.md)。

可直接按全局热键 `⌥⌘A`（Option + Command + A）框选截图，无需先选词。识别完成后直接进入问答窗口，并聚焦问题输入框；只有提交问题后才调用 AI。菜单栏也有独立的“截图问一问”入口。取消截图会恢复原先可见窗口并保留问题草稿。

在“快捷键与取词 → 设置取词与截图快捷键…”中修改“截图问一问”组合键。升级时保留已有选词和截图取词设置；若原设置占用了默认新组合键，会自动选择与它们不同的默认值。若其他应用占用某个热键，启动时提示具体冲突，同时保留其他可用热键。实现及系统测试边界见[独立热键验证记录](docs/DIRECT_SCREENSHOT_QUESTION_SHORTCUT.md)。

截图后点击底部“问一问…”，输入问题并按回车。可以先选词，再问“这个词在这里是什么意思”，也可以直接分析整段文字，并继续追问。默认三个快捷问题可快速解释内容、分析句子或总结要点。点击「编辑快捷问题…」可新增、编辑或删除，最多 5 个；按钮名称与完整提问分别保存。支持 `⌘+` / `⌘−` 缩放阅读文字、`⌘0` 恢复，并记住比例。回答下方显示首字延迟、总耗时、输出 token 数及平均 TPS；TPS 按输出 token 数除以整个请求耗时（含等待），服务未返回用量时显示 `—`。详见[问答界面设置与统计口径](docs/QUESTION_UI_CUSTOMIZATION.md)。

“问一问”窗口右上角“模型设置…”或菜单栏“模型与服务 → 问一问模型设置…”可以预先保存多个命名配置。点击“新增配置”，填写名称、服务地址、模型名称与 API Key，再点击“保存并使用”。每个配置可以使用不同服务，Key 分别保存在本机 Keychain。选择已有配置可编辑；删除需再次点击“确认删除”。原来的独立问答配置自动迁移为“原问答模型”，保留启用状态和原 Key。

问答窗口上方“问答模型”下拉菜单可直接切换已保存的配置，也可选择“沿用取词模型”。当前选择会保留到下次启动。切换或保存配置会停止当前回答并开始新对话，输入中的问题会保留；取词释义继续使用原设置。

0.2.73 起，首次使用默认选择 DeepSeek Flash，新增配置预填 `https://api.deepseek.com` / `deepseek-flash`，仍需填写自己的 API Key；已有选择保持。支持官方 Kimi K2.6（`https://api.moonshot.cn/v1` / `kimi-k2.6`）：省略固定温度参数，可关闭思考；低／中／高均为开启。安装包包含正式应用图标。实测、生成说明与验证见[Kimi、图标与默认模型记录](docs/KIMI_ICON_DEFAULTS_VERIFICATION.md)。

0.2.72 起，模型设置可勾选“此模型直连（跳过系统 HTTP 代理）”，各模型独立保存，默认继续使用系统代理。直连不修改系统代理、VPN 或 TUN；失败后可取消勾选再重试。当前 Mac 的 DeepSeek 三轮对照首字中位数从 1.36 秒降到 0.51 秒，安装后一次实际调用为 1.11 秒；GPT、Claude 保持系统路径。样本与边界见[网络路径性能验证](docs/QUESTION_NETWORK_PERFORMANCE.md)。

0.2.71 起，问答 HTTP 空闲连接保留 120 秒，减少输入追问后重新握手的机会；上游仍可能排队或主动断开。耗时拆解和未采用的提示词实验见[连接复用与延迟诊断](docs/QUESTION_CONNECTION_PERFORMANCE.md)。

0.2.70 起，模型旁可选择思考强度（自动、关闭／最少思考、低、中、高），各模型独立记忆，默认优先速度。不支持完全关闭的模型使用最低强度；无法识别的模型保留服务默认。原文预览合并 OCR 固定行尾并自动重排。实际参数、兼容范围和延迟对照见[思考设置与性能复测](docs/QUESTION_THINKING_PERFORMANCE.md)。

支持 Chat Completions、OpenAI Responses 和 Anthropic Messages 三种接口。设置中的“接口协议”默认自动识别：aicodewith 的 Claude 使用 Messages、GPT 使用 Responses，其他服务使用 Chat Completions；也可手动选择。旧配置自动使用这个默认值，保留原地址、模型和 Key。模型名称需按服务方提供的名称填写，图片输入还需要所选模型支持图像。模型配置不会保证答案正确。多配置验证见 [多模型切换验证](docs/QUESTION_MODEL_PROFILES_VERIFICATION.md)，接口与鉴权验证见 [原生接口验证](docs/NATIVE_QUESTION_API_VERIFICATION.md)。

回答区按窗口可见宽度换行，放大或缩小窗口会重新排版。当前本地模型在语法判定与纠错追问中已出现错误，提示改进不能保证正确；具体案例见 [换行与语法验证](docs/SCREENSHOT_QUESTION_FIXES.md)。

流式首段立即显示，后续按 60 毫秒合并刷新，完成或停止时保留最新文字。已保存的 GPT、Claude 和 DeepSeek 的真实调用延迟、阅读/语法检查与推理参数对照见 [模型性能验证](docs/QUESTION_MODEL_PERFORMANCE.md)。该对照测试没有修改已保存模型的推理设置。

需要理解图表、颜色或布局时，勾选“参考原截图”；所配置模型必须支持图像输入。切换图片模式、选中内容或修正原文会开始新对话。回答可随时停止，失败或停止的问题会恢复到输入框，便于重试。问答不会加入生词本；对话仅保留在当前窗口中，未加入云端同步。当前使用打字输入，尚未接入语音。

图片在内存中缩放至最长边不超过 1600 像素后发送给已配置的 AI 服务。纯文字问题默认不发送图片；实际发送位置由 AI 设置中的服务地址决定。实测与限制见 [截图问答验证记录](docs/SCREENSHOT_QUESTIONS_VERIFICATION.md)。

输入框支持 ⌘V 粘贴、⌘C 复制、⌘X 剪切、⌘A 全选、⌘Z 撤销和 ⇧⌘Z 重做。安全输入框的复制限制由 macOS 保持默认行为。

## 开发验证

```bash
swift test --scratch-path /tmp/vocab-capture-tests
swift build -c release
uv run --project question-engine --frozen --extra build python -m unittest discover -s question-engine/tests -v
```

测试涵盖快捷键兼容与校验、词组/原句定位、流式释义与缓存语境隔离、查询取消与回车保护、普通选词预览、异步释义切换、修正与连续保存，以及同步过程中保留新增词条；新增截图问答测试覆盖流式响应、连续追问、图片选择、取消与过期响应隔离。若当前文件夹带有 Finder 元数据导致测试包签名失败，使用上述临时构建目录。

## Edge / Chrome 网页取句

浏览器不会总是将选词前后的 DOM 文本提供给 macOS 辅助功能。安装 `browser-extension/` 后，在网页中选中英文词或短语，右键选择「拾词助手：查词」，扩展会按网页选区截取所在完整句并唤起本机 App。安装步骤见 [browser-extension/README.md](browser-extension/README.md)。

## 尚未完成的发布前工作

- 以 Xcode App target 打包、签名和复制 `Resources/Info.plist`，使 Services 出现在系统菜单；
- 对接 Supabase 登录与“读-合并-写”同步，复用 `reader_sync_state.vocabulary`，避免覆盖阅读器并发新增的单词；
- 增加词条浏览、删除、撤销及 OCR 兜底。

不要自动发送完整屏幕或所有剪贴板内容；问答仅分析用户框选的区域，图片输入由“参考原截图”控制。

Supabase 登录密码只用于换取认证 session，不会保存；session token 保存在 macOS Keychain。同步只更新该登录用户的 `vocabulary` 列，并按单词与时间戳合并，保留阅读器现有词条。

## 登录与同步

菜单栏「词」→「同步到阅读达人…」，输入与阅读达人相同的邮箱和密码，点击「登录并同步」。登录后，每次确认保存的生词会自动尝试同步；截图窗口先显示本机保存结果，云同步在后台完成。也可随时通过同一菜单手动同步。

登录凭据失效时，手动同步会直接打开重新登录窗口。生词仍保存在本机，重新登录后会一起同步。网络中断或服务暂时不可用时会保留登录凭据，恢复后可重试。多个同步请求会共用一次凭据刷新。
