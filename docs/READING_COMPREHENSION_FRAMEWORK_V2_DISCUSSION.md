# 阅读达人：阅读理解框架 V2 讨论底稿

> 状态：讨论基线，尚未启用；不构成当前 `article.json` Schema 或 Runtime 实现规格。
> 目的：把阅读理论、文章标注模型、儿童阅读过程和 ReadMaster 现有能力分层讨论，避免继续在 V1 上用 UI 规则弥补模型边界问题。

## 1. 这份文档要解决什么

阅读理解不是从线性文字中取出一个标准答案，而是读者在特定目的下，使用文本线索与已有知识，逐渐建构连贯的意义表示。

```text
Linear text → coherent mental model
```

此前讨论的大方向仍然成立：小学阶段先训练孩子从 Paragraph 走向 Text，并采用低输出压力的交互。但需要重新整理层级，不能再把以下事物放在同一层：

- 原文的客观位置（paragraph、sentence）；
- 文章本身的意义与篇章结构；
- 作者在各处的修辞目的；
- 孩子在阅读中采取的动作；
- 考试中出现的题型；
- 孩子最终形成或修正的理解。

本文把这些分开，作为后续 V2 标注实验和 Runtime 设计的共同语言。

## 2. 总框架

```text
UNIVERSAL READING COMPREHENSION
│
├── A. TEXT
│      原文客观提供了什么、在哪里
│
├── B. TEXT MODEL
│      原文信息怎样形成意义、关系、组织与修辞目的
│
├── C. READER PROCESS
│      读者怎样逐步定位、连接、组织、概括、推断与修正
│
└── D. MENTAL MODEL
       读者最终形成的显性、推断和整合理解
```

这四层不是产品四个页面，也不是四套题。它们是分析问题时的边界：一项数据、一段 UI 或一次评估必须知道自己属于哪一层。

## 3. A：TEXT——原文层

```text
Article → Section → Paragraph → Sentence → Clause → Span
```

这一层只保存作者写下的内容和稳定位置。

- `Paragraph`、`Sentence` 是 location / span，不天然等于一个 Idea；
- 现有 ReadMaster 的 `article.data`、`para`、sentence ID、词汇、句法和 TTS 均属于这一层或直接服务这一层；
- 这一层必须是不可随 AI 解释改写的 canonical source。

因此，`p3` 不能被直接当作“第三条 supporting idea”。它只是一个可被意义节点、关系、活动证据引用的文本范围。

## 4. B：TEXT MODEL——文章内部的意义模型

Text Model 不是一句“文章结构”。它至少包含四个相互关联、不可互相替代的系统。

```text
TEXT MODEL
├── Semantic structure       说了什么
├── Discourse relations      信息为什么能连起来
├── Organizational structure 作者怎样安排内容
└── Rhetorical function      作者为什么在这里这样写
```

### 4.1 Semantic structure：意义节点

对说明文，核心抽象是通用的 `Idea` 节点，而不是被固定术语限制的三层树。

```text
Central idea
├── Major idea
│   ├── Supporting idea
│   └── Supporting idea
└── Major idea
    └── Supporting idea
```

每个 Idea 至少需要表达：

- `id`：稳定引用；
- `content`：该意义的简洁表达；
- `role / level`：central、major、supporting、detail 等可扩展角色；
- `source_scope`：它由哪些 text spans 支撑或表达；
- `parent_id` 或 child links：若存在层级关系。

这允许简单文章只有 central → support，也允许复杂文章出现更多层，而不把 `detail`、`example`、`evidence` 错当作同一条层级链。

### 4.2 Discourse relations：意义节点之间的关系

`example`、`evidence`、`explanation`、`contrast`、`cause`、`sequence` 等不是“下一层 idea”，而是两个 spans / ideas 之间的关系。

```text
Claim ← evidence ─ Supporting information
      ← example  ─ Concrete case
      ← explain  ─ Clarification
```

V2 应采用有限、可验证的儿童阅读关系集合，而不是将研究级 taxonomy 原样暴露或让 Parser 自由命名。关系需要有：

- source / target；
- relation type；
- direction；
- 支撑该关系的 source spans；
- 必要时的 nucleus / satellite 重要性信息。

### 4.3 Organizational structure：整体与局部如何安排

说明文常见的结构包括：description / classification、sequence、cause–effect、compare–contrast、problem–solution、general–specific、argument 等。

