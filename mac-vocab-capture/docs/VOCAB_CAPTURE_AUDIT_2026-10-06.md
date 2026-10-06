# 拾词助手详尽 Audit — 2026-10-06

## 结论与范围

基于当前 0.2.74 工作区实现（包括未提交的联网检索改动）进行只读审查。范围是选区/快捷键/鼠标触发、Chromium 扩展、AX 与 OCR 原文、词典释义、保存、登录和阅读器词库同步；仅对相邻“问一问”共用链路核查，不扩展为全问答或全网站审计。数学错题功能不在范围内。

发现 **28 项**：3 项已复现的高优先级问题、1 项高优先级账号归属设计风险、20 项中优先级问题、4 项低优先级问题。已复现、静态确认和待实测风险分别标注；不声称用户已经丢词、泄露资料或发生线上故障。建议先保护数据与语境，再对取词客户端优化速度。

本次未修改应用源码、未提交/推送/发布；仅新增本审计报告。隔离夹具写在 /tmp。没有读取真实Keychain、API配置、用户词库、原句日志或私人截图，没有登录/写入真实云端，没有执行付费模型请求。

## 验证证据

- 当前完整 Swift 测试 **207 项通过，0失败**；编译将警告视为错误。命令：`swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-pick-audit-20261006 -Xswiftc -warnings-as-errors`。
- `git diff --check -- mac-vocab-capture` 通过；扩展3个JS文件 `node --check` 通过。
- 不存在可调用的LSP诊断工具，因此类型验证采用完整编译和生产源码隔离编译；没有声称运行过LSP静态分析。
- 以下复现使用实际生产实现、假数据与禁用真实存储/Keychain的stub。Swift桥接解析只运行在隔离子进程，未攻击用户运行中的App。

| 隔离场景 | 观测 | 对应问题 |
|---|---|---|
| 损坏旧JSON后保存 | 初始0词，保存后只剩new | H01 |
| 两笔同actor并发同步 | 两笔成功，云端只剩1词 | H02 |
| 负数/Int.max Content-Length | Swift隔离进程exit=-5 | H03 |
| 云端GET/PATCH都是200[] | 仍报告uploadedCount=1 | M01 |
| 同时间戳网页校正词 | 被旧meaning替换，校正元数据丢失 | M02 |
| 删除墓碑后显式重加 | 同步返回0词 | M03 |
| 合成DOM含隐藏script | context含不可见标记 | M07 |
| 取消选区再重选同词句 | 扩展仍只发布1次 | M06 |
| 缩写/小数/5词短语 | 原句截断/原生拒绝 | M11 |
| 保存后连续Enter | 保存闭包从1次变2次 | M13 |
| 相同查询同时执行 | 2次HTTP，之后才缓存 | M14 |
| JSON length / SSE无结束直接EOF | 接受并缓存，复查只有1次HTTP | M15 |
| trim不同的同词 | 本机产生2条 | L01 |

主要临时证据：`/tmp/vocab-storage-audit/Audit.swift`、`/tmp/vocab-audit-cache-probe.swift`、`/tmp/vocab-audit-ui-probe.swift`、`/tmp/vocab-pick-audit-evidence/DictionaryBoundaryCheck.swift` 与 `dictionary-boundary.json`。临时证据不依赖真实凭据，可能随系统清理而消失；需要在后续修复中转为正式回归测试。

测试通过不能证明上述边界不存在：现有Tests没有SelectionReader/BrowserContextBridge覆盖；扩展DOM、跨tab、真实鼠标和进程失败路径未覆盖。当前真实云端RLS、账号写入、全局热键、屏幕权限拒绝、当前模型首释义延迟没有重新系统实测。

## 问题清单

### H01 · 高优先级 · 损坏词库被当作空库，后续保存覆盖旧文件

**证据级别：已复现。** 位置：[VocabularyStore.swift:16](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyStore.swift:16)；[VocabularyStore.swift:35](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyStore.swift:35)。

文件不存在、读取失败、数组解码失败都被 try? 转成空数组。任一历史词条字段类型不兼容也可能让整库解码失败。隔离假库启动数量为 0，保存后磁盘只剩 new；atomic 写入并不保留旧版本。

**优化与验收：** 区分首次无文件与损坏/权限失败。错误状态禁止覆盖，保留原文件并给恢复入口；增加版本标记、滚动备份和导出。验收：损坏、不可读、单条字段异常时旧文件字节不变，恢复后能继续保存。

