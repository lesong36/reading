# 拾词同步：真实云端验收（2026-10-07）

## 结论

真实 Supabase 项目 `reading master` 已完成用户授权后的 v2部署，真实 JWT/REST验收 **11组全部通过**。协调者已安装新版 Native App并发布/验证阅读器网页 v2之后，部署 `vocabulary_sync_v2_atomic_operations`，再刷新 PostgREST schema cache。独立复核确认 RPC、私有实现、收据与升级备份存在，旧 vocabulary列 INSERT/UPDATE权限已撤销。

本报告按阶段保留部署前事实，后文有授权后部署与完整实测结果。真实云端请求只读写本轮两名合成测试用户的记录；没有读取普通用户词条、真实加密 API配置或既有账号凭据。迁移在云端内部保留原始词库备份再升级结构，没有把普通用户数据导出到验收机。未发送邮件。公开 publishable key与测试凭据不进入报告、源码或发行包。

此证据完成服务端环境验收，但不能单独证明实际 Native账号切换期间的迟到响应处理，或生产 Swift持久队列的断网重启。H04/M20这两条客户端系统路径需使用对应 Native证据补齐；完整判定见最后一节。

## 阶段一：部署前只读实测证据（历史记录）

| 检查 | 实际结果 | 含义 |
|---|---|---|
| MCP 项目状态 | `ACTIVE_HEALTHY`，项目 ref `faeixgpjhnwpfzfkgjsu` | 云端管理连接可用。 |
| SQL `server_version` | `17.6` | 查询来自真实项目，不是本地临时集群。 |
| `public.reader_sync_state` | 存在，RLS 已启用 | 原阅读同步表存在。 |
| `reader_private` schema | 不存在 | v2 私有实现/收据/原始备份尚未部署。 |
| `public.sync_reader_vocabulary_v2(bigint,jsonb)` | 不存在 | 新客户端无法在此项目完成 v2 同步。 |
| 版本和墓碑列 | `vocab_revision`、`vocab_tombstones` 不存在 | 服务端尚不能执行新的版本与恢复协议。 |
| authenticated 表级 INSERT/UPDATE | 均为 `true` | 旧整体数组写入保护尚未部署。 |
| authenticated `vocabulary` 列 INSERT/UPDATE | 均为 `true` | 同账号旧客户端仍可覆盖整份 vocabulary。 |
| anon 表级及 vocabulary 列 INSERT/UPDATE | 均为 `true` | grants 较宽；现有 owner RLS 仍限制行，不等同匿名可写任意账号。 |
| owner RLS | INSERT `WITH CHECK(auth.uid() = user_id)`；SELECT/UPDATE `USING(auth.uid() = user_id)`，UPDATE 同样 WITH CHECK | 静态所有权限制存在；不能替代真实 JWT 双账号运行验收。 |
| 最近迁移 | `20261003091353 / p0_learning_sync_email_alerts` | 已登记迁移未包含拾词 v2。以目录缺失证据为主，因为直接执行 SQL 可能不登记历史。 |
| PostgREST 暴露 schema | SQL会话 `pgrst.db_schemas` 与目录角色配置均为 null；实际 REST 下 `reader_private` 为无效 schema | 数据 API 配置需以实际 REST 校验为准，SQL null 本身不是证明。 |
| 公开 RPC REST 探测 | 使用既有系统 HTTPS 代理后 HTTP `404 / PGRST202`：schema cache 没有 `public.sync_reader_vocabulary_v2(p_expected_revision,p_operations)` | 真实 REST 与 SQL 目录一致，v2 RPC 未部署。 |
| `Accept-Profile: reader_private` REST 零行探测 | HTTP `406 / PGRST106`，`Invalid schema: reader_private` | 该 schema 当前不能由此 Data API profile 访问；部署后必须再次验证。 |

RPC REST 调用仅发送 `p_expected_revision:null, p_operations:[]`；该空操作为设计中的只读调用。首次 Python urllib 与直接 curl 出现 TLS reset。协调者发现系统已有 HTTPS 代理 `127.0.0.1:7897`，CLI 默认未使用它；显式采用既有代理后两次 RPC/schema 请求均成功取得 HTTP 响应。没有修改系统代理配置或关闭证书校验。原始 reset 是 CLI 传输配置差异，已解决。

