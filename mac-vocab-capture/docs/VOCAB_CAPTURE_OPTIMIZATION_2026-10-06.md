# 拾词功能五阶段优化实施与验收

对应审计：[28项问题审计](./VOCAB_CAPTURE_AUDIT_2026-10-06.md)。逐项机器可读状态见 [覆盖率JSON](./VOCAB_CAPTURE_OPTIMIZATION_COVERAGE_2026-10-06.json)。

## 当前结论与口径

原28项中27项已验证；M08的左右键组合取词实际复验仍失败，用户明确要求放弃，已移除功能、菜单和配置读取。M08浮钮A→B等既有保护保留。原28/28“100%”结论已撤回，移除不记作组合键验收通过。最终移除回归与版本见[实时报告](./VOCAB_CAPTURE_LIVE_VERIFICATION_2026-10-07.md)。

已授权部署生产Supabase v2、发布协调升级后的网页、备份并安装0.2.75 App及发布签名安装包。系统交互使用隔离词库和模拟释义；真实云端采用两个专用合成账号，已完成定向清理；模型实测使用公开语境。未查看或导出用户词库、未将API Key写入源码、报告或构建物。现有其他阅读功能保留，没有新增依赖。

## 五阶段结果

| 阶段 | 已实现 | 严格闭环 | 主要结果 |
|---|---:|---:|---|
| A 止损与可靠性 | 5/5 | 5/5 | 损坏/未知版本词库阻止写入、备份恢复；桥接资源上限；Keychain更新失败保留旧值；拒绝截断回答；有界流式等待 |
| B 账号与同步 | 9/9 | 9/9 | 账号独立词库与收集箱、持久操作队列、事务RPC/版本墓碑/幂等确认、401受控刷新、网页词库隔离 |
| C 语境与交互 | 8项及M08保留部分 | 8/9；1项按用户调整范围 | 配对和一次性凭证、活动tab/window握手、可见DOM、AX后台预算、选区revision、截图错误分类、回车防重、原文诊断到期删除 |
| D 速度与配置 | 4/4 | 4/4 | 支持服务的默认关闭/最少思考；同请求合并与独立取消；先显示完整meaning；分类错误、有界重试和配置检查 |
| E 清理 | 1/1 | 1/1 | 删除无入口Recent界面和字段；预览、截图进程和同步调度独立；保持既有菜单/快捷键入口 |

## 关键行为与修改文件

### 本机词库及账号

`Sources/VocabCapture/VocabularyStore.swift` 与新 `VocabularyPersistence.swift` 使用版本化JSON envelope，条目和pending原子保存。保存成功即有持久operationID；只有对应账号、generation和服务器确认才能移除。未登录收集箱及旧来源不明词库不会自动上传，登录后需用户在App明确绑定；碰撞原件另存备份。

正常写入保存最近三份备份。损坏文件、读取失败、未知版本只允许保全原件/显式恢复，不能变成空词库继续覆盖。冲突恢复有“采用云端”与“采用本机并重新提交”，仅处理指定词，先保存永久原始快照。

额外防线：App保存调用携带`VocabularyWriteScope`，在Store actor内部检查账号/generation再执行写盘。保存前的UI检查无法替代这个原子检查；A→B→A旧请求仍无写入权。

`KeychainStore.swift` 先更新既有项目，只有not-found才新增；失败不会先删除旧凭据。主动清空/退出才删除。

### 跨端同步

`VocabularySyncCoordinator.swift` 将普通取词、OCR、手动、启动与网络恢复接入同一队列；debounce默认0.5秒，连续收藏等待上限2秒。每批最多500项，单轮最多8批，其余继续排队。离线、429和5xx有界退避；认证、权限和参数错误等待处理。

`SupabaseClient.swift`/`VocabularyEntry.swift` 处理严格确认、账号/session revision、401单次刷新、元数据与未知字段。`index.html`及仓库中文入口改为独立词库RPC，其他进度写入不包含受保护词库列。账号切换期间不显示旧账号词库；未归属词库不写入账号outbox，账号词库也不覆盖未归属localStorage/OPFS。

`supabase/vocabulary-sync-v2.sql`/`schema.sql` 使用auth.uid、行锁、全局revision、词条baseVersion、版本墓碑和操作receipt。旧全数组PATCH/upsert由列权限阻断。保护实现放在非暴露reader_private，固定search_path，公共RPC为SECURITY INVOKER包装。

升级顺序、兼容风险和SQL测试详见 [同步v2说明](./VOCABULARY_SYNC_V2.md)。升级前新客户端明确提示协议未升级，保留本机pending，不回退到旧覆盖协议。

### 采集和交互

