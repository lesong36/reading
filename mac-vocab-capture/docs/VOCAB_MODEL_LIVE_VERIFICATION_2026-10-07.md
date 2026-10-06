# 已配置模型实际验收（2026-10-07）

## 本轮结论

已覆盖 **5/5 个已配置服务（100% 服务覆盖）**，核心矩阵共 30 次真实网络请求：云模型 24 次、本机明确 llama.cpp 后端 6 次。**29/30 次完整成功，成功结果人工语义复核全部通过**；DeepSeek 关闭思考的首个 bank 请求返回 `invalidResponse`，被生产客户端拒绝，未保存或缓存。不能将本报告写成“30/30 全部通过”或“所有服务无失败”。

原先未完成的云服务凭据访问已由用户明确授权，测试仅在 Swift 内存及生产匿名管道内传递凭据。没有将 Key 写入源码、日志、命令参数、报告或词库，也没有修改现有配置。首轮被停止的非交互凭据读取属于此前验收，不再代表当前云服务未测。

## 生产实现修正

确认当前本机 `127.0.0.1` 是 llama.cpp：`/props` 返回 build `b10488-9d77fa172`，模板包含 `enable_thinking`；`/v1/models` 的 owned_by 为 `llamacpp`，当前 Qwen3.6 35B GGUF。官方 [llama.cpp server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) 明确支持 `chat_template_kwargs.enable_thinking`。

修正为显式 `DictionaryBackend`：旧设置保持 `openAICompatible`，用户明确选择 `llamaCpp` 后，关闭档发送 `enable_thinking: false`，低/中/高发送 `true`，自动省略控制；开启档扩大对应 token 预算。未根据 localhost、GGUF 名称或兼容网关猜测能力。`backend` 保留于规范化、持久配置和缓存/合并请求身份。

当前用户保存的旧配置没有被自动改写。本机下表只在临时内存配置明确选择 llamaCpp，因此安装新代码后仍需在取词设置选择这个后端才能使用该控制。

新增 4 项回归先在旧代码失败（5 个断言失败），修复后全部 DictionaryClientTests **29 项通过**，warnings-as-errors。覆盖关闭/开启/自动请求参数、旧 JSON/未知后端、未知本机不猜能力及后端缓存隔离。日志 `/tmp/vocab-model-live/backend-red.log`、`backend-green.log`。

## 方法与统计边界

公开合成原句：bank — `We sat on the bank of the river.`（河岸）；charge — `The museum does not charge an admission fee.`（收费）；bear — `The evidence does not bear out his claim.`（bear out 证实/支持）。不读取用户词库、截图、历史对话或私有语境。

- DeepSeek/Kimi/本机直接使用生产 `DictionaryClient`、`DictionaryRequestPolicy`，缓存关闭，保持生产 15 秒首内容/30 秒总预算。首释义是完整 meaning 字段被生产逻辑发布的时刻。
- AICodeWith GPT/Claude 使用实际保存的 Responses/Messages 协议、生产 `ScreenshotQuestionClient → LangChainQuestionTransport → question_engine.py`，运行已有 .venv，不新增依赖。它们属于相邻问答链路，不能充当原生取词支持 Responses/Messages 的证明。
- 云模型每档 3 个不同公开夹具、按 off 后 on 顺序。GPT off 是该模型允许的最低 low，并不能彻底关闭；中档为 medium。Claude off 对此型号使用 between_tools/低 effort，开启为 adaptive/low。DeepSeek、Kimi off 为 disabled，low 为 enabled。
- 样本少、顺序固定且服务端/连接预热可能影响结果，不计算稳定 P95，不宣称普遍提速比例或准确率保证。
- GPT 服务报告 reasoningTokens=0；Claude reasoning token 未提供。不由参数或零/缺失统计断言网关确实改变了推理量。
- 问答 TPS 仅在 provider 有 outputTokens 时按 outputTokens/总耗时计算，是含网络和等待的平均值，不能当作解码速度。原生词典未提供 usage，不编造 TPS。

## 云服务汇总（秒，中位数）