结构可以嵌套，不应只有一个平面 `text_structure` 字符串。

```text
Article
└── Problem–solution
    ├── Problem
    │   └── Cause–effect
    └── Solutions
        └── Compare–contrast
```

V2 需要表达 structure 的 `type`、`scope` 与 `children`；V1 的单个 `analysis.text.structure.type` 只能作为简化展示，不足以支撑标注与教学。

### 4.4 Rhetorical function：作者为什么在这里这样写

语义内容、关系和作者目的不相同。

例如 “Some researchers, however, disagree.”：

- semantic：一些研究者不同意；
- discourse：contrast / opposition；
- rhetorical function：引入一个相反观点。

儿童版可使用有限、清晰的功能分类，例如 introduce topic、define、explain、illustrate、compare viewpoints、present problem、propose solution、conclude。V2 不应由 Runtime 将几十种自由文本标签临时猜成这些分类。

## 5. Genre-specific semantic model

统一的是总框架，不是所有文章的意义树形状。

```text
Semantic model
├── Expository / informational
│   └── Idea hierarchy
├── Argumentative
│   └── Claim / reason / evidence / warrant / rebuttal
└── Narrative
    └── Character / goal / attempt / outcome / event structure
```

V2 的当前范围仍是小学说明文。Narrative 和 Argumentative 需要自己的 semantic model 与 routine；不应用说明文的 main-idea/support 流程硬套。

## 6. C：READER PROCESS——产品真正要教什么

Reader Process 是孩子构建 Text Model 的过程，不是文章固有属性，也不等同于考试题型。

```text
Locate → Connect → Organize → Generalize
                   ↕
                 Infer → Evaluate

Hypothesize → Read → Verify / Revise → Hypothesize again
```

对小学说明文，V2 的 child-facing routine 可以仍然是两遍阅读，但其内部含义要更严格：

```text
First pass
  locate a paragraph → form a meaning candidate → find support
  → leave a light note → make a low-stakes prediction

Second pass
  revisit notes → identify function and connection → organize idea cards
  → recognize structure → generalize a central idea → infer when warranted
```

其中 `main_idea_candidate` 是孩子的暂时理解，不是系统一开始给出的“答案”。阅读后可由证据、组织和全文概括来确认或修正。

## 7. D：MENTAL MODEL——产品最终要支持的结果

Mental Model 不是另一份文章标注 JSON，而是 learner state 的结果。它可包括：

- explicit meaning：孩子确认的段意、中心意思、关系；
- inferred meaning：由文本证据与背景知识支持的合理推断；
- integrated meaning：孩子把各部分组织成的整体解释；
- confidence / revision history：最初猜想如何被确认或修正。

因此，孩子进度必须与文章 `analysis` 分离保存。文章模型不能因某个孩子的答案被改写；孩子也不应在开始阅读时得到 analysis 的结论。

## 8. 对现有 Article Reading Model V1 的诊断

V1 的 `content / analysis / pedagogy` 顶层边界正确，应保留。但 `analysis` 内部仍是混合层：

| V1 资产 | 主要问题 | V2 方向 |
| --- | --- | --- |
| `topic / main_idea / key_details` | 意义节点、证据与儿童答案混合 | 变为有 scope 的 Idea graph；证据单独相对某个 claim 表达 |
| `relation_to_previous` | 一段只能有一个关系，且只能指向前段 | 独立 relation graph，连接 ideas / spans，可嵌套 |
| `function.type` | Parser 自由输出数十种标签，UI 再归一 | 导入期输出有限 taxonomy 与稳定枚举 |
| `signals` | signal 不等于某个 claim 的可接受证据集合 | 明确 `claim_id`、accepted evidence sets 与质量层级 |
| `text.structure.type` | 只能表达一个扁平标签 | scoped structure tree / forest |
| `pedagogy.activities` | 零散题目，不构成过程 | routine stages，带 target、options、答案与 feedback policy |

V1 Runtime 中 `getChildFunction`、`getChildConnection`、从 `signals` 推测证据等逻辑，正是上述模型边界不足的症状。它们可保留为实验性兼容层，但不应继续扩展为正式规则系统。

## 9. V2 的概念性边界（不是最终 Schema）

仍保持顶层三层：

```text
content       原文与稳定位置
analysis      Text Model：semantic / discourse / organization / rhetoric
pedagogy      对特定文章、特定脚手架的确定性 routine
```

