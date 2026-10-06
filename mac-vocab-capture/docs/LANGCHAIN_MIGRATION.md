# 截图问答迁移到 LangChain 1.4+

日期：2026-10-06。

目标：在保留 macOS 原生截图、OCR、快捷键、问答窗口和多模型配置的前提下，将问答模型调用交给 LangChain。框架采用 Python `langchain >=1.4,<2`，锁定真实解析和测试过的版本；模型集成依赖分别锁定。

## 实施边界

1. 保留现有 141 项测试作为迁移基线，新增本地进程通信及真实 LangChain 模型适配的回归测试。
2. 用常驻本机子进程提供 NDJSON 流式请求、取消和错误结果；数据经匿名管道传递，不引入新的云端网关、监听端口或跟踪服务。
3. 使用 LangChain 直接模型流式调用，保留已有历史、图片开关和三种接口路由。当前单次截图问答无需新增 Agent 工具循环。
4. App 内置 Python 运行时与锁定依赖，用户无需安装 Python。启动时预热导入，后续问题复用进程，避免每次启动解释器。
5. API Key 仍从钥匙串读取，只随本次请求经管道进入子进程内存；不写命令行、环境变量、配置文件或日志。
6. 模型服务地址、模型切换、取消、过期流响应隔离和错误文案保持兼容。生产 App 缺少内置引擎时明确报错，不静默绕回其他实现。

## 验证

- 真实 LangChain provider + 本机模拟服务：Chat Completions、Responses、Anthropic Messages 的地址、认证、历史、图片、流式输出、完成标记、限流/认证失败/截断与取消。
- Swift 进程通信：预热、首字流、并发隔离、取消、子进程崩溃、后续请求重启、协议和版本不匹配。
- 全部 Swift 测试、Python 测试、锁定依赖、发布构建和签名检查。
- 冻结引擎在无开发虚拟环境依赖下启动并完成模拟问答；记录冷启动与复用进程延迟、应用体积。
- 正式安装前后校验用户生词本和偏好，保留可回退的旧版。

来源：[LangChain 发布版本](https://pypi.org/project/langchain/)、[模型调用](https://docs.langchain.com/oss/python/langchain/models)、[OpenAI 集成](https://docs.langchain.com/oss/python/integrations/chat/openai)、[Anthropic 集成](https://docs.langchain.com/oss/python/integrations/chat/anthropic)。

## 实施结果

后续真实服务性能复测发现并修复系统代理路由缺失，当前已安装 **0.2.68**；详见 [真实模型性能复测](LANGCHAIN_CLOUD_PERFORMANCE.md)。以下 0.2.67 为首次迁移时的验证记录。

已安装本机版本 **0.2.67**。生产默认调用 App 内置的 LangChain 进程；明确注入 `URLSession` 的测试仍可使用原生适配器，不作为生产静默回退。

锁定依赖：`langchain 1.4.3`、`langchain-core 1.6.6`、`langchain-openai 1.6.7`、`langchain-anthropic 1.7.5`、`openai 3.24.0`、`anthropic 1.11.0`、`httpx2 2.13.1`。构建使用 uv 管理的 Python 3.13 和 PyInstaller 6.22.3。升级锁文件时，应重新验证 Anthropic 适配的客户端工厂与事件转换钩子。

直接使用模型的 `astream`，不引入工具循环。进程启动时预热，最多复用四个模型配置的 SDK 客户端和连接；配置或 Key 不同不会共享客户端。GPT Responses 保留现有 `store=false` 和输出预算，未额外开启思考；Claude 思考内容不会显示为答案，本次未修改用户已保存的推理设置。

三种接口的完整路径、认证、六轮历史与图片输入已保留。服务忽略流式设置而返回完整 JSON 时，兼容同一次已收到的响应，不重发模型请求。支持 gzip；回答为空、截断或 Claude 缺少 `message_stop` 时明确失败，不发布为完整答案。

## 实际验证记录

- Swift **161 项测试通过**，发布构建使用 `-warnings-as-errors`；新 Swift 文件严格格式检查通过。
- Python **22 项测试通过**：真实 LangChain SDK 连接本机模拟服务，覆盖三种接口、图片与历史、HTTP 401 零重试、完整 JSON、gzip、空回答、截断、拒绝文本、缓存并发、取消、EOF 关闭及禁用跟踪。
- 将进程测试的执行入口替换为 App 中实际冻结的引擎后，测试集再次通过；四项进程测试使用打包后的执行文件，其他 SDK 测试使用锁定的开发环境。
- 独立编译的 Swift 夹具使用生产默认 `ScreenshotQuestionClient`，经常驻冻结引擎完成三个接口的问答。实际请求路径与预期一致，每次回答为 `Hello world`，进程正常退出且 stderr 为空。
- 签名布局将 Python 元数据与普通数据放在 `Contents/Resources`，原加载位置保留 App 内相对链接。16 个内部 Mach-O 分别签名，再签外层 App；`codesign --verify --deep --strict` 通过。[Apple 签名布局说明](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- 正式安装位置为 `~/Applications/拾词助手.app`。安装前后生词本和偏好文件 SHA-256 一致，指定签名要求与旧版一致；启动后核实仅一个正式 App 进程及其一个内置引擎子进程。旧版保留在本机废纸篓，可回退。

## 延迟与范围

即时本机模拟服务的 12 次请求中，连接复用后的首段延迟中位数 **1.78 ms**。各协议第一次创建客户端的首段耗时为 21–56 ms。打包后新进程 ready 为 **0.604 秒**，这次测量已有系统文件缓存；最初未预热的冻结引擎启动曾为 **4.599 秒**，所以启动时预热仍有必要。原始数据见 [本机测量记录](LANGCHAIN_MIGRATION_PERFORMANCE.json)。

上述数据不包含真实云端模型推理、服务排队和外网传输，不能据此宣称 GPT、Claude 或 DeepSeek 更快；已有云端对比仍见 [模型性能验证](QUESTION_MODEL_PERFORMANCE.md)。当前 App 约 **49 MB**。本次仅在当前 Apple Silicon Mac 验证，未验证 Intel 或其他 macOS 版本；截图及实体热键的既有系统测试边界仍见 [独立热键记录](DIRECT_SCREENSHOT_QUESTION_SHORTCUT.md)。

## 变更文件

- `question-engine/`：锁定依赖、持久引擎、SDK 回归和开发说明。
- `LangChainQuestionTransport.swift`、`ScreenshotQuestionBackend.swift`：匿名管道和生产入口；共享提示词集中于 `ScreenshotQuestionInstructions.swift`，原生适配器只为明确注入的测试保留。
- `VocabCaptureApp.swift`：引擎预热与退出关闭；新增两个 Swift 测试文件覆盖通信与请求生成。
- `scripts/build-question-engine.sh`、`scripts/sign-app.py`、`scripts/package-app.sh`：冻结、数据布局、内部签名与打包。
- `VERSION`、README 和本记录：版本、开发流程与验证范围。
