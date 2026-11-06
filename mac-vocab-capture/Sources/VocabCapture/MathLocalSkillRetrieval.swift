import Foundation

/// A local, non-authoritative shortlist. Only user requirements grant teaching
/// permissions; OCR can improve recall but cannot select or approve a method.
enum MathLocalSkillRetrieval {
  static func retrieve(methods: [MathTeachingMethod], requirements: String,
    textHint: String) -> [MathTeachingMethod] {
    // A language task is not mathematical evidence just because its prompt
    // contains a shared word such as “完成” in “过去完成时”. Respect the
    // human's requested action; OCR never overrides it. A combined request
    // explicitly asking to solve the problem still gets the normal shortlist.
    let languageTask = requirements.range(of: #"翻译|译成|(?:英语|英文)语法|(?:解释|分析|讲解)[^。！？!?\n]{0,12}(?:英语|英文|语法|时态)"#, options: .regularExpression) != nil
    let mathTask = ["解题", "算术", "求解", "solve"].contains(where: requirements.lowercased().contains)
    if languageTask && !mathTask { return [] }
    let catalogue = try? MathTeachingReviewCatalogue.load()
    let skills = try? MathSkillCatalogue.load()
    let eligible = MathMethodMatcher.eligibleMethods(methods, question: requirements, catalogue: catalogue)
    // Ambiguous identities cannot safely be reported by the answer's ID protocol.
    let counts = Dictionary(grouping: eligible, by: \.id).mapValues(\.count)
    let documents = eligible.filter { counts[$0.id] == 1 }.map { method in
      return Document(method: method, title: tokens(method.title).union(titleConcepts(method.title)), category: tokens(method.category),
        discovery: tokens(skills?.discoveryMetadata(for: method)?.description ?? ""),
        body: tokens(method.instructions))
    }
    let sourceText = requirements + "\n" + textHint
    let concepts = problemConcepts(sourceText)
    let requestedConcepts = problemConcepts(requirements)
    let query = tokens(sourceText, stripInstructionWords: true).union(concepts)
    // Narrow only when an eligible, unedited project skill actually supplies
    // the detected structure. Otherwise lexical/custom recall remains intact.
    let focusedConcepts = concepts.filter { concept in
      documents.contains { $0.title.contains(concept)
        && skills?.discoveryMetadata(for: $0.method) != nil }
    }
    guard !query.isEmpty, !documents.isEmpty else { return [] }
    var frequency: [String: Int] = [:]
    for document in documents {
      for token in document.all { frequency[token, default: 0] += 1 }
    }
    func weight(_ token: String) -> Double {
      log(1 + Double(documents.count) / Double(frequency[token, default: 0] + 1))
    }
    // Unseen story nouns have no retrieval evidence. Counting their high IDF
    // in the denominator suppresses relationships the catalogue does describe.
    let structural = query.filter { $0.hasPrefix("relation:") }
    let coverageQuery = structural.count >= 2
      ? query.filter { frequency[$0] != nil } : query
    // Stable summation order prevents hash-seeded Set iteration from breaking
    // exact-score ties between otherwise identical candidate documents.
    let queryWeight = coverageQuery.sorted().reduce(0) { $0 + weight($1) }
    guard queryWeight > 0 else { return [] }
    let ranked = documents.compactMap { document -> (MathTeachingMethod, Double)? in
      let overlap = query.intersection(document.all)
      let titleOverlap = query.intersection(document.title)
      let generic: Set<String> = ["问题", "原来", "时间", "人数", "物品", "数量", "总数", "顺序", "次数", "所花", "每人", "几个", "怎么", "怎样", "安排", "重复", "结果"]
      func literalEvidence(_ values: Set<String>) -> Set<String> {
        values.filter { !$0.hasPrefix("relation:") && !generic.contains($0) }
      }
      let titleEvidence = literalEvidence(titleOverlap)
      let discoveryEvidence = literalEvidence(query.intersection(document.discovery))
      let explicitRelations = titleOverlap.filter { $0.hasPrefix("relation:") }
      // Structurally specific methods should not enter through a counterexample
      // in their body when this request supplies no corresponding structure.
      var advertisedConcepts = titleConcepts(document.method.title)
      // Hexagon construction is one branch of this general cutting method.
      // Its recall hint must not exclude the method's other constructions.
      if document.method.title == "几何剪拼与对称构造" {
        advertisedConcepts = advertisedConcepts.filter { concepts.contains($0) }
      }
      // This broad method also serves ordinary sum-and-ratio questions;
      // the chase-specific recall hint must not narrow those cases.
      if document.method.title == "和倍问题" && !concepts.contains("relation:chase-finite-destination") {
        advertisedConcepts.remove("relation:chase-finite-destination")
      }
      if document.method.title == "幻方与拉丁格约束" && !concepts.contains("relation:incomplete-higher-magic") {
        advertisedConcepts.remove("relation:incomplete-higher-magic")
      }
      // Narrow project methods must be supported by the problem itself. Their
      // examples otherwise crowd unrelated methods out of a bounded shortlist.
      if skills?.discoveryMetadata(for: document.method) != nil {
        let title = document.method.title
        if title == "多属性位置与定向相邻推理" && !sourceText.contains(title)
          && !concepts.contains("relation:ordered-multi-attribute") { return nil }
        if title == "面对面座位的左右与身份推理" && !sourceText.contains(title)
          && !concepts.contains("relation:facing-seat-identities") { return nil }
        if title == "对手人数与地区身份推理" && !sourceText.contains(title)
          && !concepts.contains("relation:opponent-identity") { return nil }
        if title == "周循环接待与连续窗口" && !sourceText.contains(title)
          && !concepts.contains("relation:weekly-reception") { return nil }
        if title == "多人语言集合与直接交谈" && !sourceText.contains(title)
          && !concepts.contains("relation:language-intersections") { return nil }
        if title == "报数后选位的数位对抗" && !sourceText.contains(title)
          && !concepts.contains("relation:reported-digit-game") { return nil }
        if title == "可拒乘电梯的单停层总成本" && !sourceText.contains(title)
          && !concepts.contains("relation:optional-elevator-stop") { return nil }
        if title == "整除约束的七数混合极值" && !sourceText.contains(title)
          && !concepts.contains("relation:divisible-mixed-digit-extrema") { return nil }
        if title == "双机统筹与总等待最小化" && !sourceText.contains(title)
          && !concepts.contains("relation:two-machine-waiting") { return nil }
        if title == "边界选点直线分区与图形计数" && !sourceText.contains(title)
          && !(sourceText.contains("三角形") && sourceText.contains("正方形")
            && (sourceText.contains("线段") || sourceText.contains("直线"))
            && (sourceText.contains("部分") || sourceText.contains("区域"))) { return nil }
        if title == "缺角长方形三块拼正方形" && !sourceText.contains(title)
          && !(sourceText.contains("长方形") && sourceText.contains("正方形")
            && sourceText.contains("拼") && (sourceText.contains("割") || sourceText.contains("去掉") || sourceText.contains("缺角"))
            && (sourceText.contains("3") || sourceText.contains("三"))) { return nil }
        if title == "五格十字剪拼正方形" && !sourceText.contains(title)
          && !(sourceText.contains("十字") && sourceText.contains("正方形")
            && (sourceText.contains("剪") || sourceText.contains("切")) && sourceText.contains("拼")
            && (sourceText.contains("5") || sourceText.contains("五"))) { return nil }
        if title == "三角网四块全等分割" && !sourceText.contains(title)
          && !((sourceText.contains("三角网") || sourceText.contains("图"))
            && ["分割", "分成", "分为", "剪成", "切成"].contains(where: sourceText.contains)
            && (sourceText.contains("相同") || sourceText.contains("全等"))
            && (sourceText.contains("4") || sourceText.contains("四"))) { return nil }
        if title == "七块不同尺寸长方形分割" && !sourceText.contains(title)
          && !(sourceText.contains("长方形") && sourceText.contains("分")
            && (sourceText.contains("7") || sourceText.contains("七"))) { return nil }
        if title == "五方格最少正方形铺法" && !sourceText.contains(title)
          && !(sourceText.contains("正方形") && sourceText.contains("拼")
            && (sourceText.contains("最少") || sourceText.contains("至少"))
            && (sourceText.contains("5") || sourceText.contains("五"))) { return nil }
        if title == "三四正方形四块拼五" && !sourceText.contains(title)
          && !(sourceText.contains("正方形") && (sourceText.contains("切") || sourceText.contains("剪"))
            && sourceText.contains("拼") && (sourceText.contains("3") || sourceText.contains("三"))
            && (sourceText.contains("4") || sourceText.contains("四"))) { return nil }
        if title == "全等直角三角形分割构造" && !sourceText.contains(title)
          && !(sourceText.contains("三角形") && (sourceText.contains("全等") || sourceText.contains("形状相同") || sourceText.contains("大小相同") || sourceText.contains("完全相同"))
            && (sourceText.contains("分") || sourceText.contains("拼"))) { return nil }
        if title == "重叠纸片遮挡顺序" && !sourceText.contains(title)
          && !((sourceText.contains("纸片") || sourceText.contains("纸张"))
            && (sourceText.contains("重叠") || sourceText.contains("遮挡") || sourceText.contains("叠放"))) { return nil }
        if title == "不重复棱路线的奇偶与最值" && !sourceText.contains(title)
          && !(sourceText.contains("棱") && (sourceText.contains("不重复") || sourceText.contains("只允许爬一次") || sourceText.contains("只能走一次"))) { return nil }
        if title == "正方形长条的环绕裁剪" && !sourceText.contains(title)
          && !((sourceText.contains("纸条") || sourceText.contains("长条"))
            && (sourceText.contains("剪") || sourceText.contains("裁"))) { return nil }
        if title == "互异数字组成两数的乘积极值" && !sourceText.contains("乘积") && !sourceText.contains("乘法") && !sourceText.contains("×") { return nil }
        if title == "数码和作除数的余数最值" && !(sourceText.contains("余数") && (sourceText.contains("数字") || sourceText.contains("数码"))) { return nil }
        if title == "相邻数码对互异的数位最值" && !(sourceText.contains("相邻") && (sourceText.contains("数码") || sourceText.contains("数字") || sourceText.contains("两位"))) { return nil }
        if title == "同奇偶取平均合并的终值极值" && !(sourceText.contains("平均") && (sourceText.contains("奇偶") || sourceText.contains("奇数") || sourceText.contains("偶数"))) { return nil }
        if title == "圆桌座次的旋转等价与锚点" && !((sourceText.contains("圆桌") || sourceText.contains("围成一圈")) && (sourceText.contains("坐法") || sourceText.contains("座次") || sourceText.contains("排列"))) { return nil }
        if title == "同路程延迟出发与速度变化" && !((sourceText.contains("出发") || sourceText.contains("延迟")) && (sourceText.contains("相遇") || sourceText.contains("到达")) && (sourceText.contains("少走") || sourceText.contains("减速") || sourceText.contains("慢"))) { return nil }
        if (title == "正方体展开图对面与顶点面和" || title == "正方体对顶点表面最短路径") && !sourceText.contains("正方体") { return nil }
      }
      // Narrow project constructions need their defining context, rather than
      // incidental square/triangle words from the body. Manual/custom methods
      // receive no new project trust or restriction from this recall gate.
      let definingRelations: Set<String> = ["relation:regular-dodecagon", "relation:square-midpoint-cycle", "relation:equal-square-reassembly", "relation:rectangle-staircase-reassembly", "relation:square-size-inventory", "relation:square-corner-area-difference", "relation:congruent-rectangle-spans", "relation:central-area-cut", "relation:inventory-thresholds", "relation:circular-capacity", "relation:weighted-class-capacity", "relation:adaptive-bijection", "relation:common-comparison", "relation:first-period-catchup", "relation:stock-baseline", "relation:shared-vertex-flags", "relation:grouped-score-balance", "relation:median-difference-sum", "relation:integer-average-shift", "relation:fixed-sum-product", "relation:constrained-digit-extrema", "relation:digit-subsequence"]
      // The narrow train reconciliation skill needs a multi-event signal.
      // The broad event-line skill also advertises this signal for recall but
      // must remain available for ordinary motion questions.
      if document.method.title.contains("火车车长") && document.method.title.contains("多事件对齐")
        && !concepts.contains("relation:train-event-reconciliation")
        && skills?.discoveryMetadata(for: document.method) != nil { return nil }
      if !advertisedConcepts.intersection(definingRelations).isSubset(of: concepts)
        && skills?.discoveryMetadata(for: document.method) != nil { return nil }
      if !advertisedConcepts.isEmpty && concepts.isDisjoint(with: advertisedConcepts) {
        guard !titleEvidence.isEmpty || discoveryEvidence.count >= 2 else { return nil }
      }
      if !focusedConcepts.isEmpty {
        // A second question can still recall its own method by positive title
        // or discovery evidence (e.g. guarantee sharing plus an average).
        guard !focusedConcepts.isDisjoint(with: document.title)
          || !titleEvidence.isEmpty || discoveryEvidence.count >= 2
          || explicitRelations.count >= 2 else { return nil }
      }
      // A single arbitrary body bigram is too weak; an exact two-character
      // title term (e.g. 盈亏) is useful retrieval evidence, not applicability.
      guard overlap.count >= 2 || !titleOverlap.isEmpty else { return nil }
      let coverage = overlap.sorted().reduce(0) { $0 + weight($1) } / queryWeight
      guard coverage >= 0.08 || !titleOverlap.isEmpty else { return nil }
      let score = overlap.sorted().reduce(0.0) { value, token in
        // An explicit area objective is stronger than incidental shape nouns.
        // “最小正方形面积2” names a unit cell and does not trigger this relation.
        let titleWeight: Double = token == "relation:area-extremum" ? 12 : 5
        return value + weight(token) * (document.title.contains(token) ? titleWeight : document.discovery.contains(token) ? 4 : document.category.contains(token) ? 2 : 1)
      } / sqrt(Double(max(1, document.all.count)))
      return (document.method, score)
    }.sorted {
      $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1
    }
    func roles(_ method: MathTeachingMethod) -> [String] {
      MathMethodMatcher.singleCallRolePolicy(for: method, catalogue: catalogue).roles
    }
    var solutions = Array(ranked.map(\.0).filter { roles($0).contains("solution") }.prefix(5))
    // A whole-page OCR may contain several unrelated motion problems. Preserve
    // the eligible exact project method for the user's explicitly named task;
    // OCR alone cannot activate this priority or grant teaching permission.
    let requestedTitle = requestedConcepts.contains("relation:incomplete-higher-magic") ? "幻方与拉丁格约束"
      : requestedConcepts.contains("relation:cross-congruent-reassembly") ? "几何剪拼与对称构造" : nil
    if let requestedTitle,
      let requested = documents.map(\.method).first(where: {
        $0.title == requestedTitle && roles($0).contains("solution")
          && skills?.discoveryMetadata(for: $0) != nil
      }) {
      solutions.removeAll { $0.id == requested.id }
      solutions.insert(requested, at: 0)
      solutions = Array(solutions.prefix(5))
    }
    // Retrieve visual dependencies named in the served solution bodies. The
    // references may also describe exclusions: this is recall, never adoption.
    // Only exact active project snapshots contribute trusted dependency names;
    // arbitrary custom prose does not grant a candidate a visual role.
    let visualDocuments = documents.map(\.method).filter { roles($0).contains("visual") }
    // An eligible project visual may name the solution that underlies it.
    // Fill only vacant slots, using explicit links in exact active snapshots;
    // arbitrary custom prose and untrusted edited project copies grant no link.
    let recalledVisuals = ranked.map(\.0).filter { roles($0).contains("visual") }.prefix(2)
    let projectMethods = documents.map(\.method).filter {
      roles($0).contains("solution") && skills?.discoveryMetadata(for: $0) != nil
    }
    for visual in recalledVisuals where skills?.discoveryMetadata(for: visual) != nil {
      let references = projectMethods.compactMap { method -> (MathTeachingMethod, String.Index)? in
        guard let range = visual.instructions.range(of: "[[\(method.title)]]") else { return nil }
        return (method, range.lowerBound)
      }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }
      for (method, _) in references where solutions.count < 5 && !solutions.contains(where: { $0.id == method.id }) {
        solutions.append(method)
      }
    }
    let projectSolutions = solutions.filter { skills?.discoveryMetadata(for: $0) != nil }
    let dependencies = projectSolutions.map { solution in
      let references = visualDocuments.filter { visual in
        if solution.instructions.contains("[[\(visual.title)]]") { return true }
        // A named visual heading/introduction is also an explicit dependency.
        // Do not infer one from incidental body text such as “表格比面积图合适”.
        return solution.instructions.components(separatedBy: .newlines).contains { line in
          let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
          guard line.hasPrefix(visual.title) else { return false }
          let suffix = line.dropFirst(visual.title.count)
          return !["不适用", "不支持", "不能", "不是", "无需"].contains(where: suffix.hasPrefix)
        }
      }
        .sorted { left, right in
          let a = solution.instructions.range(of: "[[\(left.title)]]")
          let b = solution.instructions.range(of: "[[\(right.title)]]")
          if let a, let b { return a.lowerBound < b.lowerBound }
          if (a != nil) != (b != nil) { return a != nil }
          return solution.instructions.range(of: left.title)!.lowerBound
            < solution.instructions.range(of: right.title)!.lowerBound
        }
      return references
    }
    // Round-robin preserves dependencies of a lower-ranked plausible solution
    // instead of filling both visual slots from the first lexical candidate.
    var linked: [MathTeachingMethod] = []
    for offset in 0..<(dependencies.map(\.count).max() ?? 0) {
      for references in dependencies where offset < references.count {
        let visual = references[offset]
        if !linked.contains(where: { $0.id == visual.id }) { linked.append(visual) }
      }
    }
    let lexical = ranked.map(\.0).filter { roles($0).contains("visual") }
    for visual in lexical where !linked.contains(where: { $0.id == visual.id }) { linked.append(visual) }
    return solutions + Array(linked.prefix(2))
  }

