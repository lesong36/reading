# 原生词库与真实云端组合验收：H04、M20

验收时间：2026-10-07T04:38:19.416058+08:00（Asia/Shanghai）。

**结论：H04、M20 均 PASS。** 本报告使用实际生产 Swift 类型、两个真实 Supabase 合成测试账号、已部署的 vocabulary v2 RPC；没有用 Python 构造 outbox 或模拟云端响应。

## 验收范围与隔离

- 实际执行 `VocabularyStore`、`VocabularySyncCoordinator`、`SupabaseVocabularySync`、`VocabularyEntry`、`VocabularyPersistence`。
- 编译输入为本次生产 Swift 源码快照，除正常入口 `main.swift` 外全部保留，加入专用临时 CLI 入口。命令包含 `swiftc -swift-version 5 -O -warnings-as-errors`，退出码 0；上述五个核心文件在验收结束时与当前生产源码 SHA-256 一致。
- 临时文件及生产词库实例仅位于 `/tmp/vocab-native-cloud-20261007/`。没有读取真实用户词库、Keychain 或用户偏好。
- 两个合成账号的 session 仅从仓库外、权限 `0600` 的临时文件读入内存并注入客户端。未把密码、JWT、refresh token、账号邮箱或配对码写入终端、报告、命令行或源码。
- 使用现有系统 HTTPS 代理配置，未改变系统网络设置。只向合成账号 B 写入一个本验收专属随机前缀词条；账号 A 仅执行只读 RPC。该词条保留供主验收任务后续统一清理。

## H04：A → B 切换与旧 A 返回隔离

1. 使用真实账号 A，通过生产 `SupabaseVocabularySync.sync(batch:)` 读取实际云端快照；快照包含 **3 个合成词条**，保证测试不是空数据的无效验证。
2. 在实际 RPC 完成之后、生产 coordinator 收到返回值之前，专用门控延迟交付这个真实快照。门控忽略取消直至显式释放，用于稳定重现旧返回晚于账号切换的条件。
3. 将注入的内存账号切换为 B，调用生产 `accountChanged()`。确认 B 的本机词库初始为 **0** 个词条，且写入 scope 属于 B。
4. 释放旧 A 快照。旧同步任务被账号变更 / 取消机制拒绝，B 仍为空；旧 A 返回未写入 B。
5. 使用真实账号 B 再次执行生产 coordinator 同步。B 本机最终 **1 个词条**，词条集合严格等于实际 B 云端快照，当前 scope 仍属于 B。

| 断言 | 结果 |
|---|---|
| A、B 各自真实 RPC 完成 | PASS |
| A 快照非空，晚于切换才交付 coordinator | PASS |
| 旧 A 同步任务被拒绝 | PASS |
| 旧 A 快照未污染 B 本机词库 | PASS |
| B 本机集合等于 B 云端集合 | PASS |
| B 写入 scope 未被旧 A 改回 | PASS |

**接缝说明：** 延迟发生在真实 HTTPS RPC 返回后、coordinator 收到快照前；没有模拟或替换云端数据。这验证原生账号切换、请求世代和持久化隔离的真实云端组合行为。它没有人为延迟底层 HTTPS socket，也不单独证明操作系统网络栈内部的行为。

## M20：断网持久队列、独立进程重启与真实确认

1. 生产者独立 OS 进程 **PID 71830**：先用生产 coordinator 和真实 B RPC 取得基线，再通过生产 `VocabularyStore.add` 保存一个公开合成词条。
2. 在网络同步闭包的边界注入 `URLError.notConnectedToInternet` 模拟断网。生产 coordinator 同步失败，但实际生产文件中的 pending 数仍为 **1**，操作 ID 已持久化。
3. 生产者进程立即退出，未调用 coordinator 的正常 shutdown，也未完成同步。没有把内存对象传递给后续进程。
4. 消费者为新的独立 OS 进程 **PID 72021**：重新创建实际 `VocabularyStore` 和 `VocabularySyncCoordinator`，加载相同临时目录。确认 pending **1**，操作 ID 与前进程严格相同。
5. 使用生产 Supabase 客户端调用真实 RPC，pending 从 **1 → 0**，上传计数为 1；云端仅有一个该词条，revision 从 **1 → 2**。
6. 再次提交确认前的原始生产 batch，包含相同操作 ID。真实 RPC 返回同一操作确认回执，revision 仍为 **2**，没有重复词条。
7. 再次执行生产 coordinator 同步，上传计数 **0**。

| 断言 | 结果 |
|---|---|
| 实际生产 Store 保存词条与 pending | PASS |
| 模拟断网后 pending 保留 | PASS |
| 两个真实独立 OS 进程，非重建同进程对象 | PASS |
| 重启后操作 ID 不变 | PASS |
| 真实 RPC 确认后 pending 归零 | PASS |
| 首次真实上传仅增加一次 revision | PASS |
| 相同 batch 重放不重复增加 revision 或词条 | PASS |
| 后续 coordinator 同步不重复上传 | PASS |

**接缝说明：** 断网由同步闭包边界的真实 `URLError` 注入；没有关闭用户网络或修改代理。恢复阶段以真实账号 JWT 执行实际 HTTPS RPC。进程退出测试涵盖“已落盘操作在应用进程退出后恢复”；未模拟突然断电或文件系统硬件故障。

## 原始证据与复现入口

以下均为隔离的仓库外临时文件，不包含真实用户凭据：

- `/tmp/vocab-native-cloud-20261007/main.swift`：专用 CLI，读取凭据时校验文件权限；错误输出仅限安全分类。
- `/tmp/vocab-native-cloud-20261007/source-hashes.json`：生产源码快照校验。
- `/tmp/vocab-native-cloud-20261007/build.log`：严格编译日志。
- `/tmp/vocab-native-cloud-20261007/m20-producer.json`、`m20-consumer.json`、`h04-account.json`：脱敏断言、计数、进程 ID、revision 与结果。

独立执行顺序（命令行不含凭据）：

```sh
/tmp/vocab-native-cloud-20261007/native-cloud-acceptance offline
/tmp/vocab-native-cloud-20261007/native-cloud-acceptance restart
/tmp/vocab-native-cloud-20261007/native-cloud-acceptance accounts
```

三次执行均打印相应 `PASS`，退出码均为 0。重跑必须使用新的临时词库目录，避免把上次已确认的数据误当首次重启验收。

本报告只关闭 H04、M20 的这两个验收目标；不代替浏览器、系统截图授权、取词响应速度或模型语义质量的独立验收。