初始 `GET /rest/v1/` 的 OpenAPI 请求返回 HTTP401 `Secret API key required`，本次没有获取或使用 secret key。改用 `GET /rest/v1/reader_sync_state?select=user_id&limit=0` 加 `Accept-Profile: reader_private` 得到上述406；零行请求没有读取用户记录。

当前列名（仅结构）：`user_id, vocabulary, favorites, reading_positions, quiz_progress, wrong_answers, preferences, encrypted_ai_key, updated_at, vocab_master_progress, completion_records`。仅查询列名称/类型，未读取任何列值。

## 部署前六项验收状态（历史记录）

| 问题 | 本次可证明的事实 | 尚缺的真实验收 |
|---|---|---|
| H02 并发全量写丢词 | 新协议未部署，原数组写入权限仍开放 | 发布 v2 后用两个独立 JWT 客户端同时提交不同词及同词冲突；验证最终快照、revision 与精确确认。 |
| H04 账号隔离 | owner RLS 静态表达式正确；本机账户隔离已有独立回归 | 两个专用测试账号实际登录切换、旧请求延迟返回、跨账号读写拒绝。 |
| M01 空响应误报成功 | 新 RPC 不存在；新客户端应显示升级要求并保留 pending | 真实 REST 返回结构、操作 ID 精确确认、失败不清队列，并验收实际 UI 状态。 |
| M02 网页校正被旧释义覆盖 | 没有云端版本列 | 在 Native/Web 分别编辑公开测试词，核对版本冲突、释义与扩展元数据往返。 |
| M03 已删除词显式恢复 | 没有云端墓碑列 | 真正删除、普通旧 upsert 不复活、明确 restore 使用墓碑版本并成功。 |
| M20 离线恢复续传 | 云端缺少 v2 接收与幂等确认 | 专用账号离线添加、重启、恢复网络、断流重试；确认 pending 被精确移除且不重复增 revision。 |

**六项均保持待环境验收。** 本次新增了真实部署状态证据，没有增加“已闭环”计数。

## 部署前拟定的最小后续步骤（保留升级决策记录）

1. 保留数据库备份，审查并部署 [vocabulary-sync-v2.sql](../../supabase/vocabulary-sync-v2.sql)。同时确认所有读写方升级，防止只升级原生端却继续由旧网页整体覆盖。
2. Data API 暴露 schema 中不加入 `reader_private`；确认 `public` RPC 的角色 EXECUTE、私有 SECURITY DEFINER 的 auth.uid 校验及固定 search_path、私有表 RLS/权限，并检查旧 vocabulary 列写入确实被拒绝。不要为兼容旧写法重新开放列权限。
3. 后续 CLI 验收显式采用系统已有 HTTPS 代理（本次已证明可用）。保留证书校验，不使用 `curl -k` 绕过；实际 App 网络还需使用自己的测试路径验证。
4. 使用两个专用测试账号、公开合成词条，在真实 JWT/REST 下运行上表场景。测试账号准备、生产协议部署与测试数据写入均未在本次只读任务执行。
5. 完成 Native/Web 双客户端、并发、断网重启及冲突恢复后，再更新覆盖率；仅在全部场景有记录时把这六项标为通过。

## 文档依据

操作前已读取 Supabase changelog markdown，检查相关 breaking changes；2026-09-25 的 PostgreSQL 小版本公告涉及扩展/索引和加密变化，与本次只读目录检查无直接冲突。本次未升级数据库或修改扩展。

