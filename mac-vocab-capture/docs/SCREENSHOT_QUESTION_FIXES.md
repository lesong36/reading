# 截图问答换行与语法判断复核

日期：2026-10-05；版本：0.2.60。

## 换行修复

用户报告长回答在右侧裁切。旧版本用 NSTextView.string 替换正文，会沿用已有段落属性；测试将段落置为裁切后，旧渲染器的长回答只有 54 点高度，未换行。此次明确指定每次渲染的字体、颜色与按词换行样式，并在呈现、更新和窗口缩放时同步文本视图、文本容器与滚动区可见宽度，保持无限制的文本容器高度。

原生测试窗口使用实际 ScreenshotQuestionPanel，由 CUA 输入长回答测试问题并通过测试菜单切换 600、940 点宽度；长段落均重新排版，右侧无裁切。窄窗口正文容器 526 点、可见区 554 点；宽窗口分别为 866、894 点，保留左右各 14 点内边距。视觉检查 96/100，pass。独立测试程序的固定内容用于布局检查，不能证明模型答案正确。

新增回归测试覆盖流式及完整长回答、放大和缩小后的重新换行、以及旧段落裁切属性不会影响后续回答；旧渲染器快照在裁切测试中失败，新版本通过。字体和版式只在渲染时明确指定，不引入额外 UI 层或依赖。

## 正确的语法解释

按标准书面语及考试英语，应为：

- There's a new car in front of his sister and him.
- There's a new car in front of my sister and me.

in front of 后的并列成分作介词宾语，并列不会把代词变为主语；拆开检查就是 in front of him、in front of me。旧答案编造“主格优先”规则，并把常见非标准用法说成正式标准，结论和解释都有错误。[Cambridge Grammar：个人代词](https://dictionary.cambridge.org/grammar/british-grammar/pronouns-personal-i-me-you-him-her-etc) 说明介词后使用宾格。

## 模型问题尚未解决

沿用用户配置的本机 llama.cpp、Qwen3.6-35B-A3B Uncensored Q6_K_P，没有变更模型、服务或向外部服务发送材料。合成文本复现了旧回答，并检查中文标准语法规则、结论一致性、英文规则与不同句子的教学示例。临时把历史作为引用 JSON 也只部分改善，仍会产生矛盾，未加入生产。

最终只保留简短通用规则：优先用户最新句子；按标准/考试英语判断；检查语法支配关系、并列拆分和代词对应；允许纠正历史错答。没有针对用户句子写死输出，也没有保留无效的大段英文与示例。

最终生产提示的四个针对性真实流式案例：

| 场景 | 结果 |
|---|---|
| 新问 my sister and I | 正确改为 me |
| 新问 his sister and he | 仍错误认为可接受 |
| 错历史后复核 him | 最终改对，但开头判断仍矛盾 |
| 错历史后输入新的 I 句 | 仍错误判为正确 |

只有一个案例的判断与解释同时正确，样本不是整体准确率评测。客户端测试只能验证请求与规则契约，不能据此声称语法问题修复。当前模型的语法知识和纠错可靠性不足，未来需要实际评估更可靠模型，而不应继续堆提示来掩盖问题。

## 修改文件

- Sources/VocabCapture/ScreenshotQuestionPanel.swift：显式换行样式和随窗口变化的正文宽度。
- Sources/VocabCapture/ScreenshotQuestionClient.swift：简短来源与语法判断规则。
- Tests/VocabCaptureTests/ScreenshotQuestionPanelTests.swift、ScreenshotQuestionClientTests.swift：布局回归与请求契约。
- Tests/VocabCaptureTests/DictionaryClientTests.swift：把早期释义测试从定时间隔改为预览回调释放剩余响应，避免 URLSession 缓冲及调度造成错误失败。
- README.md、VERSION、本记录：说明、版本与证据。

## 最终验证与安装

77 项完整测试全部通过（0 失败），warnings-as-errors 编译与五个 Swift 文件的严格格式检查通过，差异检查通过。初次完整运行的既有早期释义测试两次因生产者固定时间间隔失败，改为由预览回调释放剩余响应后，目标测试与完整套件均通过；没有更改词典生产逻辑。

发布构建成功，0.2.60 签名通过深度严格校验，已安装到 ~/Applications/拾词助手.app。安装前后词库与偏好文件哈希一致，旧 0.2.59 位于废纸篓，可恢复。构建和测试 App 已清理，更新后的安装路径只有一个运行进程，无最近崩溃报告。CUA 打开菜单栏应用时因没有窗口超时，启动通过目标进程确认；安装后的实际截图快捷键未再次自动化验证。此次未提交或发布 GitHub Release。

换行修复完成；模型语法可靠性问题仍存在，不能把测试通过或提示调整描述为模型准确性修复。