概念形状如下：

```json
{
  "content": { "paragraphs": [] },
  "analysis": {
    "model_kind": "expository",
    "semantic": { "ideas": [] },
    "discourse": { "relations": [] },
    "organization": { "structures": [] },
    "rhetoric": { "functions": [] },
    "inferences": []
  },
  "pedagogy": {
    "routine": {
      "kind": "informational_two_pass",
      "stages": []
    }
  }
}
```

`pedagogy.routine.stages[]` 需要显式给出每次交互的 target、可选答案、错误类型、可接受 evidence sets、提示与解锁条件。Runtime 只渲染和记录，不再临时推断：

```text
free-form parser label → child category
signals + details → accepted evidence
single structure string → learning path
```

这些转换应在导入期完成，或在教研审核阶段明确修订。

## 10. 与当前 ReadMaster 的关系

V2 不是新建一个独立产品。它是 ReadMaster 现有阅读器的文章级理解层。

| ReadMaster 现有能力 | 在 V2 中的位置 | 当前处理 |
| --- | --- | --- |
| 书架、分级、文章导入 | Article discovery / content distribution | 保留 |
| sentence ID、段落、原文展示 | TEXT canonical source | 保留，继续作为 evidence 定位基础 |
| 单词、词组、句法、翻译、TTS | bottom-up support | 保留；只在理解受阻时按需进入 |
| 现有“做题” | assessment / exam practice | 保留；不作为篇章 routine 主流程 |
| 篇章阅读 tab | Reader Process workspace | 未来替换为 V2 deterministic routine |
| AI 问答、个性化解释、语音表达 | optional adaptive support | 不负责重新解析文章或生成地图 |
| 学习记录 | learner mental-model / progress evidence | 扩展为候选、修正、证据和组织过程的记录 |

因此，ReadMaster 的主阅读界面仍是一份原文加工作区；区别是右侧工作区不再是“从 analysis 取答案的题目面板”，而是让孩子逐步构建并修正理解的地方。

## 11. 讨论期决策与非决策

### 已达成的方向

- V1 先聚焦小学说明文；
- `content / analysis / pedagogy` 的顶层分离继续保留；
- 文章导入期深度预解析，阅读 Runtime 尽量确定性；
- 儿童以点、选、连、拖、点击原文为主，逐步降低脚手架；
- 叙事与论证文本不强行复用说明文 semantic model；
- Main Idea 是逐渐形成和修正的理解，不是阅读开始时展示的答案。

### 尚未冻结

- V2 的最小 discourse relation taxonomy；
- Idea graph 的最低必要字段与层级表达；
- structure tree 是否在小学 V2 首版支持嵌套，还是先只保留 scoped flat structures；
- evidence 的质量等级、可接受集合与儿童反馈政策；
- 哪些 reader-process 事件需要保存为长期学习记录；
- 如何将现有 V1 sidecars 迁移或废弃；
- ReadMaster 中篇章 routine 与既有“做题”入口的导航关系。

## 12. 推荐的讨论与实施顺序

1. 先冻结本框架中的层级边界；
2. 单独讨论 V2 最小 Text Model，而不是先写完整 Schema；
3. 选一篇现有说明文做人工标注实验，检查 Idea / Relation / Function / Structure 是否真的能分开；
4. 从该样本倒推 `pedagogy.routine` 的最小确定性字段；
5. 编写 V2 validator 和 fixture，再改 Runtime；
6. 仅在 3–5 篇经过人工审阅的文章上跑 P920；
7. 质量通过后，再决定 RFD1–6 / RE 的批量迁移。

在第 5 步之前，不应继续扩大 V1 Runtime heuristics，也不应大规模重跑现有 120 篇 sidecars。

## 13. 下一次讨论建议：ReadMaster 的产品边界

下一轮应回答的不是“再加什么题”，而是：

1. 阅读器在什么时候进入篇章 routine，什么时候只停留在句子/词汇支撑？
2. “做题”是 routine 后的迁移练习、独立测评，还是同一工作区的另一种模式？
3. 孩子的段落便签、猜想与修正是临时脚手架，还是应该成为可回顾的学习档案？
4. 教师/家长应看到文章的 expert Text Model，还是只看到孩子构建过程的摘要？
5. AI 解释介入的触发条件是什么，怎样避免替孩子完成意义建构？
