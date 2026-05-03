# 英语长难句阅读器交付说明

推荐客户使用入口：

1. `~/Applications/英语长难句阅读器.app`
2. 如果需要从项目目录直接启动，可双击 `启动英语长难句阅读器.command`

当前约定：

- `~/Applications/英语长难句阅读器.app` 是唯一正式安装入口
- 仓库内历史 `.app` 副本已改名为 `.app.disabled`，避免被 Launchpad 重复收录

核心文件：

- `英语长难句交互阅读解析.html`
  正式单文件页面源码。
- `~/Applications/英语长难句阅读器.app/Contents/Resources/index.html`
  已安装到 Launchpad / Applications 的实际运行页面。
- `英语长难句阅读器.app.disabled/Contents/Resources/index.html`
  仓库内保留的历史 app 包资源，仅作备份，不再作为 Launchpad 入口。

## 更新规则

只改源码文件不够。每次改完页面后，必须至少同步正式安装版 app，否则双击 Launchpad 图标仍可能打开旧界面。

需要同步的目标：

1. 仓库源码：`英语长难句交互阅读解析.html`
2. 已安装 app 资源：`~/Applications/英语长难句阅读器.app/Contents/Resources/index.html`

可选同步：

3. 仓库归档 app 资源：`英语长难句阅读器.app.disabled/Contents/Resources/index.html`

## 为什么之前会出现“app 里还是旧界面”

原因有两层：

1. `.app` 实际打开的是它自己包内的 `Contents/Resources/index.html`，不是仓库里的源码 HTML。
2. 启动地址固定为 `http://127.0.0.1:8765/index.html`，浏览器可能继续复用旧缓存页面。

当前修复：

- app 的 `launcher` 已改为启动时自动附带版本参数：
  `http://127.0.0.1:8765/index.html?v=<mtime>`
- 项目目录启动脚本也做了同样处理：
  `...?v=<mtime>`
- `.app` 版本号已升到 `CFBundleShortVersionString=1.1`、`CFBundleVersion=2`

## 为什么 Launchpad 里会出现多个图标

原因通常不是一个 app 生成了多个图标，而是系统索引到了多个同名 `.app`：

1. `~/Applications/英语长难句阅读器.app`
2. 项目目录中的 `英语长难句阅读器.app`
3. 旧版本目录中的同名 `.app`

只要这些 `.app` 都还保留 `.app` 后缀，Launchpad / Spotlight 就可能把它们都当成独立应用展示。

当前处理：

- 保留正式安装入口：`~/Applications/英语长难句阅读器.app`
- 仓库内副本改名为 `.app.disabled`
- 后续如果还需要保留历史包，继续用 `.app.disabled` 或压缩包形式归档，不要保留可识别的 `.app`

## 如果以后更新后看不到新界面

按这个顺序排查：

1. 确认已经把源码同步到了两个 `.app` 的 `index.html`
2. 关闭旧的阅读器页面标签
3. 重新双击 `~/Applications/英语长难句阅读器.app`
4. 如果 Launchpad 仍出现多个图标，先确认项目目录中是否还有未改名的同名 `.app`
5. 如果仍异常，再检查 app 内实际页面是否包含目标文本，例如：
   `OpenAI-compatible`
6. 再检查启动器 URL 是否带了 `?v=...`

## 当前模型设置预期

当前前端应当能看到：

1. `Ollama`
2. `OpenAI-compatible`

其中 `Ollama` 提供两套预设：

- 本地：`http://127.0.0.1:11434`
- 远程 NV：`http://100.121.25.47:11434`

`OpenAI-compatible` 提供可编辑的：

- API Key
- Base URL
- Model
