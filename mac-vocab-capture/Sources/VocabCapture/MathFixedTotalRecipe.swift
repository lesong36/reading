import Foundation
import CoreFoundation

/// A single unchanged resource divided into whole items before and after a
/// per-item usage change. Ambiguous remainders belong to ordinary reasoning.
enum MathFixedTotalRecipe {
  static let contract = """
    fixed_total仅适用于同一批资源总量不变、每件用量改变后求完整件数。必填id、title、kind:"fixed_total"、resource_unit、count_unit、original_per_item、original_count、improved_per_item、conservation_evidence。三个数量只填{"value":原题数值,"unit":"单位","evidence":"含数值的原题条件"}，每件量单位为resource_unit/count_unit，件数为count_unit。conservation_evidence引用承接同一批资源的原句，如“原来做791套的布，现在可做多少套？”，不要编写题目未说的“不变”。资源单位仅米、厘米、千米、克、千克、升、毫升、平方米；件数单位仅套、件、个、本、瓶、盒、袋、张、块。单位必须统一，无换算。程序计算总量和新件数并绘表；新件数非整数、有余料处理、预算变化或条件不明时不能套用。不得填计算结果、答案或布局。
    """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    guard Set(entry.keys) == ["id", "title", "kind", "resource_unit", "count_unit",
      "original_per_item", "original_count", "improved_per_item", "conservation_evidence"],
      entry["kind"] as? String == "fixed_total",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let resourceUnit = entry["resource_unit"] as? String,
      ["米", "厘米", "千米", "克", "千克", "升", "毫升", "平方米"].contains(resourceUnit),
      let countUnit = entry["count_unit"] as? String,
      ["套", "件", "个", "本", "瓶", "盒", "袋", "张", "块"].contains(countUnit),
      let conservation = entry["conservation_evidence"] as? String,
      conservation.count <= 500, conservedResource(conservation) else {
      throw fail("资源总量配方须明确使用同一批且总量不变的资源，并采用统一的资源与件数单位。")
    }
    var facts: [MathDiagram.Fact] = []
    func given(_ key: String, _ label: String, _ unit: String) throws -> Double {
      guard let source = entry[key] as? [String: Any], Set(source.keys) == ["value", "unit", "evidence"],
        let suppliedUnit = source["unit"] as? String,
        let number = source["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 1_000_000_000,
        let evidence = source["evidence"] as? String, evidence.count <= 500,
        MathOriginalQuantityPremise.original(number.doubleValue, evidence: evidence) else {
        throw fail("资源总量配方只接受正的有限原题数量、相同单位和含该数量的原始条件，不能引用算式。")
      }
      guard suppliedUnit == unit || (unit == resourceUnit + "/" + countUnit
        && suppliedUnit == resourceUnit && evidence.contains("每" + countUnit)) else {
        throw fail("每件资源单位只可按原题明确的每件条件规范，不能换算或混用单位。")
      }
      facts.append(.init(id: key, label: label, value: number.doubleValue, unit: unit, origin: .given, evidence: evidence))
      return number.doubleValue
    }
    let perUnit = resourceUnit + "/" + countUnit
    let originalPerItem = try given("original_per_item", "原来每件用量", perUnit)
    let originalCount = try given("original_count", "原来件数", countUnit)
    let improvedPerItem = try given("improved_per_item", "改变后每件用量", perUnit)
    let total = originalPerItem * originalCount
    let count = total / improvedPerItem
    // Decimal floating-point noise is tolerated; a genuinely fractional result
    // is never rounded into a real-world count.
    guard originalCount.rounded() == originalCount, total.isFinite,
      count.isFinite, count > 0, count <= 1_000_000_000,
      abs(count - count.rounded()) <= max(1e-10, count.ulp * 4) else {
      throw fail("完整件数必须为正整数；非整除、有余料或分配不明时须使用一般解答，不能自动舍入。")
    }
    facts.append(.init(id: "total_resource", label: "同一批资源总量", value: total, unit: resourceUnit, origin: .derived))
    facts.append(.init(id: "improved_count", label: "改变后完整件数", value: count.rounded(), unit: countUnit, origin: .derived))
    facts.append(.init(id: "checked_resource", label: "新方案使用总量", value: improvedPerItem * count.rounded(), unit: resourceUnit, origin: .derived))
    let diagram = MathDiagram(id: id, title: title, kind: .table, facts: facts, relations: [
      .init(operation: .product, inputIDs: ["original_per_item", "original_count"], outputID: "total_resource"),
      .init(operation: .quotient, inputIDs: ["total_resource", "improved_per_item"], outputID: "improved_count"),
      .init(operation: .product, inputIDs: ["improved_per_item", "improved_count"], outputID: "checked_resource"),
    ], columns: ["每件用量", "完整件数", "资源总量"], rows: [
      .init(label: "原来", factIDs: ["original_per_item", "original_count", "total_resource"]),
      .init(label: "改变后", factIDs: ["improved_per_item", "improved_count", "checked_resource"]),
    ])
    try diagram.validate()
    return diagram
  }

  private static func conservedResource(_ evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.lowercased()
    guard !text.isEmpty, !["增加", "减少", "另买", "额外", "不相同", "不是同", "不是原来", "不再", "总量改变", "总量变化", "总量不一定", "总量并非", "总量不是", "余料", "剩余材料"].contains(where: text.contains),
      !text.contains("="), !text.contains("＝") else { return false }
    let same = ["同一批", "同样的", "同一份", "原来的", "原有的", "这批", "same resource", "same batch"].contains(where: text.contains)
    let unchanged = ["总量不变", "数量不变", "总量相同", "总量相等", "仍使用", "仍用", "全部用于", "unchanged", "same total"].contains(where: text.contains)
    let carriedResource = text.range(of: #"原来[^。！？!?\n]{0,100}的(?:布|布料|材料|纸|水|油|资源)[，,；;\s]*现在[^。！？!?\n]{0,100}(?:可|能|可以)(?:做|制|装|分)"#, options: .regularExpression) != nil
    return (same && unchanged) || carriedResource
  }
}
