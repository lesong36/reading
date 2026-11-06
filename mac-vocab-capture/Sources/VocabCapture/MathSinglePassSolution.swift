import Foundation

/// Method use is reported by the same answer that solves the question. These
/// claims are neither a second model judgement nor a human correctness review.
enum MathSinglePassSolution {
  static let marker = "```math-methods"
  struct Result {
    let answer: String
    let method: MathTeachingMethod?
    let visualMethods: [MathTeachingMethod]
    let failure: String?
    var diagramOmissionReason: String? = nil
    var diagramSubmissionFailure: String? = nil
    var answerIncomplete = false
  }

  static func prompt(_ request: String, candidates: [MathTeachingMethod], programArithmetic: Bool = false) -> String {
    let catalogue = candidates.isEmpty ? nil : (try? MathTeachingReviewCatalogue.load())
    let bodies = candidates.map { method in
      let roles = MathMethodMatcher.singleCallRolePolicy(for: method, catalogue: catalogue).roles.joined(separator: ",")
      return "id:\(method.id)\nversion:\(method.versionID)\nroles:\(roles)\n名称：\(method.title)\n全文：\n\(method.instructions)"
    }.joined(separator: "\n\n")
    let answerStyle = programArithmetic ? """
      避免重复输出题面、计算树和验算。使用difference_ratio、two_allocations或purchase_comparison原题配方时，只写一小段解释关键数量关系（不超过120字），不重复计算；原生程序将从配方完成计算步骤、单位检查、数值与实际图解显示。仍须看原图确认配方前提，不从助手答案反推事实。
      其它题型保留正常解题步骤与必要验算，简洁但不省略关键推理。用户明确要求详解或特殊步骤时优先遵守，不为缩短输出而漏解题号、混合条件或删掉解题过程。
      """ : "先输出正常解题步骤及验算。"
    return """
      本次请求：
      \(request)

      下列为本机检索到的候选技能全文，不是已选方法，不是题目条件。直接查看原图解题，在同一次回答中独立判断是否实际采用。缺条件、不适用或没有匹配技能时正常解释思路，不强行套用名称；主方法允许null。中间含单价乘数量不证明归一归总适用；优惠比较直接按规则比较付款。只采用满足全文前提且允许角色的候选；方法例题数字不能替代原图。
      \(bodies)

      \(answerStyle)
      随后输出且仅输出一个math-methods数据块，JSON恰有method_id、visual_method_ids；主方法为实际采用的solution角色id或null，图法为实际采用的visual角色id数组（最多两个）。未采用时填null和[]；不能引用未提供的id。只声明已采用，不把候选检索或自我验算当作用户已核验。
      ```math-methods
      {"method_id":null,"visual_method_ids":[]}
      ```
      候选技能明确提供math-grid分块格图或math-center-cut中心切割格式时，可在回答正文输出完整JSON围栏，由离线显示端检查；中心切割仅为归一化示意，不是原题测量数据。不为此另外强画数量图，不把技能例题数字当原图条件。
      有助于理解或用户明确要求画图时，再在回答最后输出math-diagrams数据块；没有帮助不强行画。原题不清时说明缺失条件，不编造图解。两种数据块互相独立，不把方法数据放进图解JSON。
      """
  }

  /// Remove only the metadata fence, leaving the independent diagram payload
  /// for the existing arithmetic/provenance/rendering validator.
  static func parse(_ response: String, candidates: [MathTeachingMethod]) -> Result {
    let lines = response.components(separatedBy: "\n")
    var retained: [String] = [], blocks: [String] = [], current: [String]?
    var malformed = false
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if current != nil {
        if trimmed == "```" { blocks.append(current!.joined(separator: "\n")); current = nil }
        else { current!.append(line) }
      } else if trimmed == marker { current = [] }
      else { retained.append(line) }
    }
    if current != nil { malformed = true }
    let answer = retained.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    func rejected() -> Result { .init(answer: answer, method: nil, visualMethods: [], failure: "方法采用记录未有效返回；解答仍待用户核验。") }
    guard !malformed, blocks.count == 1, blocks[0].utf8.count <= 4096,
      let data = blocks[0].data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["method_id", "visual_method_ids"],
      object["method_id"] is NSNull || object["method_id"] is String,
      let visualIDs = object["visual_method_ids"] as? [String], visualIDs.count <= 2,
      Set(visualIDs).count == visualIDs.count
    else { return rejected() }
    let primaryID = object["method_id"] as? String
    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    if let primaryID {
      guard let method = byID[primaryID],
        MathMethodMatcher.singleCallRolePolicy(for: method).roles.contains("solution") else { return rejected() }
    }
    var visuals: [MathTeachingMethod] = []
    for id in visualIDs {
      guard id != primaryID, let method = byID[id],
        MathMethodMatcher.singleCallRolePolicy(for: method).roles.contains("visual") else { return rejected() }
      visuals.append(method)
    }
    return .init(answer: answer, method: primaryID.flatMap { byID[$0] }, visualMethods: visuals, failure: nil)
  }

  static func displayText(_ partial: String) -> String {
    let parsed = parse(partial, candidates: [])
    var text = parsed.answer
    let tail = text.components(separatedBy: "\n").last ?? ""
    let trimmed = tail.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("```") && marker.hasPrefix(trimmed) {
      text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return MathDiagramAnswer.displayText(text)
  }

  /// Only a successful, independently validated compiled diagram may receive
  /// native arithmetic text. This identifies the recipe, not its applicability.
  static func nativeRecipeIDs(in answer: String) -> Set<String> {
    guard let start = answer.range(of: MathDiagramAnswer.marker),
      let close = answer.range(of: "```", range: start.upperBound..<answer.endIndex),
      let data = answer[start.upperBound..<close.lowerBound].data(using: .utf8),
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let diagrams = envelope["diagrams"] as? [[String: Any]] else { return [] }
    return Set(diagrams.compactMap { entry in
      guard let kind = entry["kind"] as? String,
        MathStructuredSolution.nativeRecipeKinds.contains(kind) else { return nil }
      return entry["id"] as? String
    })
  }
}