  private struct Document {
    let method: MathTeachingMethod
    let title: Set<String>
    let category: Set<String>
    let discovery: Set<String>
    let body: Set<String>
    var all: Set<String> { title.union(category).union(discovery).union(body) }
  }

  /// Structural recall is attached to a method's title, never to examples or
  /// exclusions in its body. It only offers the original eligible snapshot;
  /// the solver still checks applicability and may return no method.
  private static func titleConcepts(_ title: String) -> Set<String> {
    var result: Set<String> = []
    if title == "幻方与拉丁格约束" { result.insert("relation:incomplete-higher-magic") }
    if title == "多属性位置与定向相邻推理" { result.insert("relation:ordered-multi-attribute") }
    if title == "面对面座位的左右与身份推理" { result.insert("relation:facing-seat-identities") }
    if title == "对手人数与地区身份推理" { result.insert("relation:opponent-identity") }
    if title == "周循环接待与连续窗口" { result.insert("relation:weekly-reception") }
    if title == "多人语言集合与直接交谈" { result.insert("relation:language-intersections") }
    if title == "报数后选位的数位对抗" { result.insert("relation:reported-digit-game") }
    if title == "可拒乘电梯的单停层总成本" { result.insert("relation:optional-elevator-stop") }
    if title == "整除约束的七数混合极值" { result.insert("relation:divisible-mixed-digit-extrema") }
    if title.contains("约束数位极值") { result.insert("relation:constrained-digit-extrema") }
    if title.contains("删位配额") && title.contains("子序列") { result.insert("relation:digit-subsequence") }
    if title.contains("整数平均递推") && title.contains("差的整除") { result.insert("relation:integer-average-shift") }
    if title.contains("多轮一一对应") && title.contains("跨轮约束") { result.insert("relation:multi-round-bijection") }
    if title.contains("连续数码分段") && title.contains("定位") { result.insert("relation:digit-block-count") }
    if title.contains("课表容量") && title.contains("同时间冲突") { result.insert("relation:timetable-capacity") }
    if title.contains("可达金额去重") { result.insert("relation:reachable-amounts") }
    if title.contains("圆环唯一相邻对") { result.insert("relation:unique-circle-pair") }
    if title.contains("数位对称求和") { result.insert("relation:digit-position-sum") }
    if title.contains("固定和乘积最大") && title.contains("互异约束") { result.insert("relation:fixed-sum-product") }
    if title.contains("共同钟点") && title.contains("相对路程") { result.insert("relation:shared-clock-motion") }
    if title.contains("真假数量") && title.contains("星期循环") { result.insert("relation:truth-count-cycle") }
    if title.contains("共同地点") && title.contains("同程多事件") { result.insert("relation:shared-route-events") }
    if title.contains("行程事件线") { result.formUnion(["relation:train-event-reconciliation", "relation:multi-person-motion", "relation:trip-segment-switch", "relation:separation-event", "relation:chase-finite-destination"]) }
    if title == "和倍问题" { result.insert("relation:chase-finite-destination") }
    if title.contains("火车车长") && title.contains("多事件对齐") { result.insert("relation:train-event-reconciliation") }
    if title.contains("数值差之和") && title.contains("中位数") { result.insert("relation:median-difference-sum") }
    if title.contains("共享端点") && title.contains("离散间隔") { result.insert("relation:shared-vertex-flags") }
    if title.contains("分组得分") && title.contains("正误差额") { result.insert("relation:grouped-score-balance") }
    if title.contains("共同部分抵消") && title.contains("整组比较") { result.insert("relation:common-comparison") }
    if title.contains("首期差额") && title.contains("追平") { result.insert("relation:first-period-catchup") }
    if title.contains("原倍数基准") && title.contains("消耗偏移") { result.insert("relation:stock-baseline") }
    if title.contains("加权类别容量") && title.contains("恰好达到") { result.insert("relation:weighted-class-capacity") }
    if title.contains("一一匹配") && title.contains("对抗下界") { result.insert("relation:adaptive-bijection") }
    if title.contains("环形覆盖") && title.contains("窗口容量") { result.insert("relation:circular-capacity") }
    if title.contains("有限库存") && title.contains("阈值保证") { result.insert("relation:inventory-thresholds") }
    if title.contains("中心对称") && title.contains("一刀等积") { result.insert("relation:central-area-cut") }
    if title.contains("同大矩形") && title.contains("横竖拼接") { result.insert("relation:congruent-rectangle-spans") }
    if title.contains("正方形角部") && title.contains("面积差") { result.insert("relation:square-corner-area-difference") }
    if title.contains("嵌套细分") && title.contains("正方形") { result.insert("relation:square-size-inventory") }
    if title == "几何剪拼与对称构造" {
      result.formUnion(["relation:hexagon-congruent-partition", "relation:rigid-reassembly-area", "relation:cross-congruent-reassembly"])
    }
    if title.contains("阶梯剪拼") { result.insert("relation:rectangle-staircase-reassembly") }
    if title.contains("同大正方形") && title.contains("合拼") { result.insert("relation:equal-square-reassembly") }
    if title.contains("循环中点连线") { result.insert("relation:square-midpoint-cycle") }
    if title.contains("正十二边形") || title.contains("正12边形") {
      result.insert("relation:regular-dodecagon")
    }
    if title.contains("底高") && title.contains("等积") { result.insert("relation:base-height-area") }
    if title.contains("极值") && title.contains("构造") { result.formUnion(["relation:area-extremum", "relation:perimeter-extremum"]) }
    if (title.contains("横式") && title.contains("填数"))
      || (title.contains("竖式") && title.contains("数位")) {
      result.insert("relation:digit-constraints")
    }
    if title.contains("运算律") || title.contains("新运算") { result.insert("relation:defined-arithmetic") }
    if title.contains("数列") || title.contains("数表") { result.insert("relation:sequence") }
    if title.contains("最短变换") || title.contains("逆向枚举") { result.insert("relation:state-transformation") }
    if title.contains("轮换倍数") { result.insert("relation:digit-rearrangement") }
    if title.contains("位置权重") { result.insert("relation:digit-weights") }
    if title.contains("长除法") { result.insert("relation:long-division") }
    if title.contains("重复对象") || title.contains("无名分组") {
      result.insert("relation:multiset-counting")
    }
    if title.contains("邻接染色") { result.insert("relation:graph-colouring") }
    if title.contains("转移状态") { result.insert("relation:transfer-state") }
    if title.contains("有向网络") { result.insert("relation:directed-path") }
    if title.contains("连续数码") { result.insert("relation:digit-stream") }
    if title.contains("整数采购") { result.insert("relation:pack-purchase") }
    if title.contains("运输优化") { result.insert("relation:transport-cost") }
    if title.contains("并行设备") { result.insert("relation:parallel-load") }
    if title == "双机统筹与总等待最小化" { result.insert("relation:two-machine-waiting") }
    if title.contains("共享资源") { result.insert("relation:resource-precedence") }
    if title.contains("带权最短路") { result.insert("relation:weighted-route") }
    if title.contains("简单路径") { result.insert("relation:simple-path") }
    if title.contains("递推周期") { result.insert("relation:recursive-sequence") }
    if title.contains("取整除法") { result.insert("relation:ceil-division") }
    if title.contains("已知组和") { result.insert("relation:known-group-sums") }
    if title.contains("相邻差限制") { result.insert("relation:graph-difference") }
    if title.contains("分类与分步计数") { result.insert("relation:case-counting") }
    if title.contains("排列组合与限制计数") { result.insert("relation:board-placement") }
    if title.contains("计数") || title.contains("排列") { result.insert("relation:finite-counting") }
    if title.contains("真假") || title.contains("逻辑") || title.contains("对应关系") {
      result.insert("relation:logic")
    }
    if title.contains("抽屉") { result.insert("relation:guarantee") }
    if title.contains("还原") || title.contains("逆运算") || title.contains("倒推") {
      result.insert("relation:reverse-sequence")
    }
    if title.contains("统筹") || title.contains("调度") {
      result.insert("relation:scheduling")
    }
    if title.contains("博弈") || title.contains("必胜") { result.insert("relation:game") }
    if title.contains("长数字") || title.contains("重复数块") { result.insert("relation:repeated-block") }
    if title.contains("排列") || title.contains("分步计数") {
      result.insert("relation:arrangement")
    }
    return result
  }

