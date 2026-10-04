import Foundation

/// AppKit ranges are UTF-16 offsets. Keep the exact screenshot text between
/// selected words, including punctuation and line wraps, until query time.
struct OCRSelection {
  let text: String

  private var words: [NSRange] {
    let expression = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’–-][A-Za-z]+)*")
    return expression.matches(
      in: text, range: NSRange(location: 0, length: (text as NSString).length)
    ).map(\.range)
  }

  func wordRange(at offset: Int) -> NSRange? {
    words.first { NSLocationInRange(offset, $0) }
  }

  func snappedRange(_ range: NSRange) -> NSRange? {
    guard range.location != NSNotFound, range.length > 0,
      range.location <= (text as NSString).length,
      range.length <= (text as NSString).length - range.location
    else { return nil }
    let matching = words.filter { NSIntersectionRange($0, range).length > 0 }
    guard let first = matching.first, let last = matching.last else { return nil }
    return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
  }

  func selection(in range: NSRange) -> SelectedText? {
    guard let range = snappedRange(range) else { return nil }
    let source = text as NSString
    let prefix = source.substring(to: range.location)
    let suffix = source.substring(from: NSMaxRange(range))
    let start = prefix.rangeOfCharacter(
      from: CharacterSet(charactersIn: ".!?。！？"), options: .backwards)
    let end = suffix.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?。！？"))
    // Use NSString lengths rather than Swift character counts for emoji/CJK.
    let startOffset =
      start.map { (String(prefix[..<prefix.index(after: $0.lowerBound)]) as NSString).length } ?? 0
    let tailLength =
      end.map { (String(suffix[...$0.lowerBound]) as NSString).length }
      ?? (suffix as NSString).length
    let context = source.substring(
      with: NSRange(location: startOffset, length: NSMaxRange(range) + tailLength - startOffset))
    return SelectedText(
      word: normalized(source.substring(with: range)), context: normalized(context))
  }

  private func normalized(_ value: String) -> String {
    value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(
      separator: " ")
  }
}
