# 拾词助手（macOS）

一个原生菜单栏应用：在任意支持文字选择的 App 中选中英文，按 `⌥⌘D`，生成语境释义并保存。

## 当前 MVP

- `⌥⌘D` 全局快捷键；
- 鼠标左右键在 0.22 秒内同时按下即可拾词（默认开启，可在菜单关闭）；
- `⌥⌘O` 截图 OCR 取词：框选图片或不可选文字后，在本机识别英文并确认目标词；
- Edge / Chrome 网页扩展：右键“拾词助手：查词”可从网页 DOM 精确取得选词所在句；
- 可在菜单中切换为 `⌃⌥D` 或 `⌃⌥W`；
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

生成可打开的 App 包（包含 Services 注册所需的 `Info.plist`）：

```bash
./scripts/package-app.sh
open build/拾词助手.app
```

日常使用应安装到固定位置（不要从 `build/` 目录反复启动，以免 macOS 创建多个启动台条目）：

```bash
./scripts/install-app.sh
```

## 版本与签名

- `VERSION` 是唯一版本来源；应用包的版本号从这里生成。
- 每次发布前运行 `./scripts/bump-version.sh patch`（或 `minor` / `major`），再运行 `./scripts/install-app.sh`。
- 应用只从 `~/Applications/拾词助手.app` 启动；构建产物会在安装后删除，避免启动台发现多个历史副本。
- 发布脚本会自动使用钥匙串中的 Apple Development 证书；也可通过 `VOCAB_CAPTURE_SIGNING_IDENTITY` 指定签名身份。这是跨版本稳定保留 macOS 辅助功能授权的正式发布方案。

首次使用时，在菜单栏图标中配置 API Base URL、模型与 Key（Key 保存到 macOS Keychain）；随后在「系统设置 → 隐私与安全性 → 辅助功能」授予“拾词助手”权限。

截图 OCR 使用 macOS 自带的区域截图工具，再在本机通过 macOS Vision OCR 识别；仅确认后的单词和必要语境会发送给 AI。

## Edge / Chrome 网页取句

浏览器不会总是将选词前后的 DOM 文本提供给 macOS 辅助功能。安装 `browser-extension/` 后，在网页中选中英文词或短语，右键选择「拾词助手：查词」，扩展会按网页选区截取所在完整句并唤起本机 App。安装步骤见 [browser-extension/README.md](browser-extension/README.md)。

## 尚未完成的发布前工作

- 以 Xcode App target 打包、签名和复制 `Resources/Info.plist`，使 Services 出现在系统菜单；
- 对接 Supabase 登录与“读-合并-写”同步，复用 `reader_sync_state.vocabulary`，避免覆盖阅读器并发新增的单词；
- 增加词条浏览、删除、撤销及 OCR 兜底。

不要把完整屏幕截图或所有剪贴板内容上传给 AI；只在用户显式触发后发送已确认的单词和最小必要语境。

Supabase 登录密码只用于换取认证 session，不会保存；session token 保存在 macOS Keychain。同步只更新该登录用户的 `vocabulary` 列，并按单词与时间戳合并，保留阅读器现有词条。
