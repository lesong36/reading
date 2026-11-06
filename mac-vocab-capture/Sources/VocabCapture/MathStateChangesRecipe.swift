import Foundation
import CoreFoundation

/// A known initial count followed by explicitly cited arrivals or departures.
/// Citations are necessary transcription checks, not certification of the photo.
enum MathStateChangesRecipe {
  static let contract = """
  state_changes适用于已知初始数量、依次发生明确增加或减少，求最后数量。精确字段为id、title、kind:"state_changes"、initial:{value,unit,evidence}、changes:[{direction:"increase"或"decrease",amount:{value,unit,evidence}}]。changes按原题顺序填写1至5次变化；只引用含该数值且明确到来/增加或离开/减少的原题句子，方向不从标题猜测。所有数值为0至十亿的整数；所有单位相同，仅支持人、本、张、个、只、棵、件、辆、头、袋、套、箱、枝、级、瓶、盒、块。不得换算单位、把计算结果写成原题量、填写答案、facts、relations或布局。程序依次加减并计算中间和最终状态。未知初始量、倒推、含糊方向或任一步出现负数时应采用一般解答。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    guard Set(entry.keys) == ["id", "title", "kind", "initial", "changes"],
      entry["kind"] as? String == "state_changes",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let changes = entry["changes"] as? [[String: Any]], (1...5).contains(changes.count) else {
      throw fail("状态变化配方仅接受已知初始数量及按顺序列出的1至5次增加或减少。")
    }
    let units: Set<String> = ["人", "本", "张", "个", "只", "棵", "件", "辆", "头", "袋", "套", "箱", "枝", "级", "瓶", "盒", "块"]
    func source(_ raw: Any?) throws -> (value: Double, unit: String, evidence: String) {
      guard let object = raw as? [String: Any], Set(object.keys) == ["value", "unit", "evidence"],
        let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        let unit = object["unit"] as? String, units.contains(unit),
        let evidence = object["evidence"] as? String, evidence.count <= 500,
        number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000,
        number.doubleValue.rounded() == number.doubleValue,
        MathOriginalQuantityPremise.original(number.doubleValue, evidence: evidence) else {
        throw fail("状态数量须为有限非负整数，具有统一的计数单位及含该数值的原题引文，不能使用计算结果。")
      }
      return (number.doubleValue, unit, evidence)
    }
    let initial = try source(entry["initial"])
    var facts: [MathDiagram.Fact] = [.init(id: "initial", label: "原来数量", value: initial.value,
      unit: initial.unit, origin: .given, evidence: initial.evidence)]
    var relations: [MathDiagram.Relation] = []
    var stateIDs = ["initial"]
    var current = initial.value
    for (index, change) in changes.enumerated() {
      guard Set(change.keys) == ["direction", "amount"], let direction = change["direction"] as? String,
        ["increase", "decrease"].contains(direction) else {
        throw fail("每次状态变化仅可指定明确增加或减少及原题数量，不接受自定义关系。")
      }
      let amount = try source(change["amount"])
      guard amount.unit == initial.unit,
        matchesDirection(direction, value: amount.value, evidence: amount.evidence) else {
        throw fail("变化单位须与初始数量一致，增加或减少方向须由所引原题明确说明。")
      }
      let next = direction == "increase" ? current + amount.value : current - amount.value
      guard next.isFinite, (0...1_000_000_000).contains(next) else {
        throw fail("状态变化的中间与最终数量必须为支持范围内的非负数量。")
      }
      let amountID = "change_\(index + 1)"
      let stateID = index == changes.count - 1 ? "final" : "state_\(index + 1)"
      facts.append(.init(id: amountID, label: "第\(index + 1)次" + (direction == "increase" ? "增加" : "减少"),
        value: amount.value, unit: initial.unit, origin: .given, evidence: amount.evidence))
      facts.append(.init(id: stateID, label: index == changes.count - 1 ? "最后数量" : "第\(index + 1)次变化后",
        value: next, unit: initial.unit, origin: .derived))
      relations.append(.init(operation: direction == "increase" ? .sum : .difference,
        inputIDs: [stateIDs.last!, amountID], outputID: stateID))
      stateIDs.append(stateID)
      current = next
    }
    let diagram = MathDiagram(id: id, title: title, kind: .state, facts: facts,
      relations: relations, factIDs: stateIDs)
    try diagram.validate()
    return diagram
  }

  private static func matchesDirection(_ direction: String, value: Double, evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.lowercased()
    // Negated, comparative and hypothetical changes do not establish a state transition.
    guard !["没有", "没", "未", "不", "如果", "假如", "可能", "将", "预计", "本来", "比", "多于", "少于", "not", "never", "if ", "would", "more than", "less than"].contains(where: text.contains) else { return false }
    let increase = ["增加", "增添", "加入", "添入", "开来", "驶来", "到来", "进来", "来了", "上车", "买来", "买进", "购入", "收到", "送来", "运来", "放入", "arrived", "arrival", "added", "received", "joined"]
    let decrease = ["减少", "离开", "开走", "驶走", "走了", "走掉", "下车", "卖出", "售出", "拿走", "取出", "用掉", "吃掉", "送出", "运走", "left", "departed", "removed", "sold"]
    let clauses = text.components(separatedBy: CharacterSet(charactersIn: "，,；;。\n"))
      .filter { MathDiagramPlan.evidenceContains(value, in: $0) }
    guard !clauses.isEmpty else { return false }
    let wanted = direction == "increase" ? increase : decrease
    let opposite = direction == "increase" ? decrease : increase
    return clauses.contains { clause in
      wanted.contains(where: clause.contains) && !opposite.contains(where: clause.contains)
    } && !clauses.contains { clause in opposite.contains(where: clause.contains) }
  }
}
