# 问一问多模型配置验证（0.2.62）

日期：2026-10-05；平台：macOS / Apple Silicon。

## 使用方式

菜单栏“问一问模型设置…”或问答窗口“模型设置…” → “新增配置”，填写名称、Base URL、模型名及 Key → “保存并使用”。可重复添加多个配置。问答窗口“问答模型”菜单直接切换，或选择“沿用取词模型”。切换保留输入中的问题，取消当前回答并清空旧对话；下次启动保留当前选择。

设置中选择已有配置可编辑。点击“删除配置”后再点击“确认删除”才移除配置与其 Key；删除当前配置时沿用取词模型。取消表单不保存编辑内容。

## 实现与简化

- `Sources/VocabCapture/ScreenshotQuestionPreferences.swift`：多个命名配置及选中 ID 以单个无密钥 JSON 保存；旧配置按需迁移为 `legacy` / “原问答模型”，保持启用状态。构造偏好对象不写设置、不读密钥。移除原单模型 `save` / `savedConfiguration` 包装。
- `Sources/VocabCapture/KeychainStore.swift`：每个新配置使用独立 UUID 账户；迁移配置沿用原问答 Keychain 账户，无需读取或复制密钥。密钥保存、删除成功后才改变元数据。取词与登录账户不变。
- `Sources/VocabCapture/ScreenshotQuestionModelSettings.swift`：管理命名配置、校验、编辑和删除；保存失败保持表单和原设置。
- `Sources/VocabCapture/ScreenshotQuestionPanel.swift`：模型切换菜单、刷新配置、停止旧回答；提问前核对可见选择，防止原生菜单动作延迟导致请求发给旧模型。保留自动换行逻辑。
- `Sources/VocabCapture/OCRLookupPanel.swift`、`VocabCaptureApp.swift`：将同一偏好对象接入设置、问答及实际请求。
- 三个相关测试文件：迁移、密钥隔离、持久化、失败保留、删除确认、切换取消、迟到结果拒绝和菜单动作延迟回归测试。
- `README.md`、`VERSION`：用法与 0.2.62 版本。

## 验证证据

```sh
swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-multi-profile-tests -Xswiftc -warnings-as-errors
```

最终全套 **103 项测试、0 失败**；包含 17 项偏好测试、6 项设置测试、13 项问答面板测试。新增与修改的小文件严格 Swift 格式检查通过，`git diff --check` 通过。Release 打包成功，正式应用深度、严格签名校验通过。

使用隔离 UserDefaults 和内存凭据的原生验证应用，通过实际生产设置面板、问答面板及流式请求客户端，配合仅监听 `127.0.0.1` 的模拟服务：

| 操作 | 实际请求路径 | 请求模型 |
|---|---|---|
| 选择快速问答 | `/fast/v1/chat/completions` | `fast-test-model` |
| 新增并保存第三个命名配置 | `/third/v1/chat/completions` | `third-test-model` |
| 默认沿用取词模型 | `/dictionary/v1/chat/completions` | `dictionary-test-model` |

这些请求的 Authorization 均为空；记录只含路径、模型名、历史轮数和授权是否存在。新增配置成功后，问答菜单即时显示该名称。切换后新请求不包含上个模型的对话，迟到回调由测试验证不会写回。

原生菜单显示选择早于回调的现象在验证中复现，新增提交前同步与独立回归测试覆盖。完整 UI 截图检查：问答 97/100、设置 95/100，原生风格、宽度及可读性通过。后续原生操作接口出现超时，未把这一轮作为所有菜单逐项操作或全局截图快捷键的验证。

本机已更新 `/Users/coty/Applications/拾词助手.app` 为 0.2.62，确认正式可执行文件只有一个运行进程。安装前后生词 JSON 与应用偏好文件 SHA-256 相同。旧 0.2.61 应用移至废纸篓可恢复。

本轮模拟服务与新验证应用进程已停止；代码、日志留在 `/tmp/vocab-question-profiles-system/`。上一轮用户填写了真实 Key 的验证窗口 `/tmp/vocab-question-model-system/问答模型设置验证.app` 保持运行，未读取、导出或删除其中密钥。

## 限制

云服务的真实模型名、鉴权及图像支持由服务决定，本轮未逐个验证真实云模型或新增真实 Keychain 密钥。问答仍使用 OpenAI 兼容接口，图像问题需所选模型支持图像；切换模型不能保证答案正确。上一轮隔离验证窗口中填写的 Key 仍需用户在正式应用设置中重新填写，未自动转移。
