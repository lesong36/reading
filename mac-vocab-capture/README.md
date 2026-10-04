# 拾词助手（macOS）

一个原生菜单栏应用：在任意支持文字选择的 App 中选中英文，按 `⌥⌘D`，生成语境释义并保存。

## 当前 MVP

- `⌥⌘D` 全局快捷键；
- 鼠标左右键在 0.22 秒内同时按下即可拾词（默认开启，可在菜单关闭）；
- `⌥⌘O` 截图 OCR 取词：框选图片或不可选文字后，在本机识别英文并确认目标词；
- 截图取词使用同一窗口完成选词、查词与保存：单击选择单词，拖动选择词组，释义自动显示，回车加入生词本后可继续选下一个词；
- 中文释义会先显示，词性、音标和说明随后补齐；完整结果校验通过后才允许保存。等待期间回车不会重启查询，同一原句、同一服务与模型的已完成查询可复用本次运行的缓存（最多 100 条）；
- 识别有误时，可修改目标词后重新查询，或点击“修正原文”编辑识别结果；保存反馈留在窗口内，云端同步在后台进行；
- Edge / Chrome 网页扩展：右键“拾词助手：查词”可从网页 DOM 精确取得选词所在句；
- 可在菜单中切换为 `⌃⌥D` 或 `⌃⌥W`；
- 菜单栏 →“取词方式”→“设置取词与截图快捷键…”可分别录制两个快捷键；截图可一键选用 `⌥D`、`⌃⌥S` 或原来的 `⌥⌘O`。设置会检查重复与系统注册冲突，保存失败或取消时保留原设置；
- 通过 macOS Accessibility 读取前台选区及其所在完整句子，读取失败时使用剪贴板；
- 调用任何 OpenAI-compatible `/chat/completions` API；
- 以与阅读器兼容的词条字段保存到 `~/Library/Application Support/VocabCapture/vocabulary.json`；
- 使用同一阅读达人账号登录后，将本机词库与 Supabase `reader_sync_state.vocabulary` 读、合并、写回；
- 预留了 macOS Service 的 `Info.plist` 定义，用于右键选词菜单。

## 本地开发

安装完整 Xcode 后，在本目录执行：

```bash
swift build
swift run
```

生成发布用 App 包（包含 Services 注册所需的 `Info.plist`）：

```bash
./scripts/package-app.sh
```

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

截图 OCR 使用 macOS 自带的区域截图工具，再在本机通过 macOS Vision OCR 识别；仅确认后的单词和必要语境会发送给 AI。

截图时建议包含完整句子。识别后，点词即会将该词与所在句发送给已配置的 AI 服务查询；只有按“加入生词本”或回车确认才保存。修改原文或目标词会作废旧释义，需重新查询。Esc 可退出截图或关闭取词窗口；重新截图后取消会回到原窗口。历史取词快捷键保持不变，截图默认仍为 `⌥⌘O`。

## 开发验证

```bash
swift test --scratch-path /tmp/vocab-capture-tests
swift build -c release
```

测试涵盖快捷键兼容与校验、词组/原句定位、流式释义与缓存语境隔离、查询取消与回车保护、普通选词预览、异步释义切换、修正与连续保存，以及同步过程中保留新增词条。若当前文件夹带有 Finder 元数据导致测试包签名失败，使用上述临时构建目录。

## Edge / Chrome 网页取句

浏览器不会总是将选词前后的 DOM 文本提供给 macOS 辅助功能。安装 `browser-extension/` 后，在网页中选中英文词或短语，右键选择「拾词助手：查词」，扩展会按网页选区截取所在完整句并唤起本机 App。安装步骤见 [browser-extension/README.md](browser-extension/README.md)。

## 尚未完成的发布前工作

- 以 Xcode App target 打包、签名和复制 `Resources/Info.plist`，使 Services 出现在系统菜单；
- 对接 Supabase 登录与“读-合并-写”同步，复用 `reader_sync_state.vocabulary`，避免覆盖阅读器并发新增的单词；
- 增加词条浏览、删除、撤销及 OCR 兜底。

不要把完整屏幕截图或所有剪贴板内容上传给 AI；只在用户显式触发后发送已确认的单词和最小必要语境。

Supabase 登录密码只用于换取认证 session，不会保存；session token 保存在 macOS Keychain。同步只更新该登录用户的 `vocabulary` 列，并按单词与时间戳合并，保留阅读器现有词条。

## 登录与同步

菜单栏「词」→「同步到阅读达人…」，输入与阅读达人相同的邮箱和密码，点击「登录并同步」。登录后，每次确认保存的生词会自动尝试同步；截图窗口先显示本机保存结果，云同步在后台完成。也可随时通过同一菜单手动同步。

登录凭据失效时，手动同步会直接打开重新登录窗口。生词仍保存在本机，重新登录后会一起同步。网络中断或服务暂时不可用时会保留登录凭据，恢复后可重试。多个同步请求会共用一次凭据刷新。