- [Supabase 数据 API 权限与 RLS](https://supabase.com/docs/guides/api/securing-your-api)：grants 决定是否能访问对象，RLS 决定可访问的行，两者不能互相替代。
- [Supabase 自定义 schema](https://supabase.com/docs/guides/api/using-custom-schemas)：Data API 暴露需单独配置，SQL 会话中 null 配置不等于实际未暴露。
- [Supabase 数据库函数](https://supabase.com/docs/guides/database/functions)：函数 EXECUTE 与 SECURITY DEFINER/INVOKER 是独立权限边界。
- [本项目 v2 协议与升级顺序](VOCABULARY_SYNC_V2.md)。

## VocabMaster 写入方兼容检查与发布前置条件

追加只读检查范围为 `/Users/coty/Documents/Lei_MBP/repo/app_dev/vocab-master/vocabulary_app.html`。沿路径未发现附加 AGENTS.md；已阅读其 README。没有读取 `ai_config.json`、`vocab_data.json` 或浏览器本地存储，也未编辑该仓库。以下是当前文件的源码边界，不代表已经发布的 Pages 内容与该文件相同。

| 源码位置 | 读写行为 | 与拾词 v2 的兼容性 |
|---|---|---|
| `vocabulary_app.html:970–980` | 从 `reader_sync_state` 读取 `vocabulary, vocab_master_progress, preferences, encrypted_ai_key`，按当前登录 user_id 过滤 | 单纯读取 vocabulary 可继续使用原数组投影；部署后 authenticated SELECT 必须保留。此检查只读源码，未执行查询加密字段。 |
| `vocabulary_app.html:1170–1175` | 读取该用户的 `vocab_master_progress`，本机合并学习档案 | 不写 vocabulary；v2 新的词条版本字段不会被此位置覆盖。 |
| `vocabulary_app.html:1198–1202` | 唯一 `reader_sync_state` upsert，payload 仅 `user_id, vocab_master_progress, updated_at` | 未发现直接写 vocabulary。升级脚本动态保留这些非词库列 INSERT/UPDATE，因此列权限设计意图兼容，但必须实测 PostgREST upsert 和现有学习进度 trigger。 |
| `vocabulary_app.html:741–746` | 向本机 `DATA_API` POST 应用数据 | 本地服务存档路径，不是 Supabase vocabulary 写入。 |

该文件没有 `sync_reader_vocabulary_v2` 调用；这是合理的读取方/学习进度写入方角色，不能因此把它标为“仍会旧协议覆盖 vocabulary”。真正整体写 vocabulary 的 Native/阅读器网页必须升级；此 VocabMaster 文件只需证明原有非词库写入兼容。

真实云库另有学习进度保护：`vocab_guard_snapshot_v3` trigger 为 `BEFORE INSERT OR UPDATE OF vocab_master_progress`，调用同名 SECURITY DEFINER 函数。本次读取了 trigger 与函数定义，未读取其操作的用户数据。该函数在 INSERT 时会维护学习档案 metadata/baseline，在冲突已有行时延迟副作用到 UPDATE。**现有本地 v2 runner 未包含这个真实 trigger，因此此前“非词库 upsert通过”不是此生产组合的验收。**不得为了让 v2 跑通删除或绕过原有学习事件/快照保护。

### 可审查的协调升级顺序

1. 确认线上 Pages 的版本/资源 hash 与待发布 Native、阅读器网页、VocabMaster 对应。明确每个 vocabulary 写入方、owner 与发布路径；只读本文件不能证明全站没有其他旧客户端。
2. 准备包含生产结构、函数/trigger、grants、owner RLS 的隔离验收库，使用合成数据，不复制真实用户词库/密钥。先复现原有 VocabMaster 成功写入，然后应用 v2 SQL，再运行相同请求；重点覆盖缺失 reader 行 INSERT、已有行 `ON CONFLICT` UPDATE、学习事件 replay 与 vocabulary 快照保持。
3. 原生端/阅读器网页先准备 v2 客户端：RPC 缺失时明确提示并保留本机 pending。发布窗口部署 v2 迁移及相应客户端资源，不开启旧整库写回退。新旧客户端混用必须显示升级需求，不允许恢复 vocabulary 列写权限。
4. 检查迁移不影响既有 `vocab_guard_snapshot_v3`、`sync_vocab_master_v3` 及学习进度数据；校验受保护 vocabulary 列不可通过旧 PATCH/upsert写入，非词库写入仍通过其原有保护。这包含首行初始化与已有行两种路径。
5. 完成真实 Data API 的 grants/RLS/schema检查，然后用下面两个专用账号执行六项验收。记录 build hash、服务端 migration/version、请求结果与脱敏断言。
6. 回滚以修复客户端/RPC为主，保留词条版本、墓碑、收据及原始备份，不通过重开旧 vocabulary 列权限回滚。

### 双账号与跨设备验收前置条件

- 两个专用测试账号 A/B，需要可用的登录方式、验证完成的邮箱及满足项目登录策略。准备不使用普通用户真实词库的账号；本次未创建账号、发验证邮件、修改认证策略或读取真实会话。
- 至少两个独立客户端环境（例如 Native 临时隔离资料目录和独立浏览器 profile），能分别取得 A/B 的真实 JWT。JWT/密码仅保存在测试运行环境，不写入报告或源码。单个模拟 `auth.uid()` 的 SQL 会话无法替代这个条件。
- 测试词全部公开合成，带唯一 run ID，预先约定账号内的测试条目清理方式；只清理该 run 创建的数据。所有请求应验证 owner ID、operation ID、revision 与本机 pending；不得读取其他账号记录来“观察隔离”。
- 具备可恢复的网络故障/延迟注入，验证切换 A→B 后旧响应不进入 B、离线重启恢复、不同词并发、同词冲突、删除与明确恢复、ack丢失后的幂等重放。
- 生产升级及专用账号准备尚待授权/安排。此追加检查没有执行生产修改，不能提高六项闭环计数。

## 用户授权后的生产验收准备

本节记录用户随后明确授权完成全量验收之后的操作；前文“未创建账号/未执行生产修改”描述的是最初只读阶段，不用于描述本节后续操作。

### 原有生产学习保护组合：隔离 SQL 验证通过

新增 `supabase/tests/production-learning-guard-fixture.sql`，仅包含真实云库系统目录的表结构、约束、函数/trigger定义，没有用户行或密钥。内容包括四个学习保护关联表和 `vocab_profile_v3` / `vocab_guard_snapshot_v3` 的生产定义。fixture SHA-256 为 `4ec96a36b7f0cdef2110b682059b3ea2492ef80cda3b1c763eff9cbb4e081a59`，此 fixture 仅用于临时测试库，不部署到生产。

运行：

```sh
python3 supabase/tests/run-vocabulary-sync-v2.py --production-learning-guard
```

`/tmp/vocab-live-production-guard.log` 的新增实测断言均通过：

- v2 迁移前后的真实学习 guard 与 VocabMaster 非词库列 upsert兼容。
- 相同 durable 学习事件重放两次，只保存一条事件且正确次数仅为1。
- 学习进度 upsert不改变 v2 vocabulary 快照或 vocab_revision。
- 缺失 reader 行时 v2 空请求初始化 reader 行，学习 metadata 同时保持有效。
- 原有真实双连接并发、版本冲突、权限、墓碑恢复及重复部署测试同样通过。

该验证复制实际生产函数与所需结构，但仍不是线上 REST 验收；真实 Data API、JWT与生产 trigger组合会在部署后用专用账号再次运行。

### 专用账号真实登录：通过

已在用户授权后创建两名本轮唯一 run ID 的合成测试用户。密码由 PostgreSQL cryptographic random生成、在库内 bcrypt哈希；只有此 run 的新用户写入了 auth.users / identities，并由既有注册 trigger建立对应测试资料和 reader 行。没有读取、修改现有用户，也未调用 signup/invite/resend或发送邮件。首次因用户名格式不符合现有 profiles约束而整个事务回滚；调整为下划线形式后单事务创建两名用户成功。

Auth admin接口需要服务端 secret key，当前工具没有提供该接口/密钥，本轮没有为此获取用户 service_role 或配置 Key。因此先根据实际 Auth系统目录检查字段及 trigger，再创建仅本轮的已确认 email identity，随后**实际调用 GoTrue password grant**验证其能正常登录，未伪造 JWT。

运行 `supabase/tests/run-vocabulary-sync-v2-live.py --auth-only` 已通过真实双账号 password grant，并验证各返回 user ID与预期测试 ID一致。凭据与 JWT仅在仓库之外权限0600临时文件保存，报告/源码/发行包不包含它们。账号不属于正常用户，后续验收结束须撤销其测试会话并清理该 run 的数据和账号。

此阶段完整 live runner已准备，生产升级当时等协调者确认 Native/Web发布就绪后执行，未以登录成功增加问题闭环计数。下一节记录之后的部署与实测。

## 阶段三：协调发布与真实云端完整验收

协调者确认新版已签名校验并安装于 `~/Applications/拾词助手.app`，旧版备份于 `/tmp/vocab-opt-installed-backup-20261007/`；阅读器网页 v2已发布提交 `8fe351a`，并实际读取 [Pages](https://lesong36.github.io/reading/)验证 v2标记。随后协调者通过 MCP成功部署 `vocabulary_sync_v2_atomic_operations` 并执行 `NOTIFY pgrst, 'reload schema'`。云端迁移历史的版本为 `20261006202701`（UTC标记，对应上海时间2026-10-07）。没有移除旧学习保护 trigger。

本报告作者独立再次查询真实系统目录，确认：

| 检查 | 部署后真实结果 |
|---|---|
| public v2 RPC / reader_private schema | 均存在 |
| receipts / upgrade_backup | 均存在 |
| anon vocabulary INSERT / UPDATE | 均为false |
| authenticated vocabulary INSERT / UPDATE | 均为false |
| public RPC SECURITY DEFINER | false，即 SECURITY INVOKER |
| reader_private RPC SECURITY DEFINER | true，沿用已审查的 auth.uid检查和固定 search_path |
| 迁移历史 | 包含 `20261006202701 vocabulary_sync_v2_atomic_operations` |

协调者运行完整 live runner，作者读取并交叉核对日志与 JSON结果：`/tmp/vocab-opt-live-cloud-results.log`、`/tmp/vocab-opt-live-cloud-results.json`，均为以下 **11组PASS**：

1. 两名专用合成用户通过真实 GoTrue password grant登录，并匹配预期 user ID。
2. 实际 RPC读取两名 owner快照，验证返回对象、owner、revision、数组与确认结构。
3. 两个真实并发 REST调用者从相同 revision添加不同词；冲突者重试原 operation ID后两词均保留。
4. 丢失确认后的同 ID重放不增加 revision或重复上传，返回精确 ack。
5. 新释义与 provider/check时间/未来元数据保留，旧 baseVersion同词修改被拒绝。
6. 删除产生版本墓碑，普通 upsert不能复活，显式 restore成功清除墓碑。
7. A/B两个真实 JWT不能读取或更新对方账号行；匿名 RPC被拒绝。
8. 实际 Data API拒绝旧 vocabulary整体 PATCH和 upsert。
9. REST无法访问 reader_private profile，也不能读取 receipts或 upgrade_backup。
10. 实际 VocabMaster非词库列 upsert与生产学习 guard共存，事件重放仅计一次，词库快照/revision不变。
11. Python传输队列落盘后由另一进程重读，同 ID提交真实 RPC并幂等重放。**此项是传输层队列测试，不是 Native Swift持久队列的系统重启测试。**

这些测试用公开合成词条及本轮账号，不复制普通用户数据。没有读取或修改普通用户的 Keychain、现有 Auth会话、API Key或加密保险箱。两名测试账号暂留以供后续 Native验收，未在此阶段提前清理。

### Security advisors：有说明的现存告警

迁移前后均为四个 advisor类别，不能描述为“零告警”：

| 类别 | 级别 | 本轮结论 |
|---|---|---|
| `rls_enabled_no_policy` | INFO | 原有5个表，新增 receipts / upgrade_backup两个表后共7个finding。新表没有客户端grants，RLS无政策刻意 deny-all；真实 REST读取均已拒绝。它们只由 owner检查后的私有事务访问。 |
| `extension_in_public` | WARN | 原有项目告警，本迁移未变更扩展。 |
| `authenticated_security_definer_function_executable` | WARN | 原有项目告警类别；私有 v2 privileged实现属于已审查的必要边界，public包装仍为 invoker，schema不暴露且匿名无 execute。不能把有意授权的函数自动描述为“无风险”。 |
| `auth_leaked_password_protection` | WARN | 原有项目 Auth策略告警；本轮没有改动全项目密码策略。 |

依据：[RLS无政策 linter](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)、[扩展所在 schema linter](https://supabase.com/docs/guides/database/database-linter?lint=0014_extension_in_public)、[authenticated可执行 SECURITY DEFINER linter](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)、[密码泄露保护](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)。

### 六项闭环的独立判定

| 问题 | 真实云端门槛 | 完整问题闭环判断 |
|---|---|---|
| H02 | 通过：并发不同词、相同词版本冲突、旧整体写入阻断 | 结合已有生产 coordinator并发回归，可关闭本项；不是仅以迁移成功作为证明。 |
| M01 | 通过：真实对象响应、owner/operation ID精确确认、匿名/RLS拒绝、禁止旧写入 | 结合 Native严格 ack/空响应拒绝回归可关闭本项。 |
| M02 | 通过：新释义与扩展元数据保留，旧同词写入拒绝 | 结合 Native/Web生产序列化与编辑回归可关闭本项；实际 runner的“跨客户端”是两个 REST调用者，不应描述成已手工运行两款 App的全部编辑界面。 |
| M03 | 通过：真实墓碑删除、隐式复活拒绝、显式 restore | 结合既有客户端删除/恢复回归可关闭本项。 |
| H04 | 通过：真实 A/B登录与账号间 RLS读写拒绝 | 服务端隔离已闭环；实际 Native A→B切换和迟到响应系统验收仍需对应记录。现有 generation回归已覆盖逻辑，但不能把11组 runner冒称该 UI测试。 |
| M20 | 通过：真实 RPC幂等续传及独立进程传输队列恢复 | 服务端续传已闭环；生产 VocabularyStore/VocabularySyncCoordinator真正断网、磁盘重启、再同步仍需 Native验收记录。 |

因此本轮真实云端发布/协议门槛已通过，不再存在“RPC未部署”或“CLI TLS连不通”的阻塞。全项目覆盖率应综合 Native与浏览器等验收证据更新；仅依据本报告的11组 runner，不应把尚缺的两条 Native系统路径宣称已完成。

## 阶段四：验收账号与测试数据收尾清理

协调者告知后续真实云端与 Native组合验收已经完成、不再需要测试账号，并明确授权清理本轮两名用户。此前阶段三的客户端系统路径判定是当时本云端报告的证据边界；最终组合验收以总报告的 Native记录为准。本节仅记录清理，未修改其实现或其他验收文件。

清理精确限定以下两名合成用户：

- A：`d1ad4c22-9e35-4478-ab3f-faf5a8d54450`
- B：`5e2b9d78-3e67-486a-bfd9-44e6e337c93b`

先从系统目录复核 Auth/Public/Private关联 FK、owner列及 trigger，没有查询普通用户行。删除前再次验证两名账号的 `vocab_audit_run` 均等于本轮 `vocab-audit-20261007-bk1c40`；其他账号拥有的测验报告没有以这两名账号作为 reviewer，Storage对象/bucket也没有本轮 owner记录。仅返回匹配两 UUID的计数，未输出账号凭据、词条内容或日志载荷。

通过仅这两名用户的真实 password grant取得可用会话，随后执行 global sign-out。两次登出均成功，再用对应刚撤销的 refresh token请求刷新，均被拒绝。没有操作普通用户会话。此检查证明 refresh续签已撤销，不把 stateless access JWT称作立即失效。

在一个受保护事务中，按 FK顺序先删除这两 UUID的非级联学习事件、快照、metadata/admin override和私有同步健康/incident/delivery记录，再删除其 Auth flow/refresh/SCIM关联数据，最后删除带本轮标记的两条 auth.users。账号删除返回 **2**。profiles、reader_sync_state、词库 receipts/upgrade_backup及 Auth identities/sessions等通过已经检查的 ON DELETE CASCADE清除。没有扩大删除条件，没有取消原生产协议、RLS或学习保护。

删除后独立执行精确 owner过滤的 **36项列/关联检查**，全部匹配行数为 **0**，涵盖 auth.users、profiles、reader_sync_state、学习保护表、receipts、upgrade_backup、Auth identities/sessions/refresh/flow及检查到的 Storage owner列；没有发现非零残留。没有读出普通用户记录来比较全库状态。

仅在云端删除与残留检查成功后，删除仓库外权限0600文件 `/tmp/vocab-live-auth-20261007.json`，确认路径不存在；工具输出未包含任何凭据。本代理没有删除其他代理持有的文件、安装备份或验收日志，也没有修改其他文件。平台自身访问/管理日志遵循服务保留机制，本清理不声称抹去所有平台日志。
