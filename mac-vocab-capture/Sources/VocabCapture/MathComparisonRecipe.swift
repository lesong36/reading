import Foundation
import CoreFoundation

/// Original sum, ratio, and holdings are separate premises. Native operations
/// derive targets; citations check transcription consistency, not photograph truth.
enum MathComparisonRecipe {
  static let kinds: Set<String> = ["sum_difference", "sum_ratio", "equalize_transfer"]
  static let contract = """
  比较配方只填原题条件，不填计算结果、facts、relations 或布局；主方法允许为空。
  sum_difference 精确字段：{"id":"comparison","title":"和差比较","kind":"sum_difference","total":{"value":98,"unit":"本","evidence":"两人共有98本"},"difference":{"value":6,"unit":"本","evidence":"甲比乙多6本"}}。必须原题明确给出总量及差量，程序求较多量与较少量。
  sum_ratio 精确字段：{"id":"comparison","title":"和倍比较","kind":"sum_ratio","total":{"value":248,"unit":"棵","evidence":"杏树和桃树共248棵"},"multiplier":{"value":3,"unit":"","evidence":"桃树是杏树3倍"}}。必须原题明确给出总量和整数倍数2至20，不能把总量当差量。
  equalize_transfer 精确字段：{"id":"comparison","title":"移多补少","kind":"equalize_transfer","larger":{"value":38,"unit":"本","evidence":"甲有38本"},"smaller":{"value":22,"unit":"本","evidence":"乙有22本"},"equality_evidence":"甲给乙多少本使两人一样多"}。只用于两方直接转移、总量不变并要求相等；程序求平均量及移动量，不能把算得的差16或平分常数2写为原题条件。
  数字对象精确包含 value、unit、evidence；引文必须含对应原题数字（中文数字也可），不能使用答案或计算式。总量与差量或原持有量单位必须相同；倍数无单位。条件不足、多人分配、转移损耗或单位不同用一般解答，不强套。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ message: String) -> MathDiagram.ValidationError { .init(message: message) }
    func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
      guard Set(object.keys) == allowed else { throw fail("比较配方字段缺失或含有计算结果、关系或布局。") }
    }
    func source(_ raw: Any?) throws -> (value: Double, unit: String, evidence: String) {
      guard let object = raw as? [String: Any] else { throw fail("比较数量缺少原题来源。") }
      try keys(object, ["value", "unit", "evidence"])
      guard let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        let unit = object["unit"] as? String, unit.count <= 24,
        let evidence = object["evidence"] as? String, evidence.count <= 500,
        !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw fail("比较数量、单位或原题来源无效。")
      }
      let value = number.doubleValue
      guard value.isFinite, (0...1_000_000_000).contains(value),
        MathOriginalQuantityPremise.original(value, evidence: evidence) else {
        throw fail("比较数量必须非负且与原题引文数字一致，不能使用计算结果。")
      }
      return (value, unit, evidence)
    }
    guard let kind = entry["kind"] as? String, kinds.contains(kind),
      let id = entry["id"] as? String, let title = entry["title"] as? String else {
      throw fail("比较配方必须指定和差、和倍或两方移量。")
    }
    var facts: [MathDiagram.Fact] = [], relations: [MathDiagram.Relation] = []
    func given(_ id: String, _ label: String, _ source: (value: Double, unit: String, evidence: String)) {
      facts.append(.init(id: id, label: label, value: source.value, unit: source.unit, origin: .given, evidence: source.evidence))
    }
    func constant(_ id: String, _ label: String, _ value: Double, _ evidence: String) {
      facts.append(.init(id: id, label: label, value: value, origin: .constant, evidence: evidence))
    }
    func derived(_ id: String, _ label: String, _ value: Double, _ unit: String,
      _ operation: MathDiagram.Operation, _ inputs: [String]) {
      facts.append(.init(id: id, label: label, value: value, unit: unit, origin: .derived))
      relations.append(.init(operation: operation, inputIDs: inputs, outputID: id))
    }
    func sameUnit(_ first: String, _ second: String) throws {
      guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, first == second else {
        throw fail("比较的实际数量必须使用相同且非空的单位。")
      }
    }
    var diagramKind: MathDiagram.Kind, displayed: [String], parts: [Int] = []
    if kind == "equalize_transfer" {
      try keys(entry, ["id", "title", "kind", "larger", "smaller", "equality_evidence"])
      let high = try source(entry["larger"]), low = try source(entry["smaller"])
      try sameUnit(high.unit, low.unit)
      guard high.value >= low.value, let premise = entry["equality_evidence"] as? String,
        !premise.isEmpty, premise.count <= 500,
        ["给", "移", "转", "transfer", "give"].contains(where: premise.lowercased().contains),
        ["相等", "一样多", "同样多", "相同", "equal"].contains(where: premise.lowercased().contains),
        !["损耗", "丢失", "损失", "loss", "一半给", "半数给"].contains(where: premise.lowercased().contains) else {
        throw fail("移量配方需要较多方直接移给较少方并使两方相等的原题条件。")
      }
      given("larger", "较多方原有", high); given("smaller", "较少方原有", low)
      constant("two", "两方平均规则", 2, "两方数量相等且转移守恒：和与差分别平分为两份。原题要求：" + premise)
      derived("total", "两方总量", high.value + low.value, high.unit, .sum, ["larger", "smaller"])
      derived("difference", "原有数量之差", high.value - low.value, high.unit, .difference, ["larger", "smaller"])
      derived("mean", "转移后各有", (high.value + low.value) / 2, high.unit, .quotient, ["total", "two"])
      derived("transfer", "应从较多方移给较少方", (high.value - low.value) / 2, high.unit, .quotient, ["difference", "two"])
      relations.append(.init(operation: .difference, inputIDs: ["larger", "transfer"], outputID: "mean"))
      relations.append(.init(operation: .sum, inputIDs: ["smaller", "transfer"], outputID: "mean"))
      diagramKind = .balance; displayed = ["larger", "smaller", "mean", "transfer"]
    } else {
      let field = kind == "sum_difference" ? "difference" : "multiplier"
      try keys(entry, ["id", "title", "kind", "total", field])
      let total = try source(entry["total"]), condition = try source(entry[field])
      guard !total.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        ["共", "总", "合计", "一共", "total", "altogether", "sum"].contains(where: total.evidence.lowercased().contains) else {
        throw fail("和差与和倍配方必须引用原题明确的总量，不能把差数当总数。")
      }
      given("total", "两量总和", total)
      if kind == "sum_difference" {
        try sameUnit(total.unit, condition.unit)
        guard total.value >= condition.value,
          MathOriginalQuantityPremise.difference(condition.value, evidence: condition.evidence) else {
          throw fail("和差配方必须给出明确差量，且总量不能小于差量。")
        }
        given("difference", "原题明确的差量", condition)
        constant("two", "平分为两份", 2, "从总量去掉两量之差，余量是两份较小量。")
        derived("equal_total", "去掉差量后的两份", total.value - condition.value, total.unit, .difference, ["total", "difference"])
        let small = (total.value - condition.value) / 2
        derived("smaller", "较少量", small, total.unit, .quotient, ["equal_total", "two"])
        derived("larger", "较多量", small + condition.value, total.unit, .sum, ["smaller", "difference"])
        diagramKind = .barComparison; displayed = ["smaller", "larger", "difference"]
      } else {
        let multiplier = condition.value
        let multiplierUnit = condition.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["", "倍"].contains(multiplierUnit), (2...20).contains(multiplier), multiplier.rounded() == multiplier,
          MathOriginalQuantityPremise.multiplier(multiplier, evidence: condition.evidence) else {
          throw fail("和倍配方必须引用原题的无单位整数倍数2至20。")
        }
        // “倍” denotes a dimensionless ratio, as in the difference-ratio
        // compiler. Physical units still reject; retain the original citation.
        given("multiplier", "较大量是较小量的倍数", (condition.value, "", condition.evidence))
        constant("one", "较小量占一份", 1, "倍数比较把较小量看作一份；不是原题额外数量。")
        derived("total_parts", "两量合占份数", multiplier + 1, "", .sum, ["multiplier", "one"])
        let small = total.value / (multiplier + 1)
        derived("smaller", "较小量（1份）", small, total.unit, .quotient, ["total", "total_parts"])
        derived("larger", "较大量（\(Int(multiplier))份）", small * multiplier, total.unit, .product, ["smaller", "multiplier"])
        diagramKind = .equalParts; displayed = ["smaller", "larger"]; parts = [1, Int(multiplier)]
      }
      relations.append(.init(operation: .sum, inputIDs: ["smaller", "larger"], outputID: "total"))
    }
    let diagram = MathDiagram(id: id, title: title, kind: diagramKind, facts: facts, relations: relations,
      factIDs: displayed, parts: parts)
    try diagram.validate()
    return diagram
  }
}
