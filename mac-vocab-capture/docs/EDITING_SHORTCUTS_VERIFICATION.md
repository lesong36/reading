# 编辑快捷键修复（0.2.63）

2026-10-05，macOS / Apple Silicon。

## 原因与改动

原应用只安装了 NSStatusItem 菜单，没有 NSApplication.mainMenu。标准文本控件的菜单快捷键无法通过应用编辑菜单抵达第一响应者；因此右键粘贴可用时，⌘V 仍可能没有响应。

- `Sources/VocabCapture/ApplicationEditingMenu.swift`：统一创建标准编辑菜单。⌘V 粘贴、⌘C 复制、⌘X 剪切、⌘A 全选、⌘Z 撤销、⇧⌘Z 重做，target 均为 nil，使用 AppKit 默认响应链和验证。
- `Sources/VocabCapture/VocabCaptureApp.swift`：启动时安装 mainMenu，覆盖模型设置、提问、登录等原生输入控件。
- `Tests/VocabCaptureTests/ApplicationEditingMenuTests.swift`：菜单键位、真实菜单快捷键分发到响应链、普通字母输入不触发命令。
- `README.md`、`VERSION`：用法与版本。

使用同一系统编辑菜单，没有逐个替换输入框，没有新增键盘监听器或依赖。

## 验证

原生隔离验证应用采用生产模型设置面板、accessory 激活策略、隔离 UserDefaults 和内存凭据。修复前对空配置名称执行粘贴，文本无变化；修复后同一操作得到 `paste-shortcut-test`。随后 ⌘A + 粘贴替换为 `replacement-test`，⌘Z 恢复原文本。安全输入框粘贴无效测试占位文字后显示掩码；未保存配置、未写真实 Keychain、未读取用户密钥。

快捷键测试通过实际 NSMenu.performKeyEquivalent 分发至测试响应者，不访问系统剪贴板。命令行测试宿主没有可激活的 keyWindow，因此实际聚焦文本框的行为由上述原生窗口验证。

```sh
swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-multi-profile-tests -Xswiftc -warnings-as-errors
```

完整 **106 项测试、0 失败**，新文件严格格式检查与 `git diff --check` 通过。Release 构建与深度、严格签名校验通过。

已安装 `/Users/coty/Applications/拾词助手.app` 0.2.63，确认运行进程只有一个。安装前后生词 JSON 与偏好文件 SHA-256 相同。旧 0.2.62 应用保存在废纸篓可恢复。

本轮验证进程已停止；上轮用户填写密钥的旧验证应用保持不变。旧验证窗口使用旧二进制；应在正式应用中验证和使用修复。安全输入框的复制限制仍遵循 macOS 默认行为。全局取词/截图快捷键及各项真实云服务未在本轮重新测试。
