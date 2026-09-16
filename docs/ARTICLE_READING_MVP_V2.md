# 篇章阅读 MVP V2：可运行约定

> 状态：已实现为受控 MVP；不是通用 Schema 定稿，也不替代
> [`READING_COMPREHENSION_FRAMEWORK_V2_DISCUSSION.md`](./READING_COMPREHENSION_FRAMEWORK_V2_DISCUSSION.md) 的理论框架。

## 1. 这次 MVP 验证什么

MVP 只验证一条自然的阅读回路，而不是给每一个 paragraph 出一题：

```text
标题 / 开头 → 粗略预期 → 读到一个有意义的位置
  → 选择这部分怎样更新理解 → 回原文取证
  → 把更新放入自己的文章地图 → 形成全文理解
```

初始预期不判对错；检查点和全文选择可反复修改。孩子不会在开始时看到专家模型的 `central_idea`、结构标签或未选答案的对错。

## 2. 本次样本

| 文章 | 文体 | 专家语义模型 |
| --- | --- | --- |
| RE Foundations / 10A / Wild Weather | 说明文 | `idea_graph` |
| RE Foundations / 5A / The Disease Detective | 叙事文 | `goal_event_graph` |
| RFD1 / Unit 10 / Body Image | 议论 / 建议文 | `claim_reason_graph` |

受控样本位于 `data/article-reading-mvp-v2/`。该目录因全局 `data/**` 忽略规则而需要显式纳入版本控制。

## 3. `2.0-mvp` 数据边界

```text
article          文体、标题与稳定文章 ID
analysis         专家 Text Model：semantic / discourse / organization / rhetoric
pedagogy         从 Text Model 选出的教学检查点与可接受证据
learner progress 存在浏览器本地状态；绝不回写 article model
```

`analysis` 允许不同文体使用不同的 semantic model；`pedagogy` 只决定何时聚焦哪一段、可用哪些候选、哪些原文句子可支撑，不是把 `analysis` 直接展示给儿童。

每个 checkpoint 有：

- `paragraph_numbers`：当前阅读范围；
- `options` 和 `accepted_option_ids`：本次“理解更新”的有限候选；
- `source_ids`：此刻可以点击的原文范围；
- `accepted_source_ids`：能直接支撑本次更新的证据集合；
- `map_label`：只在孩子完成后放入其文章地图的简短标签。

## 4. Runtime 行为约束

1. 文章进入时加载预计算 sidecar；阅读过程中不调用 LLM 解释篇章结构或生成答案。
2. 当前检查点通过后，才开启左侧对应句子的点击；点击同一句第二次会取消选择。
3. 错误选择不会锁定：选择另一项会清除本次检查和证据状态；错误证据也可取消并替换。
4. 证据判断要求至少有一句落在 `accepted_source_ids`；MVP 故意不将“所有候选都选中”视为理想证据质量，后续可加入最少集 / 过度选择反馈。
5. V1 sidecar 及旧的“逐段便签、两遍拼图”只作为兼容实验入口；它不定义正式产品路径。

## 5. 还没有解决的事

- MVP 的候选和证据均为人工审核样本，尚无批量生产与审核工作流；
- 尚未记录孩子的理由、置信度或真正的 revision history；
- 尚未实现检查点之间的预测、section 组织、拖拽连接或低脚手架语音表达；
- 证据接受条件目前是“至少一条可接受证据”，不是 evidence quality rubric；
- 三篇文章仅用于验证三种 Text Model 的分流，不能据此宣称学习效果。

后续扩展应先完善专家标注与审核，再增加 Runtime 动作；不能把 V1 的启发式从 `function`、`relation`、`signals` 再搬进 V2。
