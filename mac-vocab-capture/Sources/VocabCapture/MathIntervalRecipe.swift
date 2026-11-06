import Foundation
import CoreFoundation

/// Converts a bounded interval description into checked arithmetic. Transcribed
/// evidence remains subject to inspection against the original photograph.
enum MathIntervalRecipe {
  static let contract = """
  interval_problem 只用于已知条件完整的正楼层向上、每相邻楼层台阶相同，或直线等距植树。只写原题条件，不写答案、facts、relations、布局。
  楼梯精确字段：{"id":"stairs","title":"楼层与间隔","kind":"interval_problem","scenario":"stairs","start_floor":{"value":1,"unit":"层","evidence":"原题从1楼到14楼"},"end_floor":{"value":14,"unit":"层","evidence":"原题从1楼到14楼"},"steps_per_interval":{"value":21,"unit":"级","evidence":"原题每层21级台阶"}}。
  植树精确字段：{"id":"planting","title":"直线等距位置与端点","kind":"interval_problem","scenario":"planting","length":{"value":100,"unit":"米","evidence":"原题路长100米"},"spacing":{"value":5,"unit":"米","evidence":"原题每隔5米"},"endpoints":"both","endpoint_evidence":"原题两端都种"}。endpoints 只能为 both（两端都种）、one（只种一端）、neither（两端不种），端点条件必须引用原题；总长度须能整分间距。数字对象仅含 value、unit、evidence，数字须出现在原题引文中。程序计算间隔与台阶或树的棵数。
  向下走、地下楼层、不同层台阶不同、环形植树、余段或条件不足均不得强套配方，改用一般解答；主方法允许为空。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
      guard Set(object.keys) == allowed else { throw fail("间隔配方字段缺失或含有未支持的答案、关系或布局。") }
    }
    func source(_ raw: Any?, integer: Bool, unit: String) throws -> (Double, String) {
      guard let object = raw as? [String: Any] else { throw fail("间隔数量缺少原题来源。") }
      try keys(object, ["value", "unit", "evidence"])
      guard let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        // 楼 and 层 are synonymous only for floor positions. Steps and
        // planting distances retain their exact dimensional requirements.
        (object["unit"] as? String == unit || (unit == "层" && object["unit"] as? String == "楼")
          || (unit == "级" && object["unit"] as? String == "级台阶")),
        let evidence = object["evidence"] as? String,
        !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.count <= 500 else {
        throw fail("间隔数量、单位或原题来源无效。")
      }
      let value = number.doubleValue
      guard value.isFinite, value > 0, value <= 1_000_000_000,
        !integer || value.rounded() == value else { throw fail("间隔数量必须为正，位置序号和台阶数必须为整数。") }
      guard MathDiagramPlan.evidenceContains(value, in: evidence) else { throw fail("间隔数量与所引原题数字不一致。") }
      return (value, evidence)
    }
    guard entry["kind"] as? String == "interval_problem",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let scenario = entry["scenario"] as? String else { throw fail("间隔配方必须指定已支持的情境。") }
    var facts: [MathDiagram.Fact] = [], relations: [MathDiagram.Relation] = []
    func given(_ id: String, _ label: String, _ value: (Double, String), _ unit: String) {
      facts.append(.init(id: id, label: label, value: value.0, unit: unit, origin: .given, evidence: value.1))
    }
    func derived(_ id: String, _ label: String, _ value: Double, _ unit: String,
      _ operation: MathDiagram.Operation, _ inputs: [String]) {
      facts.append(.init(id: id, label: label, value: value, unit: unit, origin: .derived))
      relations.append(.init(operation: operation, inputIDs: inputs, outputID: id))
    }
    if scenario == "stairs" {
      try keys(entry, ["id", "title", "kind", "scenario", "start_floor", "end_floor", "steps_per_interval"])
      let start = try source(entry["start_floor"], integer: true, unit: "层")
      let end = try source(entry["end_floor"], integer: true, unit: "层")
      let per = try source(entry["steps_per_interval"], integer: true, unit: "级")
      // Descending, basements, skipped storeys and variable flights need a
      // different description; do not infer those conditions from prose.
      guard end.0 > start.0, end.0 - start.0 <= 1000 else { throw fail("楼梯配方仅支持正楼层向上走，且每相邻楼层台阶数相同。") }
      given("start", "起点楼层序号", start, "")
      given("end", "终点楼层序号", end, "")
      given("per", "每相邻楼层台阶", per, "级")
      derived("intervals", "走过的楼层间隔", end.0 - start.0, "", .difference, ["end", "start"])
      derived("total", "总台阶", (end.0 - start.0) * per.0, "级", .product, ["intervals", "per"])
    } else if scenario == "planting" {
      try keys(entry, ["id", "title", "kind", "scenario", "length", "spacing", "endpoints", "endpoint_evidence"])
      let length = try source(entry["length"], integer: false, unit: "米")
      let spacing = try source(entry["spacing"], integer: false, unit: "米")
      guard let endpoints = entry["endpoints"] as? String, ["both", "one", "neither"].contains(endpoints),
        let evidence = entry["endpoint_evidence"] as? String,
        !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.count <= 350 else {
        throw fail("植树必须明确直线路段两端都种、只种一端或两端不种的原题条件。")
      }
      let count = length.0 / spacing.0
      guard count.isFinite, count.rounded() == count, (1...1000).contains(count),
        endpoints != "neither" || count >= 2 else {
        throw fail("植树配方只支持等距且总长度可整分的直线路段；不支持环形或余段。")
      }
      given("total", "路段总长度", length, "米")
      given("per", "相邻位置间距", spacing, "米")
      facts.append(.init(id: "endpoint_rule", label: "原题端点条件", value: 1, origin: .constant, evidence: "端点计数规则：" + evidence))
      facts.append(.init(id: "start", label: "路段起点位置序号（边界点并非都种树）", value: 0,
        origin: .constant, evidence: "测量位置从零编号；点表示边界位置，不代表均种树。"))
      derived("end", "路段终点位置序号", count, "", .quotient, ["total", "per"])
      derived("intervals", "等距间隔数", count, "", .difference, ["end", "start"])
      relations.append(.init(operation: .product, inputIDs: ["intervals", "per"], outputID: "total"))
      let label = endpoints == "both" ? "两端都种：树的棵数" : endpoints == "one" ? "只种一端：树的棵数" : "两端不种：树的棵数"
      if endpoints == "one" {
        derived("tree_count", label, count, "", .equal, ["intervals"])
      } else {
        derived("tree_count", label, count + (endpoints == "both" ? 1 : -1), "",
          endpoints == "both" ? .sum : .difference, ["intervals", "endpoint_rule"])
      }
    } else { throw fail("未支持的间隔情境应采用一般解答，不能强套楼梯或直线植树配方。") }
    let diagram = MathDiagram(id: id, title: title, kind: .interval, facts: facts, relations: relations,
      factIDs: ["start", "end", "intervals", "per", "total"])
    try diagram.validate()
    return diagram
  }
}