### H02 · 高优先级 · 云端全量读—合并—写会丢失并发更新

**证据级别：已复现。** 位置：[SupabaseClient.swift:127](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:127)；[SupabaseClient.swift:138](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:138)；[VocabCaptureApp.swift:888](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:888)；[index.html:4176](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/index.html:4176)。

网络 await 使 actor 可重入。截图队列只约束自己的入口，手动同步、普通保存和网页写入仍可重叠。隔离同一 actor 的两个请求都读到空云库，再分别 PATCH alpha 与 beta，最终只剩一个词，两笔均返回成功。跨设备存在同一竞争。

**优化与验收：** 短期统一所有本机同步入口，single-flight 加 pending revision；根本修复需服务端事务合并/RPC，或版本号条件写入、冲突重读重试。单纯换成 upsert 仍会覆盖全量数组。验收：两端并发新增与修改均保留，旧请求不能覆盖新版本。

### H03 · 高优先级 · 本机桥接的畸形 Content-Length 可使进程崩溃

**证据级别：已复现。** 位置：[BrowserContextBridge.swift:74](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:74)；[BrowserContextBridge.swift:49](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:49)。

长度没有非负和上限校验，直接相加与切片。提取生产解析函数到隔离 Swift 子进程：0 正常，-1 导致非法 Range，Int.max 导致溢出，异常子进程 exit=-5。单次 64 KiB receive 也未限制累计数据、连接时间和数量。未向实际 App 发送畸形请求。

**优化与验收：** 先限制头、body、累计字节和连接数；安全校验 0 <= length <= cap，避免先做可能溢出的加法；超时、拒绝无效/重复长度并返回 400/413。验收：负数、极大数、半包、慢连接均不崩溃、不无限积累。

### H04 · 高优先级 · 本机词库没有账号归属，换账号可能混合旧账号内容

**证据级别：静态风险。** 位置：[VocabularyStore.swift:15](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyStore.swift:15)；[VocabCaptureApp.swift:878](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:878)；[VocabCaptureApp.swift:889](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:889)。

所有账号使用同一个 vocabulary.json。登录失效后用 B 登录，成功路径会立即合并整个本机库，包括曾同步至 A 的词条与原句。代码没有账户命名空间或归属检查。未操作真实账号，未声称发生了泄露。

**优化与验收：** 按 user ID 隔离账号库；未登录收集箱与账号库明确区分，显示当前账号和退出/切换入口。同步与落盘校验账号 revision。验收：切换账号不隐式搬运原账号内容，旧会话请求不写入新账号库。

### M01 · 中优先级 · 没有更新任何云端行仍显示同步成功

**证据级别：已复现。** 位置：[SupabaseClient.swift:143](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:143)；[VocabCaptureApp.swift:892](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:892)。

缺少 reader_sync_state 行时 GET 与 PATCH 可以返回 200 []。请求了 return=representation，但客户端只看 HTTP 2xx。隔离空响应仍得到 uploadedCount=1，并会更新时间。当前认证 mock 也返回空数组，未校验真正写入。

**优化与验收：** 检测缺失行并安全创建；解析写入响应，验证唯一的目标用户行和版本。没有确认提交就保留待同步。验收：GET/PATCH [] 不报成功，缺失行可初始化，RLS拒绝/零行更新反馈明确。

### M02 · 中优先级 · Mac 旧释义覆盖网页校正，元数据有损往返

**证据级别：已复现。** 位置：[index.html:6024](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/index.html:6024)；[SupabaseClient.swift:261](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:261)；[VocabularyEntry.swift:45](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyEntry.swift:45)。

网页重新校验释义不更新原 timestamp；Mac 同时间戳优先 local。隔离校正 meaning 被旧 test 替换，definitionCheckedAt/provider 经 Codable 后丢失，再全量写回。新增、修改和校正共用创建时间作为版本。

**优化与验收：** 分离 createdAt 和 updatedAt/version，修改推进版本，规定相同版本冲突策略；保留现有校正元数据及协议扩展字段。验收：校正经 native 同步不回退，支持旧客户端无损往返。

### M03 · 中优先级 · 明确重新收藏已删除词，同步后仍消失

**证据级别：已复现。** 位置：[SupabaseClient.swift:131](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:131)；[VocabCaptureApp.swift:394](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:394)。

