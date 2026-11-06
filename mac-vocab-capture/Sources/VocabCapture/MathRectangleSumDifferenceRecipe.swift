import Foundation
import CoreFoundation

/// A rectangle's explicitly stated side sum and difference. Citation checks do
/// not certify the photograph transcription; the original still needs review.
enum MathRectangleSumDifferenceRecipe {
  static let contract = """
  rectangle_sum_difference只用于长方形原题明确给出长与宽之和及长比宽多多少，求长、宽、面积；周长不是长宽之和，不得自行除以2后冒充原题条件。精确字段id、title、kind:"rectangle_sum_difference"、rectangle_evidence、total_sides、difference；rectangle_evidence单独引用原题说明长方形的句子，不从标题或计算结果猜形状；后两项精确为{"value":原题数值,"unit":"厘米或米或千米","evidence":"含长方形、长宽和或差及数字单位的原题引文"}，单位须相同。程序计算长=(和+差)÷2、宽=(和−差)÷2、面积=长×宽并绘制矩形。不填推算尺寸、面积、关系或布局；条件不符使用一般解答。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ message: String) -> MathDiagram.ValidationError { .init(message: message) }
    guard Set(entry.keys) == ["id", "title", "kind", "rectangle_evidence", "total_sides", "difference"],
      entry["kind"] as? String == "rectangle_sum_difference",
      let id = entry["id"] as? String, let title = entry["title"] as? String else {
      throw fail("长方形和差配方只接受原题长宽之和、差及来源，不接受尺寸答案或额外字段。")
    }
    func source(_ key: String) throws -> (Double, String, String) {
      guard let object = entry[key] as? [String: Any], Set(object.keys) == ["value", "unit", "evidence"],
        let value = object["value"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, (0...1_000_000_000).contains(value.doubleValue),
        let rawUnit = object["unit"] as? String, let unit = canonicalUnit(rawUnit),
        let evidence = object["evidence"] as? String, !evidence.isEmpty, evidence.count <= 500,
        MathOriginalQuantityPremise.original(value.doubleValue, evidence: evidence) else {
        throw fail("长方形和差条件需要有限数值、长度单位及对应原题引文。")
      }
      return (value.doubleValue, unit, evidence)
    }
    let total = try source("total_sides"), difference = try source("difference")
    guard let shape = entry["rectangle_evidence"] as? String, !shape.isEmpty, shape.count <= 500,
      ["长方形", "矩形"].contains(where: shape.contains),
      !["不是", "并非", "不一定", "假设", "假如", "如果", "可能", "三角形", "平行四边形", "标题", "看起来", "推断"].contains(where: shape.contains) else {
      throw fail("必须单独引用原题的长方形条件，不能从标题或边长条件猜测形状。")
    }
    let combined = total.2 + difference.2 + shape
    guard
      !["正方形", "周长", "面积是", "面积为", "假设", "算得", "推得", "由此"].contains(where: combined.contains),
      total.1 == difference.1, total.0 > difference.0,
      matches(total.2, value: total.0, unit: total.1,
        relation: #"(?:长(?:和|与)宽(?:的|之)?(?:和|总和)|长宽(?:的|之)?(?:和|总和)|长(?:和|与)宽(?:合计|共))\s*(?:是|为|等于|共)?\s*"#),
      matches(difference.2, value: difference.0, unit: difference.1,
        relation: #"(?:长比宽(?:多|长)|长(?:和|与)宽(?:的|之)?(?:差|相差)|长宽(?:的|之)?(?:差|相差))\s*(?:是|为|等于)?\s*"#) else {
      throw fail("必须引用长方形明确的长宽之和及长比宽的差，周长或其他数量不能替代。")
    }
    let length = (total.0 + difference.0) / 2, width = (total.0 - difference.0) / 2
    let squareUnit = ["厘米": "平方厘米", "米": "平方米", "千米": "平方千米"][total.1]!
    let facts: [MathDiagram.Fact] = [
      .init(id: "total_sides", label: "长与宽之和", value: total.0, unit: total.1, origin: .given, evidence: total.2),
      .init(id: "difference", label: "长比宽多", value: difference.0, unit: total.1, origin: .given, evidence: difference.2),
      .init(id: "two", label: "两份相等的边长", value: 2, origin: .constant,
        evidence: "和加差得到两份长，和减差得到两份宽；分别平分为两份。"),
      .init(id: "double_length", label: "两份长", value: total.0 + difference.0, unit: total.1, origin: .derived),
      .init(id: "double_width", label: "两份宽", value: total.0 - difference.0, unit: total.1, origin: .derived),
      .init(id: "length", label: "长", value: length, unit: total.1, origin: .derived),
      .init(id: "width", label: "宽", value: width, unit: total.1, origin: .derived),
      .init(id: "area", label: "长方形面积", value: length * width, unit: squareUnit, origin: .derived),
    ]
    let diagram = MathDiagram(id: id, title: title, kind: .area, facts: facts, relations: [
      .init(operation: .sum, inputIDs: ["total_sides", "difference"], outputID: "double_length"),
      .init(operation: .difference, inputIDs: ["total_sides", "difference"], outputID: "double_width"),
      .init(operation: .quotient, inputIDs: ["double_length", "two"], outputID: "length"),
      .init(operation: .quotient, inputIDs: ["double_width", "two"], outputID: "width"),
      .init(operation: .product, inputIDs: ["length", "width"], outputID: "area"),
      .init(operation: .sum, inputIDs: ["length", "width"], outputID: "total_sides"),
      .init(operation: .difference, inputIDs: ["length", "width"], outputID: "difference"),
    ], factIDs: ["length", "width", "area"])
    try diagram.validate()
    return diagram
  }

  private static func canonicalUnit(_ unit: String) -> String? {
    ["厘米": "厘米", "cm": "厘米", "米": "米", "m": "米", "千米": "千米", "km": "千米"][unit]
  }

  private static func matches(_ evidence: String, value: Double, unit: String, relation: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping
    let number = #"([+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)|[零〇一二两三四五六七八九十百千万亿]+(?:点[零〇一二两三四五六七八九]+)?)"#
    guard let regex = try? NSRegularExpression(pattern: relation + number + #"\s*(厘米|千米|米|cm|km|m)(?![A-Za-z])"#) else { return false }
    return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).contains { match in
      guard let quantityRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text) else { return false }
      return MathOriginalQuantityPremise.original(value, evidence: String(text[quantityRange]))
        && canonicalUnit(String(text[unitRange])) == unit
    }
  }
}
