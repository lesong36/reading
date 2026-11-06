# 0.3.6 功能整合验收

最终状态：整合、安装与验收完成（2026-11-05）。下文保留排查过程，后续结果覆盖前面的待办状态。

目标：以完整0.2工作版本为基础，叠加0.3.6新增功能；不以较旧0.3分支替换数学功能。

## 已整合
- Markdown、LaTeX、Mermaid及数学专用图渲染、回答复制按钮。
- 版本6题库、原图、平铺标签、筛选、备份恢复、PDF、答案审核。
- 167份项目数学技能及后台教研、自动候选、模型配置。
- 0.3.6问答会话持久化、新建恢复、记录菜单、追加截图与附件保存。
- 原位OCR、逐词选择、键盘范围、内容变化处理、多屏区域及坐标转换。

## 验证证据（2026-11-05）
- 0.2核心文件保留清单：v036-preservation-missing.json为空；这是文件完整性检查，不等同于所有交互验收。
- 完整Swift回归：1234项，66项跳过，0失败；/tmp/v036-full-regression-v2.log。
- 渲染专项7项通过，实际WKWebView截图确认Markdown表格、公式及Mermaid；/tmp/v036-renderer-preview.png。
- 167份技能校验通过；修复技能与教研profile哈希不一致，增加版本绑定检查和篡改副本负测。
- 真实版本6数据库只读备份副本加载通过；/tmp/v036-real-db-check.log。
- 最终包及安装目录codesign深度严格校验通过；280个渲染及数学资源与源码一致。
- 已安装至 /Users/coty/Applications/拾词助手.app，版本0.3.6。
- 安装版实际界面成功读取原有20道题，标签、方法、审核与PDF入口可见；旧版数据库版本报错消失。
- 原应用与数据备份：/Users/coty/Library/Application Support/VocabCapture/integration-backups/20261105-004308/。

## 验证边界
安装版截图问答的系统框选未接收自动化拖动，本轮已取消框选。复制、渲染、会话及追加截图已有源码和自动化测试依据，但尚未完成安装版手动端到端验收。不能据此宣称全部真实交互均已验收，亦未重新认证数学模型正确率。

## 主要修改文件
ScreenshotQuestionPanel.swift、VocabCaptureApp.swift、OCRLookupPanel.swift、OCRCapture.swift、OCRSelection.swift、ScreenshotRegionCapture.swift；新增SessionStore/Models、原位OCR与区域选择组件及对应测试；VERSION、技能profile与validate-math-skills.py。

沿用已有数学渲染、题库和技能实现，合并新增会话及OCR能力，没有新增第三方依赖。

## 会话合并补充修复
新建会话改为统一清空富文本、复制状态和未完成请求，并保存当前截图；恢复会话正确更新原图与保存上下文、显示实际标题；OCR问答追加截图转移窗口所有权，避免关闭父窗口时丢失会话。复用既有clearConversation/updateContext，不新增依赖。
窗口与复制/恢复/新建会话23项通过，题库保存/会话存储/渲染26项通过，OCR/截图/窗口联合36项通过；新增OCR窗口所有权交接测试后OCR专项9项通过。日志分别为/tmp/v036-session-window-tests-final.log、/tmp/v036-session-save-regression.log、/tmp/v036-append-integration-tests.log、/tmp/v036-ocr-transfer-tests.log。
修复后重新打包、深度签名校验、安装并通过Finder启动；实际20题题库正常显示。最新打包日志/tmp/v036-package-final-session.log。完整1234项回归是补充修复之前的结果，后续使用上述受影响专项验证。

## 安装版实际验收补充
用户完成真实框选后，实际安装目录AnswerRenderer/index.html加载成功。通过当前deepseek-flash生成格式测试，安装版AX树与截图均显示二级标题、粗体、上标、分式、表格与Mermaid流程图。点击复制显示“已复制”，粘贴回未提交输入框核对Markdown、LaTeX与Mermaid源码完整，随后清空草稿。未保存测试为数学题、未修改审核结论。
通过问答记录新建会话后富文本为空且复制禁用，随后恢复旧会话，原回答、图表、标题及复制状态均恢复。追加截图已进入系统框选，等待用户完成该手动步骤。
与原0.2实际工作目录Sources及question-engine逐文件比对，仅六份Swift合并文件及已说明的教研profile不同；未发现核心文件缺失，六份文件原函数名均保留。清单v036-baseline-differences.json。该证据结合专项与全量回归，不单独作为行为完全等价证明。