`BrowserContextBridge.swift` 限制16KiB头、256KiB正文、8连接、10秒绝对连接期限；无效长度、半包和慢连接均有验证。扩展使用配对令牌/来源校验，custom URL只能消费15秒的一次性凭证。撤销后旧凭证失效。

`browser-extension/` 改为短期内存上下文、活动tab/window和revision握手、导航/失焦清理、只记录成功发送，排除隐藏DOM。删除无用scripting权限。扩展版本0.2.0，升级需包含新增`text-contract.js`，刷新页面并重新配对。

`SelectionReader.swift` 的AX调用移到后台串行队列：扫描预算450ms，单次IPC timeout80ms，节点数有限，取消和前台PID改变后拒绝提交。450ms是检查预算，最后一次IPC可能额外占用至80ms，不能把它写成真实测得的硬上限；真实应用P50/P95尚未测试。

新`SelectionCaptureState.swift` 与App集成，开始新拖选即清除旧浮钮；消费选词后旧读取不能再次显示。鼠标组合键重新异步读当前选区，避免消费旧快照。`SelectionTextContract.swift`和扩展共用公开夹具，支持Dr.、3.5、内联节点、en dash和最多12词；Services限制一致。

`ScreenshotRegionCapture.swift` 分开权限拒绝、启动/进程失败、无有效图像和取消；临时图片始终清理。`OCRLookupPanel.swift`/`OCRSelection.swift` 统一保存条件，成功后同revision不能再次保存，失败可重试，重新选词清除旧结果。

`ContextDebugLog.swift` 默认仅记录元数据。原文诊断明确开启，最长10分钟，到期或关闭会删除持久日志；在写入队列执行时判定诊断模式，已排队原文不能在清理后重新落盘。测试使用`VOCAB_CAPTURE_DIAGNOSTICS_DIR`临时目录。

### 取词速度和清理

`AIClient.swift`/新`DictionaryRequestPolicy.swift` 保持取词的单次模型调用，不增加Agent循环。同词、语境、配置和思考档位的请求只发一次HTTP；订阅者独立取消，全部取消才停网络；完成回调期间取消也不能向取消者返回成功。只缓存严格成功完成的结果。

完整meaning字段先展示，完整词典结果到达前不能保存。首有效内容期限默认15秒、总期限30秒，heartbeat不能续命；限制SSE行/事件及总响应大小。区分401/403、429、5xx、配置、网络、超时和截断；最多1次可恢复重试，Retry-After支持秒数与HTTP日期，不能超出共同总预算。

