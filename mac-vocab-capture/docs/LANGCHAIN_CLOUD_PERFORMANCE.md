# LangChain 接入后的真实模型性能复测

2026-10-06，当前 Apple Silicon Mac、网络与已保存的 GPT-6.1 Sol / Claude Sonnet 5.5 / DeepSeek Flash。修复版本 **0.2.68**，LangChain **1.4.3**。问题和原文为人工构造的公开文字，不上传截图；Key 仅在 Swift 内存及匿名管道中使用，没有导出到文件或日志。

## 发现与修复

0.2.67 初轮启动 12 次请求：8 次完整、3 次失败、1 次诊断后取消。GPT、Claude 的 LangChain 请求约 75 秒后失败，原生对应请求成功。URLSession 遵守 macOS 系统代理，HTTPX 原先 `trust_env=false` 直连。当前仅有 `no_proxy` 环境变量，通用 `urllib.getproxies()` 还会遮蔽系统配置回退。

0.2.68 显式读取 macOS 手动 HTTP/HTTPS 代理与绕过规则，回环地址直连；代理路由进入缓存键，路由改变时不复用旧客户端。仍禁用环境代理，不关闭 TLS 校验。冻结构建包含 `_scproxy`，在当前托管 Python 中为内置模块。[Python 文档](https://docs.python.org/3.13/library/urllib.request.html)、[HTTPX 文档](https://www.python-httpx.org/advanced/proxies/)支持这项配置方式。PAC 与仅 SOCKS 配置未在本次增加支持。

原实现还把没有 HTTP 状态的 SDK 异常显示为 500。因此初轮“HTTP 500”不能证明服务真的返回了 500。现在区分连接、超时、响应异常及真实 HTTP 错误，不显示原始异常、地址或凭据。修复后 LangChain 九题全部完整返回，未再出现约 75 秒失败，支持代理路由缺失是重要原因；模型参数没有改变。

## 方法

沿用三题：LangChain 是框架而非模型、`his sister and he → him`、给错误历史后判断 `my sister and I → me`。每模型每题分别调用 LangChain 和原生适配器一次，轮换模型顺序、交替后端先后，共 18 次。LangChain 使用生产 Swift 通信层与已安装 App 的冻结引擎；原生明确注入共享 URLSession。两条路径均复用客户端。

系统指令、端点、温度与输出预算一致，未修改推理设置。但来源文字包装和 Responses 指令字段位置不同，因此这是实际调用路径对照，不能把差值视为纯框架开销。

首段为请求开始到首个非空 MainActor 累计文字回调，完成为确认完整结束后的耗时，使用单调时钟。引擎预热 **1.64 秒**，单列；模型首题仍包含 SDK/TLS 建立。不包括截图、OCR、窗口重排或 Key 读取。

## 结果

成功样本中位数：

| 模型 | 后端 | 完整回答 | 首段 | 完成 | 首段范围 | 字符中位数 |
|---|---|---:|---:|---:|---:|---:|
| GPT-6.1 Sol | LangChain | 3/3 | 4.87 s | 7.80 s | 4.72–8.35 s | 252 |
| GPT-6.1 Sol | 原生 | 3/3 | 5.42 s | 7.89 s | 3.60–5.93 s | 234 |
| Claude Sonnet 5.5 | LangChain | 3/3 | 5.79 s | 6.46 s | 5.07–6.45 s | 546 |
| Claude Sonnet 5.5 | 原生 | 3/3 | 4.86 s | 5.11 s | 1.19–5.06 s | 496 |
| DeepSeek Flash | LangChain | 3/3 | 4.04 s | 4.37 s | 3.26–5.65 s | 372 |
| DeepSeek Flash | 原生 | 2/3 | 2.19 s | 3.32 s | 1.76–2.62 s | 468.5 |

共 **17 次完整、1 次失败**。失败为 DeepSeek 原生历史题：首段 5.13 秒、5.29 秒判定截断，未计入成功中位数。DeepSeek 两组成功题数不同，不能据此推断精确后端开销。

当前生产 LangChain 路径 **9/9 成功**。GPT 两路径接近；Claude、DeepSeek 的 LangChain 首段中位数较大。三题各一次、输出长度不同，缓存、服务负载与顺序会影响结果，不能宣称换框架稳定全面提速。所有逐题答案与初轮失败见 [JSON](LANGCHAIN_CLOUD_PERFORMANCE.json)。

## 回答检查

17 个完整答案核心检查通过：框架 6/6、him 6/6、me 5/5；LangChain 九题均通过。历史题只有 3/5 明确认错（Claude 两组、DeepSeek LangChain）；GPT 两组答对 me，却未明确承认前答有误。要求显式历史纠错时，严格通过数为 15/17。

仍有措辞问题：GPT 原生 him 末尾混入 `%timeout`；Claude 框架题展开无关语法例句，回答偏长；部分答案将主格范围说得过于绝对。这些有限检查不代表普遍准确率。

## 验证与变更

- 问答引擎、测试和 README：系统代理、路由缓存与安全错误分类。锁文件新增直接使用的 OpenAI SDK 声明，锁定版本不变，未新增代理依赖。
- `LangChainQuestionTransport.swift` 与测试：独立网络提示，缺失/布尔/小数/越界状态不会冒充 500。
- `build-question-engine.sh`、`VERSION`、README 与本记录：冻结模块、版本和性能数据。
- **162 项 Swift 测试、29 项 Python 测试通过**；进程测试换为真实 App 冻结入口后再次通过。严格格式、发布构建、深度严格签名通过。
- 已安装并启动 `~/Applications/拾词助手.app` **0.2.68**，正式 App 与其引擎各一个进程；签名要求与旧版一致，旧版在废纸篓。安装完成时偏好和生词本哈希与安装前一致，生词本结束时仍一致。启动后完整偏好字节哈希有变化，未据此宣称所有偏好在全过程不变；三个模型与初轮一致，测试程序没有保存或切换配置。当前快捷键：选词 ⇧⌘D、截图取词 ⌥D、截图问一问 ⌥A。

下一项优化可对照可选推理档与更简短的回答，特别是 Claude 的无关扩展；需要同时验证复杂题和历史纠错，不宜只降低输出预算制造截断。本轮保持现有推理设置和输出预算。