## 追加截图现场发现与修复
用户未看到选择界面，原“只差手动框选”的判断不充分。新回归实际证实：原无边框NSPanel不能成为key window，且hidesOnDeactivate为true；选择界面既无标题、也无操作提示。已改为可接收键盘的专用Panel、禁止随焦点隐藏、加截图选区无障碍名称、十字光标与“拖动框选…Esc取消”提示。测试先失败4处，修复后通过。
应用层新增真实capture回调→PNG读取→OCR→原窗口更新测试，确认已生成回答仍保留；新增取消追加后普通截图必须新开会话测试，并修正取消/失败路径清除追加状态。相关20项通过，3项跳过。日志/tmp/v036-selector-regression-before.log、/tmp/v036-append-full-chain.log、/tmp/v036-selector-append-final.log。待安装新版现场验证，不把该问题误报为用户尚未操作。

## 最新验收状态
修复选择器不能成为key window与随焦点隐藏后，安装版已通过一次自动框选并实际返回问答；追加现场复现“历史仍存储、富文本显示被清空”，现已在updateContext刷新后统一renderTranscript，并给出保留会话提示。窗口/数学应用/选择器53项通过（3跳过），日志/tmp/v036-final-append-display.log。
选择界面还会收到没有对应mouseDown的松开事件；现忽略该事件，回归测试覆盖。最终相关20项通过（3跳过），日志/tmp/v036-selector-release-final.log；最新包/tmp/v036-package-release-guard.log深度签名通过并已安装。
测试工厂改为显式注入临时SessionStore，防止会话测试写入日常目录。通过创建时间、16×16附件和测试标题确认的3条本轮夹具已从会话索引移入备份，图片资产未删除，备份在question-sessions/integration-test-fixtures-backup-20261105。
最后一轮自动化焦点仍与选区交互冲突，不能宣称安装版追加完整闭环验收通过。已明确让用户自行按快捷键与追加截图操作，自动化停止点击以免干扰。功能整合代码、测试和安装已完成，现场追加的最终确认仍待获得，不标记goal完成。

## 用户现场反馈与最终包核对
用户对手动截图、追加操作反馈“似乎没有问题”。该反馈记录为现场未发现异常，不扩展为全部模型答案正确或所有多屏场景通过。
安装版主程序与Info.plist和最终签名包逐字节一致；codesign深度严格验证通过。安装目录280个MathSkills、MathTeachingReview、AnswerRenderer资源与当前源文件SHA256全部一致。167份技能manifest及profile绑定校验通过。最后完整回归日志/tmp/v036-full-final-regression.log，等待进程结束后补充结果。

## 最终验收结论
最终代码完整Swift回归1239项，66项明确跳过，0失败，354秒；进程退出码0。日志/tmp/v036-full-final-regression.log。跳过项主要为需显式启用的现场/模型测试，不宣称全部线上模型与全部屏幕配置都重新验证。

| 目标 | 当前证据 | 结论 |
|---|---|---|
| 保留0.2功能 | 实际0.2工作目录核心文件无缺失，除六份Swift合并文件和教研profile外源码及后端一致；原函数保留；完整回归及真实20题题库 | 完成 |
| 叠加0.3.6功能 | 会话存储/恢复/追加、原位OCR、内容变化与多屏选择组件已整合；专项及完整回归 | 完成 |
| 渲染与复制 | 安装版实际生成Markdown/LaTeX/Mermaid，复制后粘贴核对源码，历史恢复现场通过 | 完成 |
| 截图与追加 | 修复选择器焦点、隐藏、误松开取消及追加后显示；截图回调→OCR→原窗口与富文本回归；用户手动反馈“似乎没有问题” | 完成 |
| 交付安装 | 主程序/Info.plist匹配签名包；280个资源哈希一致；签名通过；167技能校验通过；已启动原题库 | 完成 |

整合来源：完整数学工作版本位于/Users/coty/.codex/worktrees/791a/reading_new；新增功能来源codex/v0.3-development的6dc5c3ac。当前交付源码位于/Users/coty/.codex/worktrees/1737/reading_new。后续升级应以本整合目录为基础，避免从旧0.3分支重新打包而丢失未提交数学文件。

本次验收是功能整合与回归，不重新认证模型数学正确率；用户审核边界继续保留。没有新增第三方依赖，复用已有会话、上下文更新、富文本与题库实现。