deletedVocabKeys 无删除版本/时间，优先过滤所有同词记录。网页删除 alpha 后，用户在 Mac 新保存 alpha，隔离同步结果仍是 0；applySync 会移除刚保存词，与保存成功提示冲突。

**优化与验收：** 把显式恢复与旧设备重放区分，增加有时间/版本的删除与恢复事件；不要粗暴清空所有墓碑。验收：旧副本不复活删除项，用户明确恢复可以成功。

### M04 · 中优先级 · 未收藏选区和原句也默认明文留存

**证据级别：静态确认。** 位置：[ContextDebugLog.swift:19](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/ContextDebugLog.swift:19)；[background.js:31](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/background.js:31)；[content.js:115](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/content.js:115)。

诊断日志无开关，正常取句即写完整 word/context，取消收藏也不清除。扩展自动发布选区并将最新 payload 写 chrome.storage.local，无期限清理；容量轮转不等于短暂留存。与“不后台收集/短暂提供”的说明不一致。

**优化与验收：** 生产默认仅保留耗时、字数、错误类别。原文诊断显式开启且自动到期，提供清除与脱敏导出。扩展用内存或 session/TTL 缓存，提供显式触发和站点开关。验收：默认未收藏选区不持久化。

### M05 · 中优先级 · 桥接无法确认发送者和选区有效性

**证据级别：静态与隔离校验。** 位置：[BrowserContextBridge.swift:60](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:60)；[BrowserContextBridge.swift:80](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:80)；[SelectionReader.swift:35](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SelectionReader.swift:35)。

Loopback 限制正确，但无配对 token、Origin/Host 校验，CORS 为 *。其他本机来源可覆盖缓存；context 只检查目标词子串，cat + scatter 也被接受。未验证真实网页能否穿过浏览器私有网络限制访问端口。

**优化与验收：** 优先评估 Native Messaging；保留 HTTP 时配对、限制来源/方法/内容类型，并校验目标词边界和选区身份。自定义 URL 同样验证调用状态。验收：未配对来源不能写缓存，非法 payload 不返回有效接受。

### M06 · 中优先级 · 浏览器缓存缺少页面身份，TTL 与去重互相冲突

**证据级别：部分复现。** 位置：[BrowserContextBridge.swift:10](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:10)；[BrowserContextBridge.swift:40](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/BrowserContextBridge.swift:40)；[content.js:102](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/content.js:102)。

只有一条全局 word+15s 缓存，没有 tab/URL/窗口/选区版本，跨页同词在新发布前可能拿旧句。扩展 lastPublished 不随取消选择或 TTL 重置；合成 DOM 重选同词句始终只发一次，超过 native TTL 后没有新上下文。跨 tab 错句为控制流风险，未做真实浏览器复现。

**优化与验收：** 带来源和 selection revision；页面、焦点、取消选择使缓存失效。去重设短时间窗，失败不记成功，显式查词可刷新。验收：跨 tab 同词正确，超过15s重选仍可取句。

### M07 · 中优先级 · 网页原句会混入隐藏脚本/节点

**证据级别：已复现。** 位置：[content.js:59](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/content.js:59)；[content.js:74](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/content.js:74)。

body.textContent 和无过滤 TreeWalker 包含 script/style/隐藏节点，没有可靠的块间分隔。真实 content.js 的合成 DOM 测试：仅选可见 bank，发布 context 却含不可见 PUBLIC_HIDDEN_SCRIPT_MARKER。会污染释义，并可能把隐藏内容随查词发送给模型。

**优化与验收：** 从选区附近可见块构建文字和 DOM 偏移映射，排除 script/style/隐藏节点；保留 inline 标签衔接和段落分隔。验收：隐藏内容不发送，跨 inline、跨段、重复词正确。

### M08 · 中优先级 · 浮动按钮可能仍使用上一轮拖选

**证据级别：控制流确认。** 位置：[VocabCaptureApp.swift:547](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:547)；[VocabCaptureApp.swift:571](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:571)；[VocabCaptureApp.swift:628](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:628)。

保存 floatingSelection 后，已有按钮阻止新选区读取。选 A 后6s内改选 B 再点按钮，路径仍使用 A。首次 AX 成功也会挡住后续较准确的 DOM context 重试。鼠标 chord 是 listenOnly 再异步读选区，注释所称先于目标 App 的事件读取没有保证。未做真实鼠标复现。

