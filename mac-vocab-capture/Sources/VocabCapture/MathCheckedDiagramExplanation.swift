import Foundation

/// Explains the checked graph, not whether the model transcribed the photograph correctly.
/// Arithmetic and units remain those of the native graph; no method name is inferred.
enum MathCheckedDiagramExplanation {
  static func text(for diagram: MathDiagram) throws -> String {
    try diagram.validate()
    let facts = Dictionary(uniqueKeysWithValues: diagram.facts.map { ($0.id, $0) })
    func quantity(_ fact: MathDiagram.Fact) -> String {
      (fact.value.map(number) ?? "？") + (fact.unit.isEmpty ? "" : "（\(fact.unit)）")
    }
    var lines: [String] = []
    let given = diagram.facts.filter { $0.origin == .given }
    if !given.isEmpty {
      lines.append("图中已知条件：" + given.map { "\($0.label)\(quantity($0))" }.joined(separator: "；") + "。")
    }
    for fact in diagram.facts where fact.origin == .constant {
      lines.append("表示规则：\(fact.label)取\(quantity(fact))；\(fact.evidence!)")
    }
    // Graph validation proves derived quantities have grounded chains. Order the
    // explanation by those chains even when a stored relation list is shuffled.
    var available = Set(diagram.facts.filter { $0.origin != .derived }.map(\.id))
    var pending = diagram.relations
    while !pending.isEmpty {
      guard let index = pending.firstIndex(where: { $0.inputIDs.allSatisfy(available.contains) }) else {
        throw MathDiagram.ValidationError(message: "无法按已知条件排列图解计算步骤。")
      }
      let relation = pending.remove(at: index)
      let inputs = relation.inputIDs.map { facts[$0]! }, output = facts[relation.outputID]!
      let symbol: String
      switch relation.operation {
      case .sum: symbol = "＋"
      case .difference: symbol = "−"
      case .product: symbol = "×"
      case .quotient: symbol = "÷"
      case .equal: symbol = ""
      case .floorQuotient: symbol = "整除"
      case .remainder: symbol = "求余数"
      }
      let symbolic = output.value == nil || inputs.contains { $0.value == nil }
      let expression = inputs.map { symbolic ? "\($0.label)（\(quantity($0))）" : quantity($0) }.joined(separator: symbol)
      let prefix = symbolic ? "数量关系（含未知量）" : output.origin == .derived ? "计算\(output.label)" : "回算检查\(output.label)"
      lines.append("\(prefix)：\(expression)＝\(quantity(output))。")
      available.insert(output.id)
    }
    // Only the two native purchase rows with an explicit checked payment
    // difference qualify. A random pair of values is not a shopping decision.
    if diagram.kind == .table, diagram.rows.count == 2,
      diagram.rows[0].factIDs.last == "offer_1_payment", diagram.rows[1].factIDs.last == "offer_2_payment",
      let first = facts["offer_1_payment"], let second = facts["offer_2_payment"],
      let a = first.value, let b = second.value, first.unit == second.unit,
      let difference = facts["payment_difference"], difference.unit == first.unit,
      diagram.relations.contains(where: { $0.operation == .difference && $0.outputID == difference.id
        && Set($0.inputIDs) == Set([first.id, second.id]) }) {
      if a == b { lines.append("按图中两方案条件，实际支付相同，均为\(quantity(first))。") }
      else {
        let lower = a < b ? 0 : 1
        lines.append("按图中两方案条件，\(diagram.rows[lower].label)支付较少，差额为\(quantity(difference))。")
      }
    }
    if diagram.kind == .table,
      let total = facts["total_time"], let deadline = facts["deadline"],
      let a = total.value, let b = deadline.value, total.unit == deadline.unit,
      facts["distance"]?.unit == facts["return_distance"]?.unit,
      diagram.relations.contains(where: { $0.operation == .equal && $0.inputIDs == ["distance"] && $0.outputID == "return_distance" }),
      diagram.relations.contains(where: { $0.operation == .sum && $0.inputIDs == ["outward_time", "return_time"] && $0.outputID == "total_time" }),
      let difference = facts["deadline_difference"], difference.unit == total.unit,
      diagram.relations.contains(where: { $0.operation == .difference && $0.outputID == difference.id
        && Set($0.inputIDs) == Set([total.id, deadline.id]) }) {
      lines.append("按图中同路往返条件，总用时\(quantity(total))\(a <= b ? "不超过" : "超过")限时\(quantity(deadline))，\(a <= b ? "能" : "不能")在规定时间内返回。")
    }
    if diagram.facts.contains(where: { $0.origin == .unknown }) {
      lines.append("“？”仍是未知量，上述关系未确定其数值。")
    }
    lines.append("以上仅核对图中数量关系；原题条件与答案仍需用户核验。")
    return lines.joined(separator: "\n")
  }

  // Same six-decimal presentation policy as the renderer, whose formatter is
  // private. Preserve all supported places and never erase a tiny nonzero value.
  private static func number(_ value: Double) -> String {
    if value == value.rounded() { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
    var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return text == "0" || text == "-0" ? String(value) : text
  }
}
