# 拾词助手（macOS）

一个原生菜单栏应用：在任意支持文字选择的 App 中选中英文，按 `⌥⌘D`，生成语境释义并保存。

## 当前 MVP

- `⌥⌘D` 全局快捷键；
- 通过 macOS Accessibility 读取前台选区及其所在完整句子，读取失败时使用剪贴板；
- 调用任何 OpenAI-compatible `/chat/completions` API；
- 以与阅读器兼容的词条字段保存到 `~/Library/Application Support/VocabCapture/vocabulary.json`；
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
- 若在 Xcode 登录 Apple Developer 并获得 Apple Development 证书，可设置 `VOCAB_CAPTURE_SIGNING_IDENTITY` 使用该证书签名；这是跨版本稳定保留 macOS 辅助功能授权的正式发布方案。

首次使用时，在菜单栏图标中配置 API Base URL、模型与 Key（Key 保存到 macOS Keychain）；随后在「系统设置 → 隐私与安全性 → 辅助功能」授予“拾词助手”权限。

## 尚未完成的发布前工作

- 以 Xcode App target 打包、签名和复制 `Resources/Info.plist`，使 Services 出现在系统菜单；
- 对接 Supabase 登录与“读-合并-写”同步，复用 `reader_sync_state.vocabulary`，避免覆盖阅读器并发新增的单词；
- 增加词条浏览、删除、撤销及 OCR 兜底。

不要把完整屏幕截图或所有剪贴板内容上传给 AI；只在用户显式触发后发送已确认的单词和最小必要语境。