**优化与验收：** 新 mouseDown/选区变化取消旧快照和旧重试，用 revision 更新按钮；chord 使用已经缓存的有效选区。验收：A→B连续拖选只查 B，旧延迟回调无效。

### M09 · 中优先级 · 主线程 AX 遍历缺少耗时预算

**证据级别：静态风险。** 位置：[SelectionReader.swift:39](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SelectionReader.swift:39)；[SelectionReader.swift:178](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SelectionReader.swift:178)；[VocabCaptureApp.swift:577](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:577)。

热键/浮动按钮同步读取跨进程 AX 属性，可遍历多个祖先和最多800节点；节点数不限制 IPC 耗时。浮动按钮还安排三次主线程尝试。慢目标 App 可阻塞菜单和窗口；未量化当前真实前台 App 延迟。

**优化与验收：** 快路径只读选区/有效缓存；耗时 AX 操作放串行后台队列，设置 IPC/整体预算；按前台应用和选区版本确认返回。诊断祖先扫描默认关。验收：慢 AX provider 不阻塞主 UI，过期结果被丢弃。

### M10 · 中优先级 · 截图权限/执行失败被当成用户取消

**证据级别：控制流确认。** 位置：[VocabCaptureApp.swift:262](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:262)；[VocabCaptureApp.swift:271](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:271)。

screencapture 非零退出或读不到图片都返回 nil，上层静默恢复窗口。没有屏幕录制权限诊断与 stderr 分类。因此用户拒绝权限/工具失败会表现为没有响应。现有截图测试传合成图片，未跑进程失败路径。

**优化与验收：** 返回 canceled/permissionDenied/captureFailed 三类，只有取消静默；提供权限状态与恢复入口。注入 process runner 验收非零退出、损坏图片、正常取消，不需要真实截图。

### M11 · 中优先级 · 断句与短语规则在入口间不一致

**证据级别：已复现。** 位置：[SelectionReader.swift:73](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SelectionReader.swift:73)；[SelectionReader.swift:103](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SelectionReader.swift:103)；[OCRSelection.swift:34](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/OCRSelection.swift:34)；[content.js:5](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/browser-extension/content.js:5)。

任意 . 都作为句末：Dr. Smith 取句丢 Dr.，3.5 percent 取句成 5 percent today.。扩展最多12词、原生4词、OCR无相同限制；as a matter of fact 被原生拒绝，en dash 支持不同。桥接未接受也返204，扩展显示成功。

**优化与验收：** 统一选词契约和句子分段，保护小数/常见缩写，展示可校正语境；明确范围限制。有效响应需表示 payload 已接受。验收：缩写、小数、5词短语、连字符和超限反馈一致。

### M12 · 中优先级 · 取词未关闭思考，问一问设置对此无效

**证据级别：请求已验证/官方文档。** 位置：[AIClient.swift:66](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:66)；[VocabCaptureApp.swift:740](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:740)。

取词仍用独立 DictionaryClient，只发 temperature、max_tokens=120、stream 与 JSON 模式，没有思考控制。隔离请求确认参数缺席。若配置是官方 deepseek-flash，当前官方默认思考开启/high；自建服务实际默认不能一概而论。120输出预算还可能导致结构截断。

**优化与验收：** 复用现有提供商识别/配置规则，为支持的词典服务默认关闭思考，保留用户选项；按模型能力处理JSON、temperature和输出预算。做关闭前后首释义与质量对照，不能直接承诺加速倍数。

### M13 · 中优先级 · 保存成功后回车仍能重复保存

**证据级别：已复现。** 位置：[OCRLookupPanel.swift:264](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/OCRLookupPanel.swift:264)；[OCRLookupPanel.swift:323](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/OCRLookupPanel.swift:323)；[OCRLookupPanel.swift:354](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/OCRLookupPanel.swift:354)。

按钮禁用，但 result/resultSelection 留存，isSaving 恢复 false；键盘入口不检查已保存状态。隔离 AppKit 夹具连续回车保存闭包由1次变2次。本机按词去重，不生成两个词条，但仍触发同步和重复反馈。

**优化与验收：** 按 selection revision 记录已保存状态，按钮、回车和字段提交使用同一判断；每个快照最多保存一次。验收连续回车/长按、保存失败重试、改选下个词。

### M14 · 中优先级 · 完成缓存不能合并同时查询

**证据级别：已复现。** 位置：[AIClient.swift:39](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:39)；[AIClient.swift:73](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:73)；[AIClient.swift:148](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:148)。

