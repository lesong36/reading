# 篇章阅读 V3：多文体 Text Model 与证据优先阅读循环

> 状态：拟实施设计；V2 MVP 用于暴露交互与模型边界问题，不能作为 V3 Runtime 的直接 Schema。
> 决策：`supporting idea`、`textual evidence`、`question evidence` 与 `learner hypothesis` 必须是不同对象。

## 1. 不变的总模型

```text
TEXT → TEXT MODEL → READER PROCESS → MENTAL MODEL
```

- **TEXT**：文章、section、paragraph、sentence、clause、span 的稳定位置；不含解释。
- **TEXT MODEL**：经审核的专家模型；表达文章中的 proposition、relation、organization 与 rhetoric。
- **READER PROCESS**：孩子读到某一范围后，形成、检验、修订理解的动作。
- **MENTAL MODEL**：该孩子已确认或暂定的理解、证据和修订历史；不能回写专家模型。

## 2. 体裁不是单一开关

导入期生成并审核 `genre_profile`，它描述文章的主导方式和局部混合方式；不直接决定 UI。

```json
{
  "genre_profile": {
    "primary": "informational",
    "confidence": 0.91,
    "embedded_modes": [
      { "scope": ["p1", "p2"], "type": "case_narrative" }
    ],
    "child_label": "解释一件事的文章"
  }
}
```

判定必须综合文章的沟通目的、semantic node 类型、relation 分布和 organization scope：

| 主导体裁 | Semantic Model | 常见地图 renderer |
| --- | --- | --- |
| informational | `idea_graph` | `idea_tree`、`section_map`、`cause_chain`、`compare_board` |
| narrative | `event_goal_graph` | `event_path`、`goal_path`、`clue_board` |
| argumentative | `claim_reason_graph` | `claim_board`、`debate_map` |
| hybrid | 由 section scope 组合 | 不同 section 使用不同局部视图 |

`genre_profile.primary` 只是进入模型的先验。真正选择 renderer 的是当前 scope 中已审核的关系形状，例如因果链、对比、事件推进或主张—理由结构。

## 3. 四个不能混用的概念

```text
Supporting idea:  Idea → Idea
Textual evidence: Text span → Learner hypothesis
Question evidence: Text span → Quiz answer
Learner hypothesis: reader state，可成立、可修订、也可被否定
```

例如：

```text
central idea
  └─ major idea：人类活动加剧极端天气
       └─ supporting idea：全球变暖使热浪更常见
            └─ source span：原文的具体句子

孩子的 hypothesis：作者在解释极端天气为什么更强
孩子的 textual evidence：圈出的 global warming 相关句子
```

孩子圈出的句子可以证明其 hypothesis；它不是因此就自动变成文章的 supporting idea。后者是 Text Model 的 proposition node，前者是 Reader Process 中的一次引用动作。

## 4. V3 的最小数据边界

```json
{
  "schema_version": "3.0-draft",
  "article": { "id": "...", "genre_profile": {} },
  "content": { "paragraphs": [] },
  "analysis": {
    "semantic_model": { "kind": "idea_graph", "nodes": [] },
    "relations": [],
    "organization": { "scopes": [] },
    "rhetoric": { "functions": [] }
  },
  "pedagogy": {
    "map_plan": { "renderer": "idea_tree", "max_visible_nodes": 3 },
    "checkpoints": []
  }
}
```

一个 checkpoint 必须表示一次阅读动作，而不是一道改名的选择题：

```json
{
  "id": "cause-update",
  "scope": { "paragraph_ids": ["p3", "p4"] },
  "reader_action": "hypothesize_then_cite",
  "candidate_hypotheses": [],
  "evidence_policy": {
    "minimum_spans": 1,
    "accepted_links": [
      { "hypothesis_id": "cause", "source_ids": ["s21", "s22"] }
    ]
  },
  "map_operation": { "type": "add_node", "parent": "gist", "renderer_slot": "cause" },
  "hint_ladder": []
}
```