取词设置单独保存思考强度，支持的提供商默认关闭或使用模型允许的最低值。未知网关/模型保留默认，不能保证“关闭”一定让远端停止思考；未确认的高档位拒绝发送。规则参考 [DeepSeek思考模式](https://api-docs.deepseek.com/guides/thinking_mode)、[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)。已有服务的实际速度/释义质量尚未重测，不给出加速百分比。

`VocabCaptureApp.swift` 删除无入口的RecentVocabularyViewController/ListView/旧panel和lastSynced字段；新`DefinitionPreviewPanel.swift`保留确认/取消行为并显示首字、首释义、完成耗时。`main.swift` 适配MainActor入口。没有重写整个App。

## 验证证据

- Swift完整suite：299项，0失败、0跳过，warnings-as-errors通过。日志`/tmp/vocab-opt-final-swift.log`。
- 扩展Node：13项，0失败。日志`/tmp/vocab-opt-final-extension.log`。
- Python：56项，0失败。日志`/tmp/vocab-opt-final-python.log`。
- 网页Node：15项，0失败，包括生产helper、outbox、账号投影、未知字段、整页JSX、跨午夜/DST/旧日期。日志`/tmp/vocab-opt-final-web.log`。
- PostgreSQL 17临时UTF-8集群：旧schema先复现覆盖风险，升级后验证权限、RLS、幂等、冲突、恢复及非词库写入；在pg_stat_activity观察第一个事务仍持锁，再启动第二连接，保证实际重叠；冲突重试后保留两词。集群已停止删除。日志`/tmp/vocab-opt-db-verified.log`。
- Release编译warnings-as-errors通过：`/tmp/vocab-opt-release-complete.log`。完整package-app.sh、16个嵌套Mach-O/deep strict签名、解压后签名、冻结LangChain1.4.3引擎启动均通过；GitHub重下载包hash一致。
- JS语法、Info.plist、diff检查通过；仓库中文HTML入口与index.html一致。未运行会覆盖已安装App和私有配置的整套sync脚本。
- 子代理完成存储、采集和同步分支，主代理整合及边界复查。后续独立云端权限、原生组合及浏览器发布者审查完成，发现跨浏览器会话和浮钮事件竞态，并以红→绿回归修复。LSP工具不可用，以Swift严格编译替代，没有宣称LSP通过。

复现命令（从仓库根目录）：

```sh
VOCAB_CAPTURE_DIAGNOSTICS_DIR=/tmp/vocab-tests-diagnostics swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-tests -Xswiftc -warnings-as-errors
node --test mac-vocab-capture/browser-extension/tests/*.test.cjs
node supabase/tests/vocabulary-sync-v2.test.mjs
python3 supabase/tests/run-vocabulary-sync-v2.py
swift build --package-path mac-vocab-capture --scratch-path /tmp/vocab-release -c release -Xswiftc -warnings-as-errors
```

SQL runner只用已有PostgreSQL，不安装依赖或访问现有库。无需真实API配置，最终验收使用公开/合成夹具。收尾检查发现部分既有AppDelegate测试使用默认词库路径，现已统一注入临时目录、独立preferences及模拟凭据，避免以后回归读取用户本机状态。

## 系统界面验收的实际边界

初期使用生产源码独立App注入URLProtocol/模拟凭据/权限 runner验证UI；后续同一隔离生产生命周期App完成真实TCC拒绝→用户授权→选区成功→物理Esc取消，真实Chrome/Edge配对与跨窗口/浏览器、AppKit/Chrome前台AX、外部TextEdit物理浮钮/鼠标组合验收。权限由用户在系统完成，未用注入结果代替真实授权。

已观察：原文选curious获得语境释义；连续3次Return后按钮禁用，临时库只有1词1pending；菜单模型入口集中；取词思考默认选项可见；连接测试失败后原配置保留；释义meaning先可见且保存禁用，完整结果到达后按钮启用、性能信息可见；Esc关闭；注入权限拒绝出现明确截图失败而非静默取消。预览窗口显示的0.10/0.20/3秒是模拟数值，不能作为云模型性能测量。

临时测试App已退出、偏好与浏览器临时配对已清理。真实Chrome/Edge、AX/TCC/浮钮/鼠标组合及配置服务对照见上述真实报告。云模型实测保留失败与超时，不由模拟UI耗时推断提速。

## 逐项状态

全部28项按原审计验收条件闭环；模型比较的失败记录及范围外限制仍保留。

| ID | 阶段 | 状态 | 证据或待完成条件 |
|---|---|---|---|
| H01 | A | 闭环 | VocabularyPersistenceTests:坏文件/未知版本阻止覆盖、备份导出恢复、原始字节保全。 |
| H03 | A | 闭环 | BrowserBridgeSecurityTests:负数/溢出/重复长度/头正文上限、8连接及慢包绝对期限。 |
| M18 | A | 闭环 | KeychainWriteTests:先更新、仅not-found才新增、失败保持旧项。 |
| M15 | A | 闭环 | DictionaryClientTests:非流length、SSE异常/EOF拒绝与失败不缓存。 |
| M16 | A | 闭环 | DictionaryClientTests:heartbeat首有效内容超时、partial后总期限、line/body上限和网络取消。 |
| H02 | B | 闭环 | Native/Web/隔离PostgreSQL协议回归通过；参见优化实施报告。 2026-10-07：Native/Web升级，真实生产JWT/REST并发、冲突、删除恢复、精确确认与旧写入阻断通过；独立云端复核。 |
| H04 | B | 闭环 | 生产 Swift Store/Coordinator 与真实账号JWT HTTPS组合验收通过；H04旧A快照延迟交付不能写B；M20独立生产者/消费者进程退出重启，operationID不变、pending归零、revision只增一次且真实RPC幂等重放。明确断网/延迟为边界控制，不冒称真实网络断电。见VOCAB_NATIVE_CLOUD_LIVE_2026-10-07.md。 |
| M01 | B | 闭环 | Native/Web/隔离PostgreSQL协议回归通过；参见优化实施报告。 2026-10-07：Native/Web升级，真实生产JWT/REST并发、冲突、删除恢复、精确确认与旧写入阻断通过；独立云端复核。 |
| M02 | B | 闭环 | Native/Web/隔离PostgreSQL协议回归通过；参见优化实施报告。 2026-10-07：Native/Web升级，真实生产JWT/REST并发、冲突、删除恢复、精确确认与旧写入阻断通过；独立云端复核。 |
| M03 | B | 闭环 | Native/Web/隔离PostgreSQL协议回归通过；参见优化实施报告。 2026-10-07：Native/Web升级，真实生产JWT/REST并发、冲突、删除恢复、精确确认与旧写入阻断通过；独立云端复核。 |
| M19 | B | 闭环 | SupabaseAuthTests:未到期JWT的REST401只刷新1次、并发刷新、二次401终端失效及瞬时错误保留。 |
| M20 | B | 闭环 | 生产 Swift Store/Coordinator 与真实账号JWT HTTPS组合验收通过；H04旧A快照延迟交付不能写B；M20独立生产者/消费者进程退出重启，operationID不变、pending归零、revision只增一次且真实RPC幂等重放。明确断网/延迟为边界控制，不冒称真实网络断电。见VOCAB_NATIVE_CLOUD_LIVE_2026-10-07.md。 |
| L01 | B | 闭环 | VocabularyPersistence/ProtocolTests与SQL canonical key:空格大小写、归一化碰撞原始备份。 |
| L02 | B | 闭环 | 网页Node:同日本地分组、上海/纽约跨午夜、DST与旧date-only稳定。 |
| M04 | C | 闭环 | ContextDebugLogTests:临时真实文件中原文到期删除、恢复仅元数据；扩展删除持久原句，短期内存缓存。 |
| M05 | C | 闭环 | BrowserBridgeSecurityTests 的 token/Origin/Host/一次性凭证与词边界回归通过；真实 Edge 和 Chrome 0.2.0 均临时配对成功，公开 curious 选词分别向隔离生产桥接返回对应原句。2026-10-07 CUA 实际操作记录。 |
| M06 | C | 闭环 | Chrome/Edge 0.2.1 actual pairing; A/B tabs and independent Chrome windows; 23.808s reselect and cleared selection; Edge→Chrome→Edge 3547ms returned B/A/B; actual HTTP401 after token rotation; same document same word restored after re-pair without reload. |
| M07 | C | 闭环 | 扩展Node可见文本/隐藏DOM夹具；无script/style/hidden原句。 |
| M08 | C | 用户移除组合键 | 物理A→B浮钮确认通过；组合键实际失败，按用户要求移除，未计成功。304项Swift通过；保留浮钮3项回归，新增移除与失效保护5项。 |
| M09 | C | 闭环 | 生产 SelectionReader 在真正前台 AppKit/Chrome 公开选区各 30 次：词与原句均30/30；AppKit P50/P95=2.410/2.989ms，Chrome=3.115/3.691ms；主线程延迟 P95=0.745/0.801ms。排除所有0匹配样本；后台执行/扫描预算回归通过。 |
| M10 | C | 闭环 | Real app permission denial → user grant → actual 2146×916 region capture; fixed exit0/no file classification red→green; user physical Escape actual outcome=cancelled, process exited, UI no error. |
| M11 | C | 闭环 | Swift/JS共同断句夹具、Dr./3.5/inline/en dash与12词边界；Info.plist校验。 |
| M13 | C | 闭环 | OCRLookupPanelTests保存revision防重；CUA真实AppKit窗口连续三次Return只1词1pending。 |
| M12 | D | 闭环 | 5个实际已配置服务完成公开夹具开/关或最低思考对照；保留DeepSeek首次结构失败、llamaCpp开启3/3首内容超时及不确定gateway reasoning指标。测量满足验收，不代表所有档位成功或稳定提速。详见模型实测报告。 |
| M14 | D | 闭环 | DictionaryClientTests:同查询1HTTP、订阅者独立取消、全取消终止、失败重试和思考缓存隔离。 |
| M17 | D | 闭环 | DictionaryClientTests:401不重试、429/503最多1次、Retry-After秒数/HTTP日期与总预算、错误脱敏。 |
| L03 | D | 闭环 | URL/endpoint/model参数规范及本地HTTP兼容；Keychain失败保护旧值；CUA连接失败后配置仍保留。 |
| L04 | E | 闭环 | 删除无入口Recent类和字段；抽出预览、截图进程、同步协调器；全套warnings-as-errors通过。 |

## 剩余风险及上线条件

1. 生产已采用v2且拒绝旧整库写入。使用0.2.75及协调升级网页；未升级的外部旧写入方需要采用v2，不能为兼容撤掉词库保护。
2. 本机仍用JSON；未新增跨进程文件锁，多实例同时写同一账号文件尚无保证。单App进程actor内写入有序。
3. RPC按500项分批；异常巨大单条记录可能触发2MiB服务端上限，内容保持pending，需修正/导出保全，未做大型词库吞吐基准。
4. 没有有效备份的损坏词库只能保全原件，不能保证自动重建；恢复/绑定/采用本机冲突内容均要求用户在App明确操作。
5. 同一浏览器多个用户配置文件未覆盖；Tavily有效Key下搜索质量及真实延迟未完成检索对照，属原28项范围外。模型实测记录DeepSeek首次结构失败和本机明确开启思考3次首内容超时，推荐本机关闭思考；没有声称所有模式成功或稳定P95提速。