两个相同 word/context/service/model/key 请求同时执行，actor 在 await 时重入，分别发 HTTP。隔离生产客户端得到2次 HTTP，第三次完成后才缓存命中；不是常规单窗口回车重发问题。

**优化与验收：** 按现有缓存键合并 in-flight 任务，多个界面订阅同一结果；取消单个订阅者不取消其他订阅者的请求。验收并发、单订阅取消、全部取消、错误不缓存。

### M15 · 中优先级 · 不完整响应可被接受并写入缓存

**证据级别：已复现。** 位置：[AIClient.swift:116](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:116)；[AIClient.swift:128](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:128)；[AIClient.swift:148](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:148)。

普通 JSON 路径不查 finish_reason；SSE EOF 不要求有效完成事件。生产AIClient隔离验证：完整字段JSON但finish_reason=length，以及只有内容后直接EOF的SSE都被接受，下一次从缓存返回。解析出JSON不等于服务正常完成。

**优化与验收：** 两条路径统一完成性规则，拒绝length/aborted/content_filter等失败结束；流式要求协议有效终止。保持普通JSON兼容但验证完成状态。验收失败不缓存、不允许保存，错误前预览清除。

### M16 · 中优先级 · 取词没有产品级总截止与响应字节上限

**证据级别：静态确认。** 位置：[AIClient.swift:54](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:54)；[AIClient.swift:84](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:84)；[AIClient.swift:126](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:126)。

依赖URLSession默认超时，持续心跳可不断刷新等待计时；lineBytes/payload/content及普通JSON数据无限追加。max_tokens不能约束异常HTTP服务返回字节。Apple文档说明request计时在收到数据时重置，resource默认7天。

**优化与验收：** 设置首有效内容截止与整体截止，限制行/事件/内容总字节，支持取消和明确重试。验收心跳不止、超长行、巨型JSON、有预览后停滞，都能在预算内结束。

### M17 · 中优先级 · HTTP错误统一变成泛化服务器错误

**证据级别：静态确认。** 位置：[AIClient.swift:74](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:74)；[OCRLookupPanel.swift:317](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/OCRLookupPanel.swift:317)。

401、429、503 都被压成 badServerResponse，用户无法分辨Key错误、额度、限流、服务故障和连接问题。现有测试仅验证泛化503失败。

**优化与验收：** 安全保留状态分类并给中文恢复操作；401打开取词模型设置。可恢复错误只在无可见输出时按总预算和Retry-After做最多一次重试；错误Key不重试。验收状态分类且不显示敏感服务原文。

### M18 · 中优先级 · 旧取词Key与认证session更新先删后加

**证据级别：静态风险。** 位置：[KeychainStore.swift:26](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/KeychainStore.swift:26)；[KeychainStore.swift:107](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/KeychainStore.swift:107)。

SecItemDelete成功后SecItemAdd失败，旧值已丢；设置提示失败不能保留旧可用凭据。新问答Key使用update优先，但旧取词Key与session仍不同。未操作真实Keychain模拟破坏。

**优化与验收：** 复用SecItemUpdate，只有notFound再Add，统一凭据更新；用可注入Keychain适配器测试失败保留旧值。

### M19 · 中优先级 · 未到期token被拒绝时不能即时恢复登录

**证据级别：静态确认。** 位置：[SupabaseClient.swift:115](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:115)；[SupabaseClient.swift:152](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/SupabaseClient.swift:152)；[VocabCaptureApp.swift:832](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:832)。

本机未过期session被当作已登录。REST认证401不触发受控刷新/重新登录，而是通用server error，手动点击反复走已登录分支。现有测试确认REST失败保留凭据，但没覆盖恢复流程。

**优化与验收：** REST401按认证类型尝试一次刷新/重试，终止认证失败进入重新登录；429/5xx/离线保留session。提供可见账号与退出入口。验收过期、撤销、暂时故障分别恢复。

### M20 · 中优先级 · 待同步状态不持久化，离线恢复不续传

**证据级别：静态确认。** 位置：[VocabCaptureApp.swift:427](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:427)；[VocabCaptureApp.swift:65](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:65)；[VocabCaptureApp.swift:896](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:896)。

保存失败同步后任务结束；重启/网络恢复没有调度，需再保存或手动同步。旧lastSyncedAt只能表示某次成功，不能代表当前词条已上传。每词全量GET/PATCH也放大网络成本。

