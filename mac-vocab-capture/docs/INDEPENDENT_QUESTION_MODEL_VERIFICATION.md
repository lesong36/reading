# 独立问答模型设置验证

日期：2026-10-05；版本：0.2.61。

## 行为

“问一问”窗口右上角新增“模型设置…”，菜单栏新增“问一问模型设置…”。可独立填写 OpenAI 兼容服务地址、模型名、API Key；取词释义继续使用原配置。默认未启用独立模型，沿用当前取词设置。关闭独立选项会保留其配置，便于再次启用。

保存成功会取消旧问答并清空旧历史；输入中的问题保留。旧模型的迟到回调不能进入新对话。取消、关闭窗口、非法 URL/模型或 Keychain 保存失败不会覆盖原配置。独立配置已启用但缺失时会报配置错误，不悄悄改用另一服务。

## 配置与凭据隔离

服务和模型等元数据写入独立 UserDefaults 键，编码的 apiKey 始终为空。问答 Key 使用 Keychain 独立账户 screenshot-question-api-key；取词账户和阅读达人登录账户保持原有逻辑。保存时先写 Keychain，成功后才写元数据和启用状态。问答账户更新采用 SecItemUpdate，不存在时才新增；空 Key 只删除问答账户。

启用独立设置时不会求值字典配置或读取字典 Key；关闭时才读取回退配置。没有新增依赖。

## 验证

完整套件 94 项测试通过，0 失败，warnings-as-errors 编译与修改的八个小型 Swift 文件严格格式检查通过。新增测试覆盖模式切换、设置和 Key 隔离、无密钥元数据、Key 保存失败、禁用保留设置、缺失/损坏配置、字典配置延迟求值、URL/模型校验、取消/关闭、直接菜单 target、模型切换后旧请求隔离和输入保留。

偏好测试全部使用注入的内存凭据及独立 UserDefaults，没有写真实 Keychain。Keychain 的真实账户写入未做自动化验证，只检查隔离查询和编译；正式应用使用既有稳定签名。

原生联调使用生产问答/设置/偏好/请求类与独立测试应用。先用本机隔离 HTTP 服务验证默认字典路由，并通过界面启用、填写和保存独立设置，确认对话重置。用户随后自行在验证窗口填入 DeepSeek 服务和模型并保存；建议问题获得该配置下的实际回答。该次来源为合成测试句子。密钥字段始终遮蔽，未读出、导出或写入聊天和日志；验证程序使用内存凭据，该 Key 尚未写入正式应用。

首次测试应用因套件名等于自身 bundle id 导致 UserDefaults 初始化失败，改为独立测试套件后成功；不是生产路径的崩溃。CUA 截图确认新设置表单与问答入口无重叠或水平裁切，视觉评估 93/100，pass。

## 限制

独立模型配置解决的是请求路由与选择能力，不能保证所选模型语法准确。没有自动获取模型列表、比较模型准确率或自动回退到其他服务。图像输入需服务与模型支持，当前没有语音。

用户填写 Key 的验证窗口暂时保留，避免丢失其输入。正式版安装后须在正式入口重新填写 Key；应用不会从测试密码字段读取或复制凭据。默认配置继续沿用取词，尚未替用户启用正式版云端设置。

## 修改文件

- Sources/VocabCapture/ScreenshotQuestionModelSettings.swift：独立设置窗口与校验。
- Sources/VocabCapture/ScreenshotQuestionPreferences.swift、KeychainStore.swift：配置与 Key 隔离。
- Sources/VocabCapture/VocabCaptureApp.swift、OCRLookupPanel.swift、ScreenshotQuestionPanel.swift：菜单、窗口入口、请求路由及模型切换后的取消和历史重置。
- Tests/VocabCaptureTests/ScreenshotQuestionModelSettingsTests.swift、ScreenshotQuestionPreferencesTests.swift、ScreenshotQuestionPanelTests.swift：回归与隔离测试。
- README.md、VERSION、本记录：使用说明、版本与验证证据。

复用现有 AIConfiguration、OpenAI 兼容请求和 AppKit 设置模式，无额外模型服务、SDK 或依赖。

## 本机安装

发布构建与严格签名校验成功，正式版 0.2.61 安装于 ~/Applications/拾词助手.app，旧 0.2.60 在废纸篓中可恢复。安装前后词库和偏好文件哈希一致；默认仍沿用取词设置。更新后正式应用只有一个运行进程，无最近崩溃报告。CUA 启动因菜单栏应用没有窗口而超时，已通过目标进程确认启动。

验证应用未结束，也未删除其文件，以保留用户在测试窗口填写的凭据；已取消其 LaunchServices 登记。凭据仍仅在该验证进程内存中，关闭进程后会丢失。正式应用的设置需用户自行填写，未自动迁移密码字段。临时本机隔离 HTTP 服务暂时保留，后续完成正式配置后可一并清理。安装后正式菜单/截图热键未再次自动化验证，入口、回调和模型路由通过上文测试验证。未提交或发布 GitHub Release。
