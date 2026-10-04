# 登录失效恢复验证

日期：2026-10-04；版本：0.2.58。

## 问题与修复

云端返回 `Invalid Refresh Token: Refresh Token Not Found` 后，旧凭据仍留在 Keychain，菜单仅检查是否存在凭据，因而反复同步失败、无法重新登录。

失效刷新响应现在只清除对应的旧 Supabase 会话；手动同步直接进入重新登录窗口。后台取词保留本机生词并提示重新登录。网络中断、限流和服务器错误保留凭据。并发同步共用一次刷新，旧请求不能覆盖或清除新登录；支持将 `expires_in` 转换为可持久化的到期时间。

改动文件：`Sources/VocabCapture/SupabaseClient.swift`、`Sources/VocabCapture/VocabCaptureApp.swift`、`Tests/VocabCaptureTests/SupabaseAuthTests.swift`、`Tests/VocabCaptureTests/SupabaseLoginTests.swift`、`README.md`、`VERSION`，以及本报告。

复用现有 Keychain 存取、词库合并和原生登录窗口；删除登录窗口内部的嵌套任务，让同一个菜单操作持续到登录与同步结束，防止重复打开。未增加依赖。

## 验证结果

- 全套 55 个测试通过，零失败；以 warnings-as-errors 编译。
- 新增 10 个认证回归测试：结构化及旧格式失效响应、重新登录后读写同步、网络和临时错误保留会话、8 个并发同步只刷新一次、旧刷新与新登录/退出竞态、未登录不发请求、正常凭据不刷新、到期时间持久化。
- 新增 2 个登录窗口测试：首次与失效登录文案、空白邮箱与安全密码输入、按钮和输入框布局。
- 原生系统测试使用生产 AppDelegate 同步操作及登录窗口，配合隔离 URLProtocol、会话存储与词库：模拟截图中的错误后出现「请重新登录阅读达人」；取消后再次点击同步进入普通登录窗口；隔离存储确认旧会话已清除。
- Swift 格式检查与 diff 空白检查通过；发布包构建、安装和签名检查通过。

## 验证边界

认证测试使用模拟服务，未输入用户真实密码、未修改真实云端词库。用户需要在更新后的应用中通过「词 → 同步到阅读达人…」输入已有邮箱和密码，才能验证真实账号上传。若暂时不登录，生词继续保存在本机。

参考：[Supabase 认证错误码](https://supabase.com/docs/guides/auth/debugging/error-codes)、[会话及刷新令牌规则](https://supabase.com/docs/guides/auth/sessions)。官方更新日志已检查；本次不更改服务器认证配置或数据库权限。
