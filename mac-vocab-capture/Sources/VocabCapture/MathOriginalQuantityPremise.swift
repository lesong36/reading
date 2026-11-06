import Foundation

/// Necessary citation checks, not proof that the photograph was transcribed
/// correctly. Original conditions and answers remain subject to human review.
enum MathOriginalQuantityPremise {
  static func difference(_ value: Double, evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.lowercased()
    guard original(value, evidence: text) else { return false }
    return text.components(separatedBy: CharacterSet(charactersIn: "，,；;。\n")).contains { clause in
      ["差", "比", "多", "少", "more", "less", "difference", "older", "younger", "exceeds"].contains { marker in
        guard let range = clause.range(of: marker) else { return false }
        return firstNumber(in: String(clause[range.upperBound...])).map { MathDiagramPlan.evidenceContains(value, in:$0) } == true
      }
    }
  }
  static func multiplier(_ value: Double, evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.lowercased()
    guard original(value, evidence: text) else { return false }
    for clause in text.components(separatedBy: CharacterSet(charactersIn:"，,；;。\n")) {
      for marker in ["倍", "times"] {
        if let range = clause.range(of:marker),
          let number = numbers(in:String(clause[..<range.lowerBound])).last,
          MathDiagramPlan.evidenceContains(value,in:number) { return true }
      }
      for marker in ["乘", "multipl"] {
        if let range = clause.range(of:marker),
          let number = firstNumber(in:String(clause[range.upperBound...])),
          MathDiagramPlan.evidenceContains(value,in:number) { return true }
      }
    }
    return false
  }
  private static func firstNumber(in text: String) -> String? { numbers(in:text).first }
  private static func numbers(in text: String) -> [String] {
    let expression = try! NSRegularExpression(pattern:#"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|负?[零〇一二两三四五六七八九十百千万亿]+(?:点[零〇一二两三四五六七八九]+)?"#)
    return expression.matches(in:text,range:NSRange(text.startIndex..<text.endIndex,in:text)).compactMap {
      Range($0.range,in:text).map { String(text[$0]) }
    }
  }
  static func original(_ value: Double, evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping
    // A calculated source such as 38−22=16 must be represented by an operation,
    // never recast as a literal original quantity in a native recipe.
    guard !text.contains("="), !text.contains("＝"),
      text.range(of: #"[0-9]\s*[+−\-×÷*/]\s*[0-9]"#, options: .regularExpression) == nil else { return false }
    return MathDiagramPlan.evidenceContains(value, in: text)
  }
}