  private static func problemConcepts(_ text: String) -> Set<String> {
    // OCR may wrap a phrase in the middle of a word. This normalization supplies
    // retrieval evidence only; it never rewrites the original question/source.
    let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    func matches(_ pattern: String) -> Bool {
      compact.range(of: pattern, options: .regularExpression) != nil
    }
    var result: Set<String> = []
    if matches(#"十字"#) && matches(#"拼|拼接"#) && matches(#"正方形"#)
      && matches(#"全等|形状和大小都相同|大小形状相同|大小、形状相同"#) {
      result.insert("relation:cross-congruent-reassembly")
    }
    if matches(#"拼|剪|割"#) && matches(#"面积"#)
      && matches(#"旋转|平移|翻转"#) && matches(#"改变|不变|保持"#) {
      result.insert("relation:rigid-reassembly-area")
    }
    if (text.contains("正六边形") || text.contains("正6边形"))
      && (text.contains("五边形") || text.contains("四边形"))
      && (text.contains("分成") || text.contains("分割"))
      && (text.contains("全等") || text.contains("形状") && text.contains("相同")) {
      result.insert("relation:hexagon-congruent-partition")
    }
    if matches(#"(?:四|五|六|七|八|九)阶幻方|[4-9][×xX*][4-9].{0,12}幻方"#)
      && matches(#"完成|补|已知|未知|幻和|星|符号"#) {
      result.insert("relation:incomplete-higher-magic")
    }
    if ["长方形", "矩形"].contains(where: compact.contains)
      && matches(#"全等|同样大小|大小(?:和|与)?形状(?:完全)?相同|同大(?:的)?(?:小)?(?:长方形|矩形)|一样大"#)
      && matches(#"拼|横放|竖放|横竖|共宽|共高"#) {
      result.insert("relation:congruent-rectangle-spans")
    }
    if matches(#"孔|空洞|挖|中心对称"#) && matches(#"中心|一刀|直线|线段"#)
      && matches(#"面积相等|等面积|平分.{0,8}面积|面积.{0,8}平分|等积"#) {
      result.insert("relation:central-area-cut")
    }
    if matches(#"保证|最少|至少"#) && matches(#"取|抽|摸"#)
      && matches(#"筷|袜|奖券|球"#) && matches(#"颜色|同色|黑|白|红|绿|数字|写[0-9０-９]"#) {
      result.insert("relation:inventory-thresholds")
    }
    if matches(#"圆圈|圆桌|圆周|环形|围成.{0,4}圈"#)
      && matches(#"相邻|连在一起|连续|之间|间隔"#)
      && matches(#"最多|最少|至少|至多|不超过|必须|总能"#) {
      result.insert("relation:circular-capacity")
    }
    if matches(#"分给|分得|分配|每(?:只|个|人|位|对象).{0,12}(?:取|得|拿)"#)
      && matches(#"至少|最少|保证|必"#) && matches(#"一样多|同样多|所得相同|同数|同一数量"#) {
      result.insert("relation:weighted-class-capacity")
    }
    if matches(#"钥匙|键锁|配对探测"#) && matches(#"锁|匹配"#) && matches(#"试验|试|探测"#) {
      result.insert("relation:adaptive-bijection")
    }
    if matches(#"删除|划去|划掉|删去"#) && matches(#"数字|数码"#)
      && matches(#"剩余|剩下|留下"#) && matches(#"最大|最小"#) {
      result.insert("relation:digit-subsequence")
    }
    if matches(#"数字|数码|数位|位数"#) && matches(#"最大|最小|最接近"#)
      && (matches(#"各用一次|分别填入|互不相同|不同数字|相同数码"#)) {
      result.insert("relation:constrained-digit-extrema")
    }
    if matches(#"擦掉|擦去|删除"#) && matches(#"平均数|平均"#)
      && matches(#"整数"#) && matches(#"首数|第一个|第1个"#) {
      result.insert("relation:integer-average-shift")
    }
    if matches(#"交换|换书|对手|比赛"#) && matches(#"每人|每位|每名"#)
      && matches(#"轮|天|第一本|第二本|第四本"#) && matches(#"不同|各|分别"#) {
      result.insert("relation:multi-round-bijection")
    }
    if matches(#"页码|编号|数字|数码|写出"#) && matches(#"连续|依次|不超过|从1|共用"#)
      && matches(#"位|次数|出现|末页"#) { result.insert("relation:digit-block-count") }
    if matches(#"课表|课程表"#) && matches(#"老师|教师"#)
      && matches(#"同时|时段|周一|周二"#) && matches(#"每人|各教|每位"#) {
      result.insert("relation:timetable-capacity")
    }
    if matches(#"元|面额|票额"#) && matches(#"不同|多少"#) && matches(#"金额|总额|组成"#) { result.insert("relation:reachable-amounts") }
    if matches(#"圆圈|一圈|围成.{0,4}圈"#) && matches(#"相邻"#) && matches(#"恰有|恰好|只有"#) { result.insert("relation:unique-circle-pair") }
    if matches(#"三位数|四位数|位数"#) && matches(#"不重复|没有重复|互不相同"#) && matches(#"总和|这些数的和|数的和"#) { result.insert("relation:digit-position-sum") }
    if matches(#"自然数|整数|数"#) && matches(#"和是|之和|总和"#)
      && matches(#"乘积|积最大|积的最大"#) && matches(#"最大|最多"#) { result.insert("relation:fixed-sum-product") }
    if matches(#"相遇|追上|追及"#) && matches(#"速度|速|千米"#)
      && matches(#"钟点|时刻|点分别|早发|等距车站|站点|提前|追点"#) {
      result.insert("relation:shared-clock-motion")
    }
    if (matches(#"真话|说真|说谎"#) && matches(#"恰一句|只有一句|昨天|星期"#)) { result.insert("relation:truth-count-cycle") }
    if (matches(#"另一方案|另一种|若甲|如果甲"#) && matches(#"相遇|追上"#) && matches(#"同一点|C地|C点|在C|共同"#))
      || (matches(#"同一全程|同一路程|同地同刻"#) && matches(#"相遇|遇人"#) && matches(#"快车|中车|慢车"#)) {
      result.insert("relation:shared-route-events")
    }
    if (matches(#"折返|往返"#) && matches(#"相遇|相向"#))
      || (matches(#"换车|给甲车|给乙车|交车"#) && matches(#"相遇|出发"#))
      || (matches(#"中点"#) && matches(#"甲|乙|丙"#) && matches(#"千米|速度"#)) {
      result.insert("relation:multi-person-motion")
    }
    if matches(#"步行|走路|走了"#) && matches(#"跑步|跑了"#)
      && matches(#"平时|原来|通常"#) && matches(#"分钟|小时"#)
      && matches(#"早到|晚到|提前|比平时"#) {
      result.insert("relation:trip-segment-switch")
    }
    if matches(#"相向|相对|同向"#) && matches(#"相距|间距"#)
      && matches(#"第一次|第二次|再次"#) && matches(#"速度|每小时|每分钟"#) {
      result.insert("relation:separation-event")
    }
    if matches(#"追上|追及|追赶|追兔|猎狗追"#)
      && matches(#"洞|终点|目的地|安全区"#) && matches(#"倍"#) {
      result.insert("relation:chase-finite-destination")
    }
    if matches(#"火车|列车|货车|客车"#) && matches(#"追|相遇|遇到|超过|错开"#)
      && matches(#"秒|分钟"#) && matches(#"行人|骑车|工人|学生|三列|三车|行走|向前走|车内"#) {
      result.insert("relation:train-event-reconciliation")
    }
    if matches(#"差|大减小|距离"#) && matches(#"相加|之和|差数和|差的和"#)
      && matches(#"最小|最少"#) && matches(#"每条|分别|各个|多个"#) {
      result.insert("relation:median-difference-sum")
    }
    if matches(#"红旗|黄旗"#) && matches(#"顶点|每条边|各边"#)
      && matches(#"相邻|之间|间隔|红旗间"#) { result.insert("relation:shared-vertex-flags") }
    if matches(#"得分|分数|满分"#) && matches(#"做对|正确|对题"#)
      && matches(#"做错|错误|错题"#) && matches(#"每题|每道|每一题"#) {
      result.insert("relation:grouped-score-balance")
    }
    let samePricedParts = matches(#"桌|椅|工作服|工资|基础费|服务费"#)
      && matches(#"价|元|报酬|钱"#) && matches(#"同|一样|相同|一套"#)
    let overlappingGroups = matches(#"不算|不包括|除(?:了|去)"#) && matches(#"班|人"#)
      && matches(#"其余|总人数|总数"#) && matches(#"少|多|差"#)
    let instalments = matches(#"第一个月|首月|前一半|后一半"#) && matches(#"付|分期"#)
    let baggageAllowance = matches(#"行李|免费"#) && matches(#"千克|公斤|重量"#) && matches(#"费|元"#)
    // Two purchase statements may describe different-sized bundles of the
    // same products. This is a recall hint only; prices and the transferable
    // amounts still need to be checked against the original question.
    let comparableBundles = matches(#"电影票|门票"#) && matches(#"汉堡|饮料"#)
      && matches(#"买|购买"#) && matches(#"给|剩|相同|一样"#)
    if samePricedParts || overlappingGroups || instalments || baggageAllowance || comparableBundles {
      result.insert("relation:common-comparison")
    }
    if matches(#"第一天|首日|首天|当天"#) && matches(#"每天|接着|往后|以后"#)
      && matches(#"同一天|同时|追平|同天"#) { result.insert("relation:first-period-catchup") }
    if compact.contains("倍") && matches(#"每天|每周|每袋|每件|每期"#)
      && matches(#"剩|用完|卖完|销售完|售完|装完|加工|吃"#) { result.insert("relation:stock-baseline") }
    // A rectangle's shaded region may contain triangles visible only in the image.
    // Keep this broad recall signal below explicit grid evidence and length stories.
    let gridGeometry = ["网格", "格点", "方格"].contains(where: compact.contains)
    let rectangleRegion = ["长方形", "矩形"].contains(where: compact.contains)
      && ["阴影", "内部", "部分"].contains(where: compact.contains) && !gridGeometry
    let squareDiagonal = compact.contains("正方形") && compact.contains("对角线") && !gridGeometry
    if compact.contains("面积")
      && (["三角", "平行四边形", "梯形", "四边形", "多边形"].contains(where: compact.contains)
        || rectangleRegion || squareDiagonal) {
      result.insert("relation:base-height-area")
    }
    if matches(#"(?:最大|最小)(?:可能|非零|非0|的)?面积|面积(?:尽可能|尽量|的)?(?:最大|最小)"#) {
      result.insert("relation:area-extremum")
    }
    if matches(#"正(?:十二|12|１２)边形"#) { result.insert("relation:regular-dodecagon") }
    if compact.contains("正方形")
      && matches(#"顶点.{0,12}(?:对(?:应|面)?边|非相邻边).{0,6}中点|(?:对(?:应|面)?边|非相邻边).{0,6}中点.{0,12}顶点"#) {
      result.insert("relation:square-midpoint-cycle")
    }
    if compact.contains("正方形") && matches(#"(?:两|2|二)(?:个|张)"#)
      && (compact.contains("剪") || compact.contains("拼")) {
      result.insert("relation:equal-square-reassembly")
    }
    if (compact.contains("长方形") || compact.contains("矩形"))
      && matches(#"剪|切|分(?:割|成)"#) && compact.contains("拼") {
      result.insert("relation:rectangle-staircase-reassembly")
    }
    if compact.contains("正方形") && compact.contains("面积") {
      let cyclicExtension = matches(#"每(?:条)?边.{0,8}延长|各边.{0,8}延长|循环.{0,8}延(?:边|长)"#)
      let nestedSideProgression = compact.contains("等差") && compact.contains("边长")
      let threeSquareDifferences = matches(#"(?:三|3)(?:个|层).{0,15}正方形"#)
        && compact.contains("周长") && matches(#"差|大|长|多"#)
      let equalOffsetBands = matches(#"红|中央|中心"#) && matches(#"绿|外侧|四个三角形|4块.{0,4}三角形"#)
        && matches(#"[=＝]|等距|距离.{0,6}(?:相等|相同)|端点.{0,6}相等"#)
      if cyclicExtension || nestedSideProgression || threeSquareDifferences || equalOffsetBands {
        result.insert("relation:square-corner-area-difference")
      }
    }
    if compact.contains("正方形") && compact.contains("小正方形")
      && matches(#"分成|分为|分割|划分|切分"#) {
      result.insert("relation:square-size-inventory")
    }
    if compact.contains("周长") && matches(#"最大|最小|至多|至少"#) {
      result.insert("relation:perimeter-extremum")
    }
    let digitDomain = (matches(#"(?:各|每个数字).{0,6}(?:一次|1次)|各用一次|只能用一次|只填一次"#)
      || (matches(#"填|组合|共用|使用|选"#)
        && matches(#"[0-9一二三四五六七八九十].{0,6}(?:至|到|～|~|—|－|-|、).{0,6}[0-9一二三四五六七八九十]"#)))
      && matches(#"[□○]|空格|方框"#)
    let namedDigits = matches(#"同字同数|异字异数|字母互异|不同的?数字|异数|共用字|(?:相同|不同)的?(?:字母|汉字).{0,12}(?:相同|不同)的?数字"#)
    if (digitDomain || namedDigits) && matches(#"[=＝]"#)
      && matches(#"[+＋−\-×÷*/]"#) {
      result.insert("relation:digit-constraints")
    }
    if matches(#"填"#) && matches(#"圆|圈|区域|三角形|射线"#)
      && matches(#"(?:各|每|所有).{0,35}和.{0,4}(?:相等|相同|等于)"#) {
      // Semantic discovery words improve recall without narrowing other method families.
      result.formUnion(["交叠", "成员", "等和", "布数"])
    }
    if matches(#"圆|圈|节点"#) && matches(#"相邻|相连|连结|连接|线段"#)
      && matches(#"之差|数差|差不|差都|边差"#) {
      result.insert("relation:graph-difference")
    }
    if matches(#"向上取整.{0,12}除|除.{0,12}向上取整"#)
      || (matches(#"每次|每轮|操作"#) && matches(#"(?:补|加).{0,35}倍数"#)
        && matches(#"十分之[一九]|取.{0,8}一份|留.{0,8}一份"#)) {
      result.insert("relation:ceil-division")
    }
    if (matches(#"环"#) && matches(#"相邻.{0,12}(?:之和|数和|和)"#))
      || (matches(#"射线|三条直线"#) && matches(#"和.{0,12}(?:分别|依次|恰好)|(?:分别|依次).{0,12}和"#)) {
      result.insert("relation:known-group-sums")
    }
    if matches(#"连写|连成一串|拼接|连续写成"#)
      && matches(#"数码|第.{0,10}(?:位|个数字)"#) {
      result.insert("relation:digit-stream")
    }
    if matches(#"(?:不能|不得|不许|禁止|不).{0,4}重复.{0,12}(?:顶点|节点|一点|任何点)|每(?:个)?(?:顶点|节点|点).{0,8}(?:最多|至多).{0,8}一次"#)
      && matches(#"路线|走法|路径|线段|走到|爬"#) {
      result.insert("relation:simple-path")
    }
    if matches(#"包|袋"#) && matches(#"不.{0,3}(?:拆|打开)|整(?:包|袋)|(?:包|袋).{0,6}(?:出售|售价)"#)
      && matches(#"最少|最低|便宜|最省|花多少|多少钱"#) {
      result.insert("relation:pack-purchase")
    }
    if matches(#"运费|运输成本|运输费用"#)
      && matches(#"仓库|调运|调配|分配|供应|需求"#) {
      result.insert("relation:transport-cost")
    }
    if matches(#"(?:两|三|四|五|六|七|八|九|十|[2-9])(?:台|个).{0,6}(?:车床|机器|设备|水龙头)|多台(?:机器|设备|车床)"#)
      && matches(#"最少|最短|最早|全部|分工|完成|用完"#) {
      result.insert("relation:parallel-load")
    }
    if matches(#"工序|步骤|烧水|煮饭"#) && matches(#"同时|最少|最短|完成"#)
      && matches(#"灶|电饭锅|炉|同一(?:台|个)|一个人|一人|水壶"#) {
      result.insert("relation:resource-precedence")
    }
    if matches(#"路线|道路|公路|路网|格线|乡镇|贪吃蛇|★|星"#)
      && matches(#"最短|最少|最快"#) && matches(#"分钟|距离|走|经过|从|爬|时间|厘米"#) {
      result.insert("relation:weighted-route")
    }
    let countingRequest = matches(#"多少|几种|选法|放法|染法|方法"#)
    let optionalChoices = matches(#"可点可不点|可选可不选|(?:可选|可点).{0,8}(?:可不选|可不点)"#)
    let overlappingRoles = matches(#"兼任|兼会|既能.{0,20}也能|两种.{0,10}都能"#)
      && matches(#"选|挑|派"#)
    let symmetricColours = matches(#"染色|涂色"#) && matches(#"对称"#)
    if countingRequest && (optionalChoices || overlappingRoles || symmetricColours) {
      result.insert("relation:case-counting")
    }
    if countingRequest && matches(#"棋子"#) && matches(#"每行|每列"#)
      && matches(#"放|摆"#) {
      result.insert("relation:board-placement")
    }
    if matches(#"数列|每项|后项|下一项"#)
      && matches(#"(?:前项|前一项|前两项|前面两个数).{0,30}(?:个位|倍|和)|(?:个位|倍).{0,15}(?:前项|前一项)"#) {
      result.insert("relation:recursive-sequence")
    }
    if matches(#"(?:依次|轮流|每次).{0,35}(?:给|分给|转给)|(?:给|分给).{0,25}(?:翻倍|一半|另两人)"#)
      && matches(#"甲|乙|丙|多的人|少的人|少者|三人|两人"#) {
      result.insert("relation:transfer-state")
    }
    if matches(#"(?:箭头|有向).{0,30}(?:走|路径|路线)|(?:路线|路径).{0,30}(?:箭头|有向)|皇后.{0,50}(?:向右|向上|右上)"#)
      && matches(#"多少|几条|几种|计数"#) {
      result.insert("relation:directed-path")
    }
    if matches(#"相邻|接触|靠在一起|相接"#)
      && matches(#"染|涂|颜色|[红黄蓝绿紫黑白]色|(?:三|四|五|[2-9])色|圆片|纸片"#) {
      result.insert("relation:graph-colouring")
    }
    let repeatedInventory = matches(#"个[0-9].{0,30}个[0-9]"#)
      && matches(#"组成|排列|排成|取出|挑选"#)
    let hiddenBagOrigins = matches(#"袋"#) && matches(#"取|摸|抽"#)
      && matches(#"号码|编号"#) && matches(#"组成|可能|不区分"#)
    if repeatedInventory || hiddenBagOrigins || matches(#"(?:无名|无标号).{0,8}(?:组|分组)"#) {
      result.insert("relation:multiset-counting")
    }
    if matches(#"(?:逆序|反序|倒序|顺序颠倒).{0,12}数|(?:数|数字).{0,12}(?:逆序|反序|顺序颠倒)|(?:末位|个位).{0,16}移.{0,8}(?:首位|最高位)"#) {
      result.insert("relation:digit-rearrangement")
    }
    if matches(#"位置权重|(?:字母|汉字).{0,60}(?:和|总和).{0,20}最[大小]"#)
      || (matches(#"[A-Z]{2,}[^。！？]{0,10}[+＋][^。！？]{0,10}[A-Z]{2,}"#) && matches(#"和.{0,12}最[大小]"#)) {
      result.insert("relation:digit-weights")
    }
    if matches(#"长除法|(?:除法|被除数).{0,80}(?:商|余数|竖式|除数)"#) {
      result.insert("relation:long-division")
    }
    if matches(#"(?:最少|至少|最短).{0,12}(?:次操作|次变换|步操作|步骤)"#)
      && matches(#"数字|自然数|个位|数位|删去|划掉"#) {
      result.insert("relation:state-transformation")
    }
    let repeatedDigitCount = matches(#"[0-9一二三四五六七八九十百千]+个[0-9]"#)
      && matches(#"乘|除|减|加|平方|求和|数位和|数字.{0,3}和|[+＋−\-×÷]"#)
    let literalRepeatedBlock = matches(#"([0-9])\1{3,}|([0-9]{2,6})\2{2,}"#)
      && matches(#"[+＋−\-×÷*]"#)
    if repeatedDigitCount || literalRepeatedBlock { result.insert("relation:repeated-block") }
    let explicitArithmeticExpression = matches(#"(?:计算|算式)[^。！？]{0,20}[0-9][^。！？]{0,20}[+＋−\-×÷]"#)
    if matches(#"新运算|运算律|简便计算|巧算|凑整|平方差公式|乘法口诀表|乘积表"#)
      || explicitArithmeticExpression
      || (matches(#"(?:规定|定义).{0,25}(?:表示|记作)"#)
        && matches(#"相加|相乘|加上|减去|乘以|除以|[★☆△▲◇⊙⊕]"#)) {
      result.insert("relation:defined-arithmetic")
    }
    if matches(#"数列|数表|相邻项|(?:第.{0,8}项).{0,20}(?:规则|规律)|(?:规则|规律).{0,20}(?:第.{0,8}项)"#) {
      result.insert("relation:sequence")
    }
    if matches(#"几种|多少种|不同.{0,5}(?:排法|选法|方案|组合)"#)
      && matches(#"线路|路线|选法|方案|搭配|组合|分步|分类|排成|站成|顺序|位置|排列"#) {
      result.insert("relation:finite-counting")
    }
    if matches(#"(?:话|说|陈述|推理|对应).{0,35}(?:真|假)|(?:真|假).{0,15}(?:话|陈述)"#) {
      result.insert("relation:logic")
    }
    if matches(#"博弈|必胜|先手|后手|对手|轮流|拿最后|输赢|谁赢|谁输"#) {
      result.insert("relation:game")
    }
    // Guarantee statements are distinct from ordinary equal sharing and from
    // an optimisation asking merely for a possible smallest/largest value.
    if matches(#"(?:一定|必有|必定|保证|总有|无论|不管)[\s\S]{0,45}(?:至少|不少于|不低于|同色|相同|一样|分到|拿到|得到)"#) {
      result.insert("relation:guarantee")
    }
    let initialUnknown = matches(#"(?:原来|原先|最初|起初|开始时|原有)[\s\S]{0,15}(?:几|多少)|(?:求|问)[\s\S]{0,10}(?:原来|原先|最初|起初)"#)
    let operation = matches(#"乘|除|倍|减|加|喝|送|用掉|取走|花掉"#)
    let sequence = matches(#"先[\s\S]{0,35}再|每(?:次|过|经过)|连续|最后|最终|恰好|正好喝完|刚好喝完"#)
    if initialUnknown && operation && sequence {
      result.insert("relation:reverse-sequence")
    }
    let waiting = matches(#"等待|等候|排队|理发|水龙头|接水|服务|加工|任务"#)
    let objective = matches(
      #"(?:时间|用时|所花时间)[\s\S]{0,12}(?:总和|最短|最少)|(?:总|全部|大家)[\s\S]{0,8}(?:等待|等候)|(?:怎样|如何)[\s\S]{0,10}(?:安排|顺序)"#
    )
    if waiting && objective { result.insert("relation:scheduling") }
    if matches(#"(?:两|二|2)台[\s\S]{0,12}(?:机器|设备|机床)|双机"#)
      && matches(#"(?:等待|等候)[\s\S]{0,12}(?:总|之和)|(?:总|全部|大家)[\s\S]{0,8}(?:等待|等候)"#)
    {
      result.insert("relation:two-machine-waiting")
    }
    if matches(#"语言|汉语|英语|法语|日语"#)
      && matches(#"直接交谈|共同语言|不能交谈"#)
      && matches(#"每人|各会|种语言|人都会|人共有"#)
      && !matches(#"经.{0,4}翻译|通过.{0,4}翻译|不研究直接交谈"#)
    { result.insert("relation:language-intersections") }
    if matches(#"接待|办公"#) && matches(#"星期|周[一二三四五六日天]"#)
      && matches(#"前天|明天|后天"#) && matches(#"(?:连续|连着).{0,6}天"#)
      && !matches(#"(?:连续|连着).{0,6}工作日"#)
    { result.insert("relation:weekly-reception") }
    if matches(#"从左到右|左至右|最左|最右|中间"#)
      && matches(#"紧挨|挨着|相邻|旁边|紧邻"#)
      && matches(#"城市|北京|天津|上海|广州|重庆"#)
      && matches(#"衬衫|颜色|穿"#) && matches(#"茶|饮品|饮料"#)
      && !matches(#"围成一圈|环形|允许.{0,4}重复|不给任何位置|没有位置关系"#)
    { result.insert("relation:ordered-multi-attribute") }
    if matches(#"两侧|两边"#) && matches(#"面对面|对面"#)
      && matches(#"每(?:边|侧).{0,5}(?:2|两|二).{0,3}(?:人|位|个)"#)
      && matches(#"左侧|右侧|左边|右边"#) && matches(#"国籍|英国|德国"#)
      && matches(#"大衣|衣色|颜色|穿"#)
      && !matches(#"圆桌|围成.{0,2}圈|每(?:边|侧).{0,5}(?:3|三)|没有左右|不给.{0,4}方向"#)
    { result.insert("relation:facing-seat-identities") }
    if matches(#"运动员|选手|对手"#) && matches(#"比赛过|交过手|交手|从未比赛"#)
      && matches(#"(?:两|三|一|二|[123])名|对手人数"#)
      && matches(#"来自|地区|省|北京|上海|广东|福建"#)
      && !matches(#"只给总比赛场次|只给胜负|不区分对手"#)
    { result.insert("relation:opponent-identity") }
    let countRequest = matches(#"多少种|几种|不同.{0,5}(?:排|方法|选法)|排列方法"#)
    if matches(#"甲|先手"#) && matches(#"乙|后手"#)
      && matches(#"每次报|报一个|报数"#) && matches(#"方框|空格|选位|填入|放入"#)
      && matches(#"最佳|最优|策略|差尽量|差最大|差最小"#)
      && !matches(#"没有甲乙|不能重复|不得重复|互异数字"#)
    { result.insert("relation:reported-digit-game") }
    if matches(#"电[梯样桶]"#) && matches(#"楼[梯样棉]"#)
      && matches(#"(?:只|仅|只能)[\s\S]{0,8}(?:一|1|某一)层|单停层"#)
      && matches(#"不满意|总成本|总分|总费用"#)
      && matches(#"最小|最少|最低"#)
      && !matches(#"必须乘|不许拒乘|不能走楼梯"#)
    { result.insert("relation:optional-elevator-stop") }
    // Empty digit boxes can swallow operators in OCR. Offer a candidate for
    // this narrow damaged-expression signature; its body still requires the
    // solver to verify all operators against the actual photo before use.
    let damagedSevenDigitExpression = matches(#"(?:7|七)个(?:不同的|互异的)?(?:自然数|数字|数码)"#)
      && matches(#"填入算式|填入.{0,8}方框"#) && matches(#"[■コ_]"#)
    if matches(#"数码|数字|自然数|填入|填数|方框|□"#)
      && matches(#"整数|整除"#) && matches(#"最大|最小|最值|极值"#)
      && matches(#"×|乘|\*"#) && !matches(#"没有乘法|不含乘法|无乘法"#)
      && ((matches(#"÷|除|/"#) && matches(#"−|－|-|减"#)) || damagedSevenDigitExpression)
      && !matches(#"[+＋]"#)
    {
      result.insert("relation:divisible-mixed-digit-extrema")
    }
    let orderedChoice = matches(#"挑出|选出|选取|选[\s\S]{0,8}人|取出|排成|站成|位置|座位|排列|顺序"#)
    if countRequest && orderedChoice { result.insert("relation:arrangement") }
    return result
  }

  /// Chinese bigrams and whole Latin words, never digits or cross-punctuation
  /// bigrams. Sets prevent repeated example text from boosting a skill.
  static func tokens(_ text: String, stripInstructionWords: Bool = false) -> Set<String> {
    var text = text.lowercased()
    for phrase in ["不要使用方程", "请使用小学生的知识领域解题", "请验算确定答案的正确性",
      "不用方程", "不要方程", "可以使用方程", "允许使用方程", "四年级", "小学", "解题", "画图"] {
      text = text.replacingOccurrences(of: phrase, with: " ")
    }
    // Retain relation meaning split by numbers (e.g. “3倍”, “共248棵”). These
    // are shared vocabulary tokens, never method IDs or applicability grants.
    var result: Set<String> = []
    if text.contains("倍") || text.range(of: #"(?:一个数|某数|原数|这个数)\s*乘(?:以)?\s*(?:\d|[一二三四五六七八九十百两])"#, options: .regularExpression) != nil {
      result.insert("relation:ratio")
    }
    // Integer trailing-zero omission is a possible ratio hint, never a source
    // fact or permission to apply a method. The answer must check the original.
    if text.range(of: #"末尾(?:少添|少写|漏写|漏添)了?(?:一|1)个(?:0|零)"#, options: .regularExpression) != nil {
      result.insert("relation:ratio")
    }
    // A written ratio is the same retrieval concept as “几倍”. Require its
    // explicit 比 wording, so a clock time such as 10:30 is not ratio evidence.
    if text.range(of: #"比(?:例)?(?:为|是)?\s*\d+(?:\.\d+)?\s*[:：∶]\s*\d+(?:\.\d+)?"#, options: .regularExpression) != nil {
      result.insert("relation:ratio")
    }
    if ["共", "总和", "总数", "总量", "总价", "合计", "之和", "的和"].contains(where: text.contains) {
      result.insert("relation:total")
    }
    if text.contains("差")
      || text.range(of: #"比[^，,。;；\n]{1,20}(?:多|少|长|短|大|小|高|低|重|轻)"#, options: .regularExpression) != nil {
      result.insert("relation:difference")
    }
    if ["倒推", "逆序", "逆运算"].contains(where: text.contains) {
      result.insert("relation:inverse")
    }
    text = text.replacingOccurrences(of: "多少", with: " ")
    let expression = try! NSRegularExpression(pattern: "[\\p{Han}]+|[a-z]+")
    let ignored: Set<String> = ["方法", "题目", "条件", "原题", "原图", "适用", "替代", "能否", "逐边", "边验", "条边", "一次", "完整", "明确", "实际", "单独", "示例", "文字", "给出", "其他", "例如", "本题", "以下", "使用", "可以", "不能", "需要", "答案", "验算", "正确", "学生", "知识", "年级", "数学", "计算", "同学", "一个", "两个", "各有", "有多", "多少", "分别", "已知", "求出", "请用", "不要", "允许", "算术", "解释", "说明", "技能", "唯一", "数值", "直接", "选择", "不足", "题意", "补题", "不做", "分类", "翻译", "英语", "这句", "拓展", "来源", "疑义", "确认", "for", "the", "and", "use", "solve", "grade", "equation", "equations", "not"]
    // Split on generic teaching words before taking Chinese bigrams. Dropping
    // only the word itself afterward leaves cross-word fragments such as
    // “值的”/“的技” from “数值的技能”, which match unrelated skill prose.
    // Latin words keep their normal whole-word boundary check below.
    for word in ignored.filter({ stripInstructionWords && $0.first?.isASCII == false }).sorted(by: {
      $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }) {
      text = text.replacingOccurrences(of: word, with: " ")
    }
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text) else { continue }
      let run = String(text[range])
      if run.first?.isASCII == true {
        if run.count >= 3, !ignored.contains(run) { result.insert(run) }
      } else {
        let characters = Array(run)
        if characters.count >= 2 {
          for index in 0..<(characters.count - 1) {
            let token = String(characters[index...index + 1])
            if !ignored.contains(token) { result.insert(token) }
          }
        }
      }
    }
    return result
  }
}
