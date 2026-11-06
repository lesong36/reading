import Foundation

/// A narrow consistency notice, not a correctness verdict for an answer.
/// Unsupported arithmetic is skipped as a whole, never checked by taking a suffix.
enum MathExplicitAdditionAudit {
  struct Issue: Equatable {
    let expression: String
    let values: [UInt64]
  }

  private static let runs = try! NSRegularExpression(
    pattern: #"[\p{N}\p{Sm}\p{Pd}+*/×÷=＝＋−^().,:%％!_· \t]+"#)
  private static let additionEquality = try! NSRegularExpression(
    pattern: #"^[0-9]+(?:\s*\+\s*[0-9]+)*(?:\s*=\s*[0-9]+(?:\s*\+\s*[0-9]+)*)+$"#)

  static func issues(in answer: String) -> [Issue] {
    var result: [Issue] = []
    var fence: (marker: Character, count: Int)?
    for line in answer.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let marker = trimmed.first
      let markerCount = trimmed.prefix(while: { $0 == marker }).count
      if let current = fence {
        if marker == current.marker && markerCount >= current.count
          && trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
        {
          fence = nil
        }
        continue
      }
      if let marker, marker == "`" || marker == "~", markerCount >= 3 {
        fence = (marker, markerCount)
        continue
      }
      let source = line as NSString
      for match in runs.matches(in: line, range: NSRange(location: 0, length: source.length)) {
        let range = match.range
        // Avoid fragments of variables, scientific notation and subscripts.
        if range.location > 0 && isIdentifier(source.character(at: range.location - 1)) { continue }
        let end = NSMaxRange(range)
        if end < source.length && isIdentifier(source.character(at: end)) { continue }
        let expression = source.substring(with: range).trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: "＋", with: "+").replacingOccurrences(of: "＝", with: "=")
        guard expression.count <= 300, expression.contains("+"),
          additionEquality.firstMatch(
            in: expression, range: NSRange(expression.startIndex..., in: expression)) != nil
        else { continue }
        let values = expression.components(separatedBy: "=").compactMap(sum)
        guard values.count == expression.filter({ $0 == "=" }).count + 1,
          Set(values).count > 1
        else { continue }
        result.append(Issue(expression: expression, values: values))
        if result.count == 3 { return result }
      }
    }
    return result
  }

  static func notice(in answer: String) -> String? {
    let found = issues(in: answer)
    guard !found.isEmpty else { return nil }
    let details = found.map {
      "原文“\($0.expression)”各边计算为\($0.values.map(String.init).joined(separator: "、"))，数值不相等。"
    }.joined(separator: "\n")
    return "算式核对提示：\n" + details
      + "\n若此处是在举错误示例，请结合上下文判断；本提示不代表整题已核验。"
  }

  private static func sum(_ expression: String) -> UInt64? {
    var total: UInt64 = 0
    for token in expression.components(separatedBy: "+") {
      guard let value = UInt64(token.trimmingCharacters(in: .whitespaces)) else { return nil }
      let next = total.addingReportingOverflow(value)
      guard !next.overflow else { return nil }
      total = next.partialValue
    }
    return total
  }

  private static func isIdentifier(_ character: unichar) -> Bool {
    guard let scalar = UnicodeScalar(character) else { return false }
    // Chinese prose/units can border an equation; Latin and Greek identifiers cannot.
    return character == 95 || character == 92
      || (CharacterSet.letters.contains(scalar) && !(0x3400...0x9FFF).contains(character))
  }
}
