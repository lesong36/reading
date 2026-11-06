import Foundation
import CoreFoundation

/// Two inclusive memberships in a known population. Citation checks are only
/// transcription safeguards; neither original-image accuracy nor the answer is certified.
enum MathVennCountsRecipe {
  static let contract = """
  venn_counts仅适用于已知总体、两个集合各自人数及两者都参加人数的容斥问题。精确字段id、title、kind:"venn_counts"、total、left、right、intersection；四个量各为{value,unit,evidence}。total引用全班/总体总数；left和right必须包含同时属于两集合的成员，不能填仅参加一种的人数；intersection引用“两种都”“两项都”“既…又…”等明确重叠条件。只填原题整数0至十亿，单位统一为人、个、本、只、棵、辆、张。不得填计算结果、答案、facts、relations或布局；程序计算仅左、交集、仅右、并集、圈外，并核对总量。缺总体、缺交集、类别互斥、条件矛盾或集合人数仅计独有成员时使用一般解答。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    guard Set(entry.keys) == ["id", "title", "kind", "total", "left", "right", "intersection"],
      entry["kind"] as? String == "venn_counts",
      let id = entry["id"] as? String, let title = entry["title"] as? String else {
      throw fail("容斥配方须提供总体、两个包含交集的集合数量及明确交集，不接受自定义运算。")
    }
    var facts: [MathDiagram.Fact] = []
    let labels = ["total": "总体", "left": "左集合（含交集）", "right": "右集合（含交集）", "intersection": "两者都有"]
    func given(_ key: String) throws -> (Double, String) {
      guard let source = entry[key] as? [String: Any], Set(source.keys) == ["value", "unit", "evidence"],
        let number = source["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, (0...1_000_000_000).contains(number.doubleValue),
        number.doubleValue.rounded() == number.doubleValue,
        let unit = source["unit"] as? String, ["人", "个", "本", "只", "棵", "辆", "张"].contains(unit),
        let evidence = source["evidence"] as? String, evidence.count <= 500,
        MathOriginalQuantityPremise.original(number.doubleValue, evidence: evidence),
        supports(key, value: number.doubleValue, evidence: evidence) else {
        throw fail("容斥数量须为同单位非负整数，原题引文须明确总体、包含交集的成员或共同成员；不能将推算结果当已知量。")
      }
      facts.append(.init(id: key, label: labels[key]!, value: number.doubleValue, unit: unit,
        origin: .given, evidence: evidence))
      return (number.doubleValue, unit)
    }
    let total = try given("total"), left = try given("left"), right = try given("right"), both = try given("intersection")
    let union = left.0 + right.0 - both.0
    guard [left.1, right.1, both.1].allSatisfy({ $0 == total.1 }),
      both.0 <= min(left.0, right.0), union <= total.0 else {
      throw fail("容斥条件矛盾：交集不能超过任一集合，并集不能超过总体，所有计数单位必须相同。")
    }
    for (key, label, value) in [("left_only", "仅属于左集合", left.0 - both.0),
      ("right_only", "仅属于右集合", right.0 - both.0), ("union", "至少属于一种", union),
      ("outside", "两者都不属于", total.0 - union)] {
      facts.append(.init(id: key, label: label, value: value, unit: total.1, origin: .derived))
    }
    let diagram = MathDiagram(id: id, title: title, kind: .venn, facts: facts, relations: [
      .init(operation: .difference, inputIDs: ["left", "intersection"], outputID: "left_only"),
      .init(operation: .difference, inputIDs: ["right", "intersection"], outputID: "right_only"),
      .init(operation: .sum, inputIDs: ["left_only", "intersection", "right_only"], outputID: "union"),
      .init(operation: .difference, inputIDs: ["total", "union"], outputID: "outside"),
      .init(operation: .sum, inputIDs: ["union", "outside"], outputID: "total"),
    ], factIDs: ["left_only", "intersection", "right_only", "union", "outside", "total"])
    try diagram.validate()
    return diagram
  }

  private static func supports(_ key: String, value: Double, evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.lowercased()
    guard !["所以", "算得", "计算", "推算", "推得", "答案", "因此", "互斥", "互不", "不重叠", "不能同时", "不可能同时", "either", "exclusive", "calculated"].contains(where: text.contains) else { return false }
    let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,；;。\n"))
      .filter { MathDiagramPlan.evidenceContains(value, in: $0) }
    return clauses.contains { clause in
      switch key {
      case "total":
        let population = ["全班", "班里", "班上", "本班", "总体", "全体", "total", "altogether"].contains(where: clause.contains)
        let generalTotal = ["总共", "一共有", "共有"].contains(where: clause.contains)
          && !["参加", "喜欢", "属于", "集合", "member", "attend"].contains(where: clause.contains)
        return (population || generalTotal)
          && !["两种", "两项", "至少", "交集", "both", "union"].contains(where: clause.contains)
      case "intersection":
        guard !["不", "没", "未", "neither", "not"].contains(where: clause.contains) else { return false }
        return ["两种都", "两项都", "两者都", "都参加", "同时参加", "交集", "共同", "both"].contains(where: clause.contains)
          || (clause.contains("既") && clause.contains("又"))
      default:
        guard clause.range(of: #"只(?:参加|喜欢|会|读过|买过|拥有|属于|有|左|右)|仅|独有"#, options: .regularExpression) == nil,
          !["不", "没", "未", "only", "neither", "not"].contains(where: clause.contains) else { return false }
        return ["参加", "喜欢", "会", "读过", "买过", "拥有", "属于", "集合", "attend", "like", "member", "enrolled"].contains(where: clause.contains)
      }
    }
  }
}
