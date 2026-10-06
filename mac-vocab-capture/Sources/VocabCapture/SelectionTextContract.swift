import Foundation

/// Mirrored by browser-extension/text-contract.js; public fixtures lock both implementations.
enum SelectionTextContract {
  static let maximumWords = 12
  static func normalized(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
  static func phrase(_ input: String) -> String? {
    let value = normalized(input).trimmingCharacters(in: .punctuationCharacters)
    let pattern = "^[A-Za-z]+(?:['’–-][A-Za-z]+)*(?:[ –-][A-Za-z]+(?:['’–-][A-Za-z]+)*){0,11}$"
    return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
  }
  static func match(_ word: String, in text: String) -> NSRange? {
    let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z])"
    return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      .firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
  }
  static func sentence(_ text: String, selectedRange: NSRange) -> String? {
    let source = text as NSString
    guard selectedRange.location >= 0, selectedRange.length >= 0,
      selectedRange.location <= source.length, selectedRange.length <= source.length - selectedRange.location else { return nil }
    func boundary(_ index: Int) -> Bool {
      let c = source.character(at: index)
      if [10, 33, 63, 12290, 65281, 65311].contains(Int(c)) { return true }
      guard c == 46 else { return false }
      if index > 0, index + 1 < source.length,
        (48...57).contains(source.character(at: index - 1)), (48...57).contains(source.character(at: index + 1)) { return false }
      let preceding = source.substring(to: index).split(whereSeparator: { $0.isWhitespace }).last?.lowercased() ?? ""
      if ["dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e"].contains(preceding) { return false }
      if preceding.count == 1, preceding.first?.isLetter == true { return false }
      return true
    }
    var start = selectedRange.location
    var end = NSMaxRange(selectedRange)
    while start > 0, !boundary(start - 1) { start -= 1 }
    while end < source.length, !boundary(end) { end += 1 }
    if end < source.length { end += 1 }
    let result = normalized(source.substring(with: NSRange(location: start, length: end - start)))
    return result.isEmpty ? nil : String(result.prefix(800))
  }
}
