import Foundation
import CoreFoundation

/// Counts positions in an explicitly ordered repeating pattern. Citations are
/// necessary consistency checks; they do not establish fidelity to the photograph.
enum MathCycleRecipe {
  static let contract = """
  cyclic_pattern 只用于原题明确给出的重复排列及总项数（1…1000）。精确字段：{"id":"pattern","title":"周期与余项","kind":"cyclic_pattern","count":{"value":14,"evidence":"一共排列14个"},"labels":["红","蓝","绿"],"pattern_evidence":"按红、蓝、绿的顺序重复排列"}。labels 必须完整保留一个周期的顺序，可重复，每项1…30字，共1…12项；引用须包含同序的完整顿号或逗号分隔列表。不得写 period、cycles、remainder、facts、relations 或答案。程序数出周期长度，计算完整周期和余项；不得把推算的周期长度冒充原题数字。无法明确一个周期或条件不足时采用一般解答，主方法允许为空。
  """

  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ message: String) -> MathDiagram.ValidationError { .init(message: message) }
    guard Set(entry.keys) == ["id", "title", "kind", "count", "labels", "pattern_evidence"],
      entry["kind"] as? String == "cyclic_pattern",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let count = entry["count"] as? [String: Any], Set(count.keys) == ["value", "evidence"],
      let number = count["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let evidence = count["evidence"] as? String, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      evidence.count <= 500,
      let labels = entry["labels"] as? [String], (1...12).contains(labels.count),
      labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 30
        && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "、，,\n\r")) == nil }),
      let patternEvidence = entry["pattern_evidence"] as? String,
      !patternEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, patternEvidence.count <= 500 else {
      throw fail("周期配方只接受总项数、完整有序周期名称及原题引文，不能注入计算结果或布局。")
    }
    let total = number.doubleValue
    guard total.isFinite, total.rounded() == total, (1...1000).contains(total),
      MathOriginalQuantityPremise.original(total, evidence: evidence) else {
      throw fail("周期总项数必须为原题引用中的1至1000整数，不能使用推算答案。")
    }
    // Match a contiguous list, not an unordered bag or a subsequence that could
    // omit a position. The list may be surrounded by prose, but not extra items.
    let separator = #"\s*[、，,]\s*"#
    let ordered = labels.map { NSRegularExpression.escapedPattern(for: $0.precomposedStringWithCompatibilityMapping) }.joined(separator: separator)
    let expression = try NSRegularExpression(pattern: #"(?<![、，,])"# + ordered + #"(?!\s*[、，,])"#)
    let source = patternEvidence.precomposedStringWithCompatibilityMapping
    let matches = expression.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
    let completeList = matches.contains { match in
      guard let range = Range(match.range, in: source) else { return false }
      let prefix = source[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = source[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      let delimiters: Set<Character> = ["、", "，", ","]
      guard prefix.last.map({ !delimiters.contains($0) }) ?? true else { return false }
      guard prefix.isEmpty || ["按", "依次", "顺序", "：", ":", "为", "是", "“", "\""].contains(where: { prefix.hasSuffix($0) }) else { return false }
      return suffix.isEmpty || ["的顺序", "依次", "重复", "循环", "排列", "顺序", "。", "；", ";", ".", "”", "\""].contains { suffix.hasPrefix($0) }
    }
    guard completeList else {
      throw fail("周期名称必须与所引原题的完整排列顺序一致，不能漏项、调序或补造名称。")
    }
    var facts: [MathDiagram.Fact] = [
      .init(id: "total", label: "排列总项数", value: total, origin: .given, evidence: evidence)
    ]
    let positionIDs = labels.indices.map { "position_\($0 + 1)" }
    for index in labels.indices {
      facts.append(.init(id: positionIDs[index], label: "周期第\(index + 1)个位置（\(labels[index])）",
        value: 1, origin: .constant, evidence: "结构计数规则：每个明确列出的位置计1项；原题排列：" + patternEvidence))
    }
    let period = Double(labels.count)
    facts.append(.init(id: "period", label: "数出一个周期的项数", value: period, origin: .derived))
    facts.append(.init(id: "cycles", label: "完整周期数", value: floor(total / period), origin: .derived))
    facts.append(.init(id: "remainder", label: "从首项开始的余项数", value: total.truncatingRemainder(dividingBy: period), origin: .derived))
    let relations: [MathDiagram.Relation] = [
      .init(operation: labels.count == 1 ? .equal : .sum, inputIDs: positionIDs, outputID: "period"),
      .init(operation: .floorQuotient, inputIDs: ["total", "period"], outputID: "cycles"),
      .init(operation: .remainder, inputIDs: ["total", "period"], outputID: "remainder")
    ]
    let diagram = MathDiagram(id: id, title: title, kind: .cycle, facts: facts, relations: relations,
      factIDs: ["total", "period", "cycles", "remainder"], columns: labels)
    try diagram.validate()
    return diagram
  }
}
