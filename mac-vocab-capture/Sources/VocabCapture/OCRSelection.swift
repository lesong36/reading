import Foundation

/// AppKit ranges are UTF-16 offsets. Keep the exact screenshot text between
/// selected words, including punctuation and line wraps, until query time.
struct OCRSelection {
  let text: String

  static func range(of needle: String, in source: NSString, occurrence: Int = 0) -> NSRange {
    guard occurrence >= 0, !needle.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
    var cursor = 0
    for index in 0...occurrence {
      guard cursor <= source.length else { return NSRange(location: NSNotFound, length: 0) }
      let found = source.range(
        of: needle, options: [.caseInsensitive, .diacriticInsensitive],
        range: NSRange(location: cursor, length: source.length - cursor))
      guard found.location != NSNotFound else { return found }
      if index == occurrence { return found }
      cursor = NSMaxRange(found)
    }
    return NSRange(location: NSNotFound, length: 0)
  }

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
    let word = normalized(source.substring(with: range))
    guard words.filter({ NSIntersectionRange($0, range).length > 0 }).count <= SelectionTextContract.maximumWords,
      let context = SelectionTextContract.sentence(text, selectedRange: range) else { return nil }
    return SelectedText(word: word, context: context)
  }

  private func normalized(_ value: String) -> String {
    value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(
      separator: " ")
  }
}
