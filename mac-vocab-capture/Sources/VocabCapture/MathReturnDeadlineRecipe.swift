import Foundation
import CoreFoundation

/// One outward leg and immediate return over the same route at constant speeds.
/// No model-authored arithmetic or layout is accepted in this bounded recipe.
enum MathReturnDeadlineRecipe {
  static let contract = """
    return_deadline适用于恒速去程后立即沿原路返回、无停留或其他行程，比较往返总时间与限时。不是面积图。必填id、title、kind:"return_deadline"、distance_unit（米或千米）、time_unit（分钟或小时）、outward_speed、return_speed、outward_time、deadline。后四项只填{"value":原题数值,"evidence":"含数值的原题条件"}。各速度单位为distance_unit/time_unit，时间均为time_unit。不要填回程时间、路程、总时间或判断结果；程序计算并绘制去程/回程表及限时比较。其他行程或单位不一致时不能套用。
    """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    guard Set(entry.keys) == ["id", "title", "kind", "distance_unit", "time_unit", "outward_speed", "return_speed", "outward_time", "deadline"],
      entry["kind"] as? String == "return_deadline",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let distanceUnit = entry["distance_unit"] as? String, ["米", "千米"].contains(distanceUnit),
      let timeUnit = entry["time_unit"] as? String, ["分钟", "小时"].contains(timeUnit) else {
      throw fail("往返限时配方仅接受同一路程、统一速度与时间单位的原题条件。")
    }
    var facts: [MathDiagram.Fact] = [], relations: [MathDiagram.Relation] = []
    func given(_ key: String, _ label: String, _ unit: String) throws -> Double {
      guard let source = entry[key] as? [String: Any], Set(source.keys) == ["value", "evidence"],
        let value = source["value"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, value.doubleValue > 0, value.doubleValue <= 1_000_000_000,
        let evidence = source["evidence"] as? String, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        evidence.count <= 500, MathDiagramPlan.evidenceContains(value.doubleValue, in: evidence) else { throw fail("往返配方必须提供正的有限原题数量及对应来源。") }
      facts.append(.init(id: key, label: label, value: value.doubleValue, unit: unit, origin: .given, evidence: evidence))
      return value.doubleValue
    }
    func derived(_ key: String, _ label: String, _ value: Double, _ unit: String,
      _ operation: MathDiagram.Operation, _ inputs: [String]) {
      facts.append(.init(id: key, label: label, value: value, unit: unit, origin: .derived))
      relations.append(.init(operation: operation, inputIDs: inputs, outputID: key))
    }
    let outwardSpeed = try given("outward_speed", "去程速度", distanceUnit + "/" + timeUnit)
    let returnSpeed = try given("return_speed", "回程速度", distanceUnit + "/" + timeUnit)
    let outwardTime = try given("outward_time", "去程时间", timeUnit)
    let deadline = try given("deadline", "规定总时间", timeUnit)
    let distance = outwardSpeed * outwardTime, returnTime = distance / returnSpeed
    let total = outwardTime + returnTime
    derived("distance", "去程路程", distance, distanceUnit, .product, ["outward_speed", "outward_time"])
    derived("return_distance", "原路返回路程", distance, distanceUnit, .equal, ["distance"])
    derived("return_time", "回程时间", returnTime, timeUnit, .quotient, ["return_distance", "return_speed"])
    derived("total_time", "往返总时间", total, timeUnit, .sum, ["outward_time", "return_time"])
    derived("deadline_difference", total > deadline ? "超过规定时间" : "剩余时间", abs(total - deadline), timeUnit,
      .difference, total >= deadline ? ["total_time", "deadline"] : ["deadline", "total_time"])
    // The time rows keep the full journey comparison visible in the same graph.
    let diagram = MathDiagram(id: id, title: title, kind: .table, facts: facts, relations: relations,
      columns: ["数值"], rows: [
        .init(label: "去程速度", factIDs: ["outward_speed"]), .init(label: "去程时间", factIDs: ["outward_time"]),
        .init(label: "去程路程", factIDs: ["distance"]), .init(label: "回程速度", factIDs: ["return_speed"]),
        .init(label: "回程路程", factIDs: ["return_distance"]), .init(label: "回程时间", factIDs: ["return_time"]),
        .init(label: "往返总时间", factIDs: ["total_time"]), .init(label: "规定总时间", factIDs: ["deadline"]),
        .init(label: total > deadline ? "超时" : "剩余", factIDs: ["deadline_difference"]),
      ])
    try diagram.validate()
    return diagram
  }
}
