# Kimi、应用图标与默认模型验证（0.2.73）

2026-10-06，已安装到 `~/Applications/拾词助手.app`，当前选中 `deepseek-flash`。四个已有模型配置和生词文件保留。脱敏实测见 [JSON](KIMI_ICON_DEFAULTS_VERIFICATION.json)。

## Kimi K2.6

现有配置地址 `https://api.moonshot.cn/v1` 正确，实际失败是 HTTP 400：`invalid temperature: only 1 is allowed for this model`。应用原先统一发送 `temperature=0.2`，并且没有将“关闭思考”映射到 Kimi。

按照[官方参数参考](https://platform.kimi.com/docs/api/models-overview)与[思考模型说明](https://platform.kimi.com/docs/guide/use-thinking-models)，现在对官方 `api.moonshot.cn` / `api.moonshot.ai` 的 `kimi-k2.6` Chat Completions 调用：

- 省略 temperature，由服务按思考模式选择固定值。
- 关闭思考发送 `thinking.type=disabled`；低／中／高均发送 `enabled`，因为 K2.6 没有这三个推理强度档位；自动不发送思考参数。
- 关闭思考保留 900 token 输出上限；开启或自动使用 16384，避免推理消耗原 900 token 后没有完整正文。
- 通过既有 LangChain 的 extra_body 发送 Kimi 文档中的 `max_tokens`，避免适配器将它改名为 `max_completion_tokens`。
- Kimi 官方根地址自动补 `/v1`，已经填写完整 `/chat/completions` 路径时保留一次，不重复拼接。原服务地址与 Key 没有修改。

用现有 Key 在内存中发送公开语法题，未发送私人截图或生词：

| 调用路径 | 首个可见回答 | 总耗时 | 结果 |
|---|---:|---:|---|
| 新打包引擎 + Swift facade | 1.988 秒 | 4.564 秒 | 成功，正确解释介词后用 me |
| 安装后的正式引擎 + Swift facade | 1.352 秒 | 2.725 秒 | 成功，完整回答 |

这两次是兼容性验证，不是稳定速度基准。此次仅验证 Kimi K2.6；不声称 K3、K2.7 Code 等所有 Kimi 型号已完成兼容验证。未新增重试或修改用户网络选择。

## 默认模型

首次启动且没有保存配置或旧版问答状态时，建立并选中 DeepSeek Flash：服务地址 `https://api.deepseek.com`、模型 `deepseek-flash`，默认关闭思考。此操作仅写配置元数据，不读取或写入 Keychain；新安装仍需在应用里填写自己的 Key。

“新增配置”预填相同名称、地址和模型，API Key 保持空白，用户可以改为 Kimi 或其他服务。草稿在保存前不写入配置。已有模型和用户选择不被启动默认值覆盖，旧版迁移、明确沿用取词模型及异常配置的保护继续保留。当前已保存的默认选择确认是 DeepSeek Flash。

## 图标

采用蓝紫色圆角底、打开的书页与金色高亮选词图案。图标已在 Finder“显示简介”中实际显示，同时确认版本为 0.2.73。

- 原图：[AppIcon.png](../Resources/AppIcon.png)，由内置 imagegen 工具生成，透明背景。
- 打包使用现有 macOS sips 与 iconutil 生成 16–1024 像素的标准 iconset/icns，无新增依赖。
- `CFBundleIconFile` 指向包内 `Contents/Resources/AppIcon.icns`。

生成提示词：

> Use case: logo-brand. Asset type: final macOS application icon PNG for Chinese vocabulary helper 拾词助手, an app for capturing words from screen and asking language questions. Create one polished native macOS app icon: a soft rounded square in deep indigo and blue-violet, with a bold ivory open-book symbol in the center and a small amber highlight selection rectangle across one line on the right page; subtle dimensional shading and crisp large shapes that remain legible at 32 pixels. Front-on centered composition, icon fills about 84 percent of a square canvas, fully transparent outside the rounded square silhouette. No text, letters, slogans, watermarks, extra objects, or surrounding scene. Calm premium productivity app aesthetic.

## 验证与改动

- 197 项 Swift 测试通过，编译警告视为错误；43 项 Python 测试通过，冻结的引擎通过同样 43 项；安装后的引擎通过 5 项进程测试。
- strict Swift 格式、Python 语法、shell 语法及 git diff 空白检查通过。
- 模拟设置 App 验证首次默认选择、新增配置预填、全部字段和底部操作可见；模拟 App 不读取真实 Key。
- 原位安装 0.2.73；安装与启动前后偏好和生词文件哈希一致。Apple Development 深度严格签名校验通过，包括 Finder 查看图标后再次校验。
- 旧 0.2.72 安装包保留在废纸篓，可恢复。主程序运行已用实际进程确认；无窗口的菜单栏 App 的 AX 查询超时不作为启动失败。
- 初次 Swift 测试遇到同步目录中的 Finder metadata 签名错误，换用 `/tmp` 构建目录后全部通过；不是业务测试失败。

修改文件：`question-engine/question_engine.py`、`ScreenshotQuestionAPI.swift`、`ScreenshotQuestionThinking.swift`、`ScreenshotQuestionPreferences.swift`、`ScreenshotQuestionModelSettings.swift`、`VocabCaptureApp.swift`、相关 Swift/Python 测试、`Resources/AppIcon.png`、`Resources/Info.plist`、`scripts/build-app-icon.sh`、`scripts/package-app.sh`、`VERSION`、`README.md` 及本记录。复用既有模型配置和客户端，通过省略不兼容参数和使用现有打包工具完成；没有新增依赖。未提交、推送或发布 GitHub Release。