| 模型 | 档位 | 完整成功 | 首可见 | 首完整释义 | 完成 | 路径 |
|---|---|---:|---:|---:|---:|---|
| gpt-6.1-sol | off | 3/3 | 2.526 | —（问答无独立meaning事件） | 3.243 | 生产LangChain问答 |
| gpt-6.1-sol | medium | 3/3 | 2.767 | —（问答无独立meaning事件） | 3.175 | 生产LangChain问答 |
| claude-sonnet-5-5 | off | 3/3 | 1.372 | —（问答无独立meaning事件） | 1.373 | 生产LangChain问答 |
| claude-sonnet-5-5 | low | 3/3 | 1.524 | —（问答无独立meaning事件） | 1.578 | 生产LangChain问答 |
| deepseek-flash | off | 2/3 | 1.177 | 1.270 | 1.570 | 原生词典 |
| deepseek-flash | low | 3/3 | 2.071 | 2.071 | 2.073 | 原生词典 |
| kimi-k2.6 | off | 3/3 | 1.064 | 1.155 | 1.504 | 原生词典 |
| kimi-k2.6 | low | 3/3 | 15.084 | 15.085 | 15.432 | 原生词典 |

Kimi 本轮首释义中位数关闭约 1.155 秒、开启约 15.085 秒，关闭对这些短词典请求明显更快，返回语义均正确。DeepSeek 关闭档只有 2 个成功样本，首个结构失败保留在失败率中，不从统计抹去。

## 云服务逐请求

| 模型 | 档位 | 夹具 | 结构/语义 | 首可见(s) | 完成(s) | 公开释义或失败类型 |
|---|---|---|---|---:|---:|---|
| gpt-6.1-sol | off | bank | 通过 | 2.526 | 2.557 | 河岸 |
| gpt-6.1-sol | off | charge | 通过 | 2.392 | 4.389 | 收取（费用） |
| gpt-6.1-sol | off | bear | 通过 | 2.970 | 3.243 | 支持、证实 |
| gpt-6.1-sol | medium | bank | 通过 | 2.396 | 2.617 | 河岸，指河流边的陆地。 |
| gpt-6.1-sol | medium | charge | 通过 | 2.767 | 3.175 | 收取（费用） |
| gpt-6.1-sol | medium | bear | 通过 | 3.893 | 3.976 | 支持、证实 |
| claude-sonnet-5-5 | off | bank | 通过 | 2.084 | 2.086 | bank 在此指"河岸、岸边"，即河流两侧的陆地。 |
| claude-sonnet-5-5 | off | charge | 通过 | 1.218 | 1.219 | 收费，即要求支付（费用）。 |
| claude-sonnet-5-5 | off | bear | 通过 | 1.372 | 1.373 | bear out 意为“证实、支持”，此处 does not bear out 表示证据不能证实他的说法。 |
| claude-sonnet-5-5 | low | bank | 通过 | 1.692 | 1.693 | bank 在此指“河岸、岸边”，即河流两侧的陆地。 |
| claude-sonnet-5-5 | low | charge | 通过 | 1.192 | 1.196 | 收费；要求支付（费用）。 |
| claude-sonnet-5-5 | low | bear | 通过 | 1.524 | 1.578 | bear out 意为“证实、证明（某说法）属实”，此处 does not bear out 即“并不能证实”。 |
| deepseek-flash | off | bank | 失败 | — | — | invalidResponse |
| deepseek-flash | off | charge | 通过 | 1.337 | 1.734 | 收取（费用） |
| deepseek-flash | off | bear | 通过 | 1.016 | 1.406 | 证实，支持（说法） |
| deepseek-flash | low | bank | 通过 | 1.537 | 1.648 | 河岸 |
| deepseek-flash | low | charge | 通过 | 2.071 | 2.073 | 收取（费用） |
| deepseek-flash | low | bear | 通过 | 3.431 | 3.700 | 证实；印证（某说法） |
| kimi-k2.6 | off | bank | 通过 | 2.061 | 2.515 | 河岸，河堤 |
| kimi-k2.6 | off | charge | 通过 | 0.924 | 1.373 | 收取（费用） |
| kimi-k2.6 | off | bear | 通过 | 1.064 | 1.504 | 证实，支持（主张、理论等） |
| kimi-k2.6 | low | bank | 通过 | 15.129 | 15.470 | （河）岸；堤 |
| kimi-k2.6 | low | charge | 通过 | 15.084 | 15.432 | 收费；要价 |
| kimi-k2.6 | low | bear | 通过 | 10.136 | 10.782 | （与 out 搭配）证实；支持 |

