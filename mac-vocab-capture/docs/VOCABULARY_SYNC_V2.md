# 生词同步 v2：事务、版本与账户边界

本轮对应 H02、M01、M02、M03、M19、L02。客户端已停止以整份数组 PATCH/upsert 生词；H04/M20 的账户文件、generation、持久化 outbox 和用户确认由 VocabularyStore/App 协调。部署前 RPC 缺失会明确显示“同步协议尚未升级”，保留待上传内容，不回退到旧协议。

## 请求与确认

`POST /rest/v1/rpc/sync_reader_vocabulary_v2` 参数为 `p_expected_revision`、`p_operations`。只读使用空操作、null revision。服务器通过 `auth.uid()` 确定账户，不接受客户端指定目标账户；锁定该账户唯一 reader_sync_state 行，在同一事务中检查全局 revision、每条 baseVersion、操作 ID 和整个 batch 的合法性。上限每次 500 条、2 MiB。

返回包含 `userID`、`vocabulary`、`revision`、`acknowledgedOperationIDs`、`tombstones`、`uploadedCount`、`conflict`、`conflictingWordKeys`。Native/Web 只有在账户匹配、响应结构正确、每项操作得到唯一确认后才移除 pending。空响应、错误账户、重复/缺失确认都不是成功。

不同词的全局 revision 冲突最多请求三次，只更新全局 revision；相同词的 baseVersion 不会自动升级，因此不会把另一设备的新释义当作可覆盖旧值。相同词冲突保留操作，必须让用户明确采用云端，或再次提交本机编辑。Native 冲突恢复会保存差异备份；网页重新编辑冲突词才生成新 ID 并使用刚读取的云端版本。

删除使用版本墓碑；普通 upsert 无法复活墓碑。用户明确重新添加/导入时发 restore，并引用墓碑 version。操作 ID 的去重凭据按账户长期保存，重试已确认操作不再增加 revision。未来若归档凭据，必须定义新的幂等保留期限，不能随意清空。

条目增加 cloudVersion、updatedAt、definitionCheckedAt、definitionProvider；addedAt/timestamp 保留创建时间。Native 使用 Codable JSON 值保留未知字段，网页释义校正更新 updatedAt。页面按本地日历日期分组，原 ISO 时间不再被当作独立日期组。

## 服务端保护与升级顺序

`supabase/vocabulary-sync-v2.sql` 是可审查、可重复执行的升级脚本；`supabase/schema.sql` 包含相同的 bootstrap 段。当前环境没有 Supabase CLI，未伪造 CLI migration 历史。正式纳入部署流程时，由已有 CLI 的环境生成 migration 并执行 advisors；本轮没有安装工具或部署真实云端。

1. 在隔离/预发布数据库验证脚本和下述测试，确认 Data API 只暴露 public，不包含 reader_private。
2. 备份数据库，发布更新后的网页、macOS 版本与协议说明。客户端未就绪部署时只保留本机待上传，不执行旧整库写。
3. 运行升级 SQL。脚本先在 RLS 保护、无客户端访问权的备份表保存原数组/旧墓碑，再归一化 legacy key、选取最新重复项、增加初始版本。重复执行不会重置非零 revision。
4. 验证真实 JWT/RLS、REST RPC、旧客户端写阻断和网页非词库 upsert。完成后才把涉及服务端的问题标为线上验收完成。

authenticated/anon/PUBLIC 的 reader_sync_state 表级 INSERT/UPDATE 被撤销；仅给 authenticated 授权非词库列的写入。vocabulary/vocab_revision/vocab_tombstones 受到列权限保护，旧 Native PATCH、旧网页全量 upsert 无法绕过 RPC。其他阅读进度、偏好及既有密钥保险箱的列保持原权限与行为，本轮不读取或上传任何真实 API 配置。

公共 RPC 是 SECURITY INVOKER 包装。需要写受保护列的 SECURITY DEFINER 实现在不暴露的 reader_private，固定空 search_path、所有对象显式限定 schema、逐次校验 auth.uid；PUBLIC/anon 无执行权。receipt/升级备份表启用 RLS，客户端无读写权。现有 owner RLS 策略仍保护普通 reader 数据。

旧版本和其他应用如果仍写完整 vocabulary 将收到权限失败，必须升级写入方；不能为了兼容重新开放词库列。未来回滚应保留保护、原始备份和已确认版本，修正客户端/RPC；直接撤掉保护会重新暴露并发丢词风险。

## 客户端登录与网络恢复

Native REST 401 即使本地 expiresAt 尚未到期，也只进行一次受控 refresh，再重试同一幂等 RPC。并发 refresh 复用已有 flight；其他调用已刷新 token 时不再重复刷新。第二次 REST 401 或终端 refresh 错误需要重新登录；429、5xx、离线错误保留会话和操作。账户/session revision 在网络调用前后验证，账号切换后的旧响应不能落入新账户。本机 UI/outbox 使用 accountGeneration 进一步保护切换后结果。

本机每批最多500项，剩余操作继续留在磁盘队列，单轮最多8批后重新排队。只有离线、429及5xx进入有界退避；认证、权限和参数错误等待用户处理。

网络请求已经到达服务器时，客户端无法撤销已提交事务；事务只能影响原 JWT 所属账户的原始操作，切换后不继续发送或应用该账户的后续结果。

网页账号切换只投影该账号的云端快照和待上传操作；未归属词库单独保留，账号词库不写回公共本机词库或OPFS中的未归属词库。旧来源不明词条不自动绑定。

网页 outbox 按 userID 独立持久化，operationID 不随网络重试变化；匿名/旧来源不明词库不自动整库上传。新增、校正、明确删除/导入进入操作队列；读取云端快照不会自动制造上传操作。单 flight 中后续编辑保留独立 ID，只有本次已确认词条的后续本机编辑才基于确认版本推进。词库同步失败不阻塞其他阅读进度写入。

## 验证

```sh
node supabase/tests/vocabulary-sync-v2.test.mjs
python3 supabase/tests/run-vocabulary-sync-v2.py --pg-bin /opt/homebrew/opt/postgresql@17/bin
swift test --package-path mac-vocab-capture --scratch-path /tmp/vocab-opt-sync -Xswiftc -warnings-as-errors --filter 'SupabaseAuthTests|VocabularyProtocolTests'
```

SQL runner 使用已经安装的 PostgreSQL 17，自动创建 UTF-8 临时集群，仅监听临时 Unix socket；测试结束停止并删除集群，不访问真实云库。它先证明旧 schema 允许无保护全量写，再验证升级、私有原始备份、真实 SQL/RLS/权限/幂等/冲突/恢复/其他阅读 upsert，以及两个真实连接并发添加、冲突重试后保留两词。

网页测试使用生产 helper、fake RPC 和内存存储，覆盖持久化、确认、冲突、账户切换、恢复、in-flight 编辑、损坏 outbox、非词库 payload、整页 JSX 语法、更新版本及日期。Native 测试注入 URLProtocol 与 fake session store，不接触真实 Keychain。

已完成本机协议验证；真实 Supabase Data API 的暴露 schema、项目现有 grants/默认权限、JWT 以及生产 RLS 仍须预发布/部署验收。外部 VocabMaster 或其他写入方的兼容升级也尚未在本轮实际运行。没有宣称云端已经上线。

实现依据：[Supabase 数据库函数](https://supabase.com/docs/guides/database/functions)、[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)、[PostgreSQL 行锁](https://www.postgresql.org/docs/current/explicit-locking.html)。