`candidate_hypotheses` 是儿童此刻可能形成的理解，绝不是 article 的 supporting ideas 列表。`accepted_links` 校验的是「本次理解—文本证据」配对，而非单独判一句话或一个选项。

## 5. Runtime 的强制顺序

```text
预期 / 当前理解
   ↓
阅读当前 scope
   ↓
形成候选理解（选择、拖拽或表达）
   ↓
从原文圈出证据
   ↓
验证“证据—理解”连接
   ↓
保留 / 修订，并更新局部地图
   ↓
对下一 scope 形成新的预期
```

Runtime 不能先将候选理解判为“对”再要求孩子找事后依据。若配对不成立，反馈应指向两者关系，例如“这句话在说 X；它还没有说明 Y”，允许孩子换证据或修订理解。

## 6. 难度模型

文章难度与教学难度分开。

| 轴 | 可预计算指标 |
| --- | --- |
| language | 词汇、句长、从句/指代、句法嵌套 |
| discourse | proposition 数、relation 类型与密度、section 深度、跨段距离 |
| inference | 是否显式、是否需补前提、观点冲突与反驳 |
| task | 识别、选择、连接、组织、表达所需的输出压力 |

建议先采用四级篇章复杂度，而非伪精确单分：

- **D1**：一个主题、2–3 个显性 major ideas、一种清晰关系。
- **D2**：多个 major ideas，带明确的因果、举例、比较或顺序。
- **D3**：需要把多个 paragraph 组织为 section；部分关系隐含或跨段。
- **D4**：多观点、反驳、嵌套论证、复杂事件视角或混合文体。

`text_complexity` 决定 checkpoint 的粒度；`scaffold_level` 决定孩子一次看多少、系统给多少候选和提示。D3 文章并不必然对每个孩子都使用 D3 的交互难度。

## 7. Renderer 的自适应规则

Runtime 只渲染 `map_plan` 要求的局部视图，最多显示当前节点、父节点和 2–3 个相邻节点。复杂文章使用折叠 section 或逐层展开，不能把完整专家图一次展示给孩子。

| 当前结构 | renderer | 阅读动作 |
| --- | --- | --- |
| major ideas 支撑总体解释 | idea tree | 引用证据后长出 major-idea leaf |
| 明确因果 | cause chain | 将 cause / effect 连接起来 |
| 事件推动故事 | event path | 推进事件，修订人物目标预测 |
| 侦探式叙事 | clue board | 将线索连接到暂定解释，再修订 |
| 主张—理由—证据 | claim board | 把理由、证据接到主张；必要时展示反方枝 |

## 8. 交互脚手架

| Level | 孩子先做什么 | 系统支持 |
| --- | --- | --- |
| 1 | 从限定范围圈一句重要原文 | 少量 scope、可撤销、图标提示 |
| 2 | 将原文拖到自己选择的理解卡 | 提供语义接近、非荒谬的候选理解 |
| 3 | 自己组织一条理解，再选证据 | 给 phrase bank 与最少证据提示 |
| 4 | 语音/短句表达理解并引用原文 | 只帮助澄清与回指，不替孩子生成答案 |

若保留选择题，干扰项必须是同 topic、不同 scope 或不同 relation 的近邻：太窄的真实细节、范围过大的概括、因果倒置、错误连接、另一段的真实观点。禁止用荒谬内容当作默认错误项。

## 9. 实施顺序

1. 写 validator：每个 `analysis` node、relation 与 `pedagogy` link 都必须指向稳定原文 scope。
2. 重做一篇 D1/D2 说明文：`hypothesis → evidence → link validation → map update`；先不显示全文答案。
3. 用同一 Reader Process 分别做一篇 `event_path` 和一篇 `claim_board`，验证 renderer 可替换而交互循环不变。
4. 再扩展 complex scope、拖拽、自由表达和审核工作流。

V2 的树、预判选择和 `accepted_source_ids` 仅保留为 MVP 历史实现；不得作为 V3 的语义来源。