**优化与验收：** 持久化outbox/待同步版本，统一串行调度，短批次debounce和有界退避；启动/网络恢复续传。显示本机已保存、待同步N、失败、已同步。验收离线保存重启后恢复，退出不会遗失待处理状态。

### L01 · 低优先级 · 词条规范化规则不统一

**证据级别：已复现。** 位置：[VocabularyStore.swift:31](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyStore.swift:31)；[VocabularyStore.swift:55](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyStore.swift:55)。

入参trim后用于比较，保存却保留原字符串，旧词只lowercase。隔离保存“ hello ”和“hello”得到2条。正常入口多已清洗，导入与旧数据影响更明显。

**优化与验收：** 集中canonicalWordKey，用于写入/去重/同步/删除，同时保留展示词形；验收空格、大小写、弯引号/连字符的确定策略。

### L02 · 低优先级 · 收藏日期协议导致网页同日分组失效

**证据级别：静态确认。** 位置：[VocabularyEntry.swift:41](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabularyEntry.swift:41)；[index.html:2914](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/index.html:2914)。

Native addedAt为完整ISO时间，网页直接用addedAt做day键。同一天不同秒会分成多个组，显示完整时间。

**优化与验收：** 存储标准instant，所有显示/分组从时间转换到用户本地日期；验收同一天、多时区和跨午夜。

### L03 · 低优先级 · 取词设置缺少输入预检和规范化

**证据级别：静态确认。** 位置：[VocabCaptureApp.swift:760](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:760)；[AIClient.swift:8](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:8)；[AIClient.swift:48](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/AIClient.swift:48)。

直接保存字段，isComplete只判断非空，空格/非法URL直到查询才发现。请求总是追加/chat/completions，也不统一现有问答的endpoint校验。

**优化与验收：** trim、校验scheme/host/路径和模型名称，复用已有endpoint规则；保存失败保留旧配置，并提供不保存的连接检查。云端默认HTTPS，明确标出本地HTTP选项。

### L04 · 低优先级 · 最近词条存在未使用的旧界面代码

**证据级别：静态确认。** 位置：[VocabCaptureApp.swift:801](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:801)；[VocabCaptureApp.swift:1269](/Users/coty/Documents/Lei_MBP/repo/app_dev/reading_new/mac-vocab-capture/Sources/VocabCapture/VocabCaptureApp.swift:1269)。

实际菜单使用NSAlert显示最近12词；RecentVocabularyViewController和RecentVocabularyListView没有入口，相关recentEntriesPanel未使用。AppDelegate文件1467行，混合采集、同步、设置和多个视图。

**优化与验收：** 决定保留哪种最近词条体验，删除未接入分支；之后按边界拆分协调器与面板。不要为本次audit做整文件重写。验收菜单、快捷键、异步revision保持既有行为。

## 速度优化：按实际取词路径推进

取词是 `SelectionReader/OCR → DictionaryClient(URLSession) → 预览 → VocabularyStore`；“问一问”的LangChain连接池、模型思考配置和直连开关不自动作用于它。不能把问答性能成绩当作取词成绩。

| 优先顺序 | 优化 | 预期作用与边界 |
|---|---|---|
| 1 | 为支持的取词模型明确关闭思考；统一协议能力与输出预算 | 官方DeepSeek默认思考可能是可见释义等待的重要来源。自建服务需确认真实默认；关闭前后做准确率对照。 |
| 2 | 从主线程移出AX慢扫描，取消过期采集，诊断扫描默认关闭 | 减少触发后、AI请求开始前的卡顿；与模型服务排队分别量化。 |
| 3 | 合并in-flight请求；相同完成结果继续复用100条缓存 | 减少多窗口重复请求和成本，不保证单次网络首字必然变快。 |
| 4 | 单独配置与测量取词连接；复用现有传输能力/参数规则 | 按支持服务比较系统网络与可选直连、冷/热连接；不硬编码全部服务直连，也不为此必然迁移Agent。 |
| 5 | OCR取消传递到Vision请求；缓存词范围/正则 | 减少连续截图、拖词时旧工作积压；目前没用真实截图量化收益。 |
| 6 | 同步批次、增量outbox、词库索引 | 降低每词全库编码、GET/PATCH与O(n²)合并。小词库保留JSON也可，是否SQLite由规模实测决定。 |