Kimi low/bank 的“（河）岸；堤”与原句一致，最初关键词匹配标 REVIEW，人工复核通过。DeepSeek 首次失败未保留原始返回，不能凭错误类型推断具体缺字段或服务原因；后续诊断独立记录，不以重测成功覆盖首次失败。

## 本机显式 llama.cpp 后端（秒）

| 档位 | 夹具 | 首字 | 首完整释义 | 完成 | 公开释义 |
|---|---|---:|---:|---:|---|
| off | bank | 0.999 | 1.580 | 7.415 | 河岸 |
| off | charge | 1.048 | 1.647 | 7.769 | 收费 |
| off | bear | 0.874 | 1.839 | 6.577 | 证实；支持 |
| automatic | bank | 1.015 | 1.653 | 4.152 | 河岸 |
| automatic | charge | 0.540 | 0.780 | 2.802 | 收费 |
| automatic | bear | 0.576 | 1.079 | 2.741 | 证实，证明（为真） |

关闭档首释义中位数 1.647 秒、完成 7.415 秒；自动档首释义中位数 1.079 秒、完成 2.802 秒。自动档省略 enable_thinking，默认行为由本机服务/模板决定；这不是明确开启思考的对照。结果不能证明关闭比自动快，完成耗时仍有提升空间。与此前兼容模式的 6 个样本亦无同条件预热对照，未给出版本加速比例。

## 可复核证据与剩余条件

- 云主矩阵：`/tmp/vocab-model-live/cloud-results.log`，24 请求/23 完整成功，进程正常退出。
- 本机新后端：`/tmp/vocab-model-live/llama-results.log`，6/6 成功，进程正常退出。
- 先前未发送后端控制的本机基线：`/tmp/vocab-model-live/local-results.log`，6/6 成功，仅作为历史样本。
- 临时源码 `/tmp/vocab-model-live/CloudHarness.swift`、`Harness.swift`；不含凭据值。实际 Keys 只经 Keychain 内存读取和生产请求/匿名管道传递。
- DeepSeek 附加公开 bank 诊断另见 `/tmp/vocab-model-live/deepseek-diagnostic.log`：修正临时诊断 parser 后 HTTP200、text/event-stream、42 个数据帧，DONE 终止，完整 JSON 的五字段都是字符串，meaning 为“河岸”；严格 DictionaryResult 解码通过。未复现第一次失败，不能认定其具体原因已定位/修复。临时诊断首版 parser 未分派内容，属于测试夹具问题，未计入生产失败率。
- 没有改写用户设置、词库、Keychain 或第三方账号，没有新依赖、部署或发行上传。

模型服务覆盖已达 100%，性能/语义小样本矩阵已完成；仍不能承诺云服务零失败或稳定 P95。若要求 M12 的“速度改善且质量不退化”严格闭环，需补充同条件旧版本基线、足量重复样本，并解释/处理 DeepSeek 首个结构失败；不能以本轮已有请求覆盖率替代这些条件。

## 本机明确开启思考的补验

显式 `backend=llamaCpp`、`thinking=low`，使用相同三个公开语境：bank/charge/bear。生产取词客户端三次均触发首有效内容截止，分别 15.742 / 16.000 / 15.998 秒；没有完整释义，不计语义通过。对照的明确关闭思考三项已有完整结果。

该差异证明开启思考在当前本机服务上会耗尽产品等待预算，不能把 automatic 当作明确开启，也不能通过延长超时把失败率抹掉。当前建议继续关闭思考。只记录公开夹具和脱敏耗时；没有修改用户保存的模型或凭据。