建议性能指标使用单调时钟：`capture_ms / context_ms / ocr_ms / request_headers_ms / first_visible_meaning_ms / complete_ms / save_ms / sync_ms / cache_hit / canceled`。默认只记录耗时和字数，不记录原文或Key；首token与首个完整中文meaning分别统计。

评测矩阵包含：原生AX、网页扩展、截图OCR；单词/短语/长句；冷/热连接、命中/未命中缓存；各实际支持提供商；思考开/关。采集足够重复样本报告P50/P95及失败率，同时使用多义词/短语金标准评测质量。已有0.2.57记录的约263–443ms可见释义来自当时本机Qwen简单词样本，不是0.2.74所有服务的速度保证，本次没有新的真实API速度样本。

## 产品与质量优化

- **保存与同步状态分开。** 显示本机已保存、待同步数量、最近错误和当前账号；成功不靠一个全局时间戳推断，提供一次性保存与撤销。
- **统一确认面板。** 普通选词与OCR都能核对/编辑原文、目标词与最终释义；显示语境来源（AX/扩展/剪贴板/OCR），减少“看起来查的是B，实际保存A”。剪贴板fallback只读取已有剪贴板，没有自动复制当前选区，不应把旧内容静默称为当前选词。
- **保留更多遇词记录。** 当前同词重复收藏返回旧entry，新语境/义项不会保存。可以先提供追加语境或替换释义，不强制立即引入新的数据库。保留来源URL/应用名和采集方式，提高可追溯性。
- **结构正确与语言正确分开评测。** 目前JSON与非空meaning只保证结构；建立bank/run/left、take off、否定、分词、专名、搭配金标准。规则放system，原文独立结构化为不可信资料；没有真实模型注入实验，不声称已经证明被攻击。
- **可见的权限与诊断状态。** 展示辅助功能、屏幕录制、鼠标监听、扩展桥接是否正常；授权后可恢复监听，处理event tap被系统禁用；错误提供对应恢复入口。
- **可访问性与长内容。** 取词预览/OCR沿用可调字体、限制到屏幕工作区，长释义与语境可滚动/展开；小屏、长短语、长note、大字体、键盘焦点和VoiceOver做独立回归。隔离超长字段把预览从520撑到1144，说明需要布局上限，但没有声称日常输入必然裁切。

## 建议实施顺序

1. **数据与稳定性补丁：H01/H02/H03，并明确H04账号归属。** 先保护损坏库、规范桥接输入、统一本机同步并发；跨设备用事务/版本控制。补回归后再打包。
2. **同步可信度：M01/M02/M03/M18/M19/M20。** 确认实际云端提交，修订词条版本/恢复协议，失败保留凭据与待同步状态。
3. **语境、隐私和交互：M04–M11/M13。** 保证捕捉对的句子、显示来源、默认不持久化未收藏内容，纠正重复保存和权限静默。
4. **性能与模型可靠性：M12/M14–M17。** 关闭支持服务的思考、合并请求、严格完成性和预算，再按当前版本重新测P50/P95与准确率。
5. **精简与扩展：L01–L04和产品优化。** 统一规范化和日期、删除未使用视图，按实测词库规模决定数据层演进；不引入未经需要的依赖。

## 应保留的已有措施

本机atomic写入、add/applySync失败回滚、同步期间新增保护；OCR的revision、取消与旧答案隔离；完整结果前禁止保存；缓存按词/完整语境/模型/服务/凭据隔离，错误不缓存；确认continuation只恢复一次；刷新token single-flight与旧刷新不能覆盖新登录；密码不保存、Key与session用Keychain；PATCH只更新词库/更新时间，schema中owner RLS。这些措施有效，但不能替代缺失的完成性、损坏库保护、账号归属和跨端并发控制。部署中的实际RLS未核查。

## 官方依据

- DeepSeek官方当前说明思考默认开启/high，Chat Completions支持显式disabled：[Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)。这是M12对官方DeepSeek的依据，不推断自建服务默认。
- Apple说明request timeout在收到数据时重置，默认60s；resource整体默认7天：[Request timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest)、[Resource timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource)。本次通过官方Markdown读取，应用应提供自己的总预算。
- PostgREST将PATCH更新与POST upsert区分；upsert不能解决全量数组并发覆盖：[Tables and Views](https://docs.postgrest.org/en/stable/references/api/tables_views.html#update)。
- 使用code-review与Supabase技能进行审查，核对Supabase更新索引；未执行云端迁移、授权或配置变更。
