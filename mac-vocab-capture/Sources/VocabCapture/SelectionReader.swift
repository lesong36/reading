import ApplicationServices
import AppKit
import Foundation

struct SelectedText: Sendable {
  let word: String
  let context: String
}

enum SelectionReader {
  /// Uses Accessibility only after an explicit user action (service/hot key).
  /// It never polls the foreground application or records keystrokes.
  static func read() -> SelectedText? {
    readFocusedSelection() ?? clipboardFallback()
  }

  /// Reads only the active app's current selection. Used after the user drags
  /// to select text, so a stale clipboard value never creates a floating UI.
  static func readFocusedSelection() -> SelectedText? {
    let system = AXUIElementCreateSystemWide()
    var focusedApplication: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApplication) == .success,
          let app = focusedApplication else { return nil }

    let application = app as! AXUIElement
    var focusedElement: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
          let element = focusedElement else { return nil }

    var selectedText: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
          let text = selectedText as? String else { return nil }
    guard let selection = sanitize(text) else { return nil }
    let ancestors = accessibleAncestors(startingAt: element as! AXUIElement)
    let directContext = ancestors
      .lazy
      .compactMap { sentenceContext(in: $0) }
      .first(where: { isUsableSentence($0, containing: selection.word) }) ?? selection.context
    let selectionBounds = ancestors.lazy.compactMap { selectedTextBounds(in: $0) }.first
    let context = isUsableSentence(directContext, containing: selection.word)
      ? directContext
      : selectionBounds.flatMap { nearbyTextSentence(in: Array(ancestors.prefix(5)), containing: selection.word, around: $0) } ?? selection.context
    return SelectedText(word: selection.word, context: context)
  }

  private static func clipboardFallback() -> SelectedText? {
    sanitize(NSPasteboard.general.string(forType: .string) ?? "")
  }

  private static func sanitize(_ input: String) -> SelectedText? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = trimmed.trimmingCharacters(in: .punctuationCharacters)
    let pattern = "^[A-Za-z]+(?:['’][A-Za-z]+)?(?:[ -][A-Za-z]+(?:['’][A-Za-z]+)?){0,3}$"
    guard word.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return SelectedText(word: word, context: trimmed)
  }

  static func fromServicePasteboard(_ pasteboard: NSPasteboard) -> SelectedText? {
    sanitize(pasteboard.string(forType: .string) ?? "")
  }

  /// OCR commonly wraps one sentence across multiple visual lines. Normalize
  /// those wraps first, then retain the full grammatical sentence containing
  /// the selected word or phrase instead of passing the whole screenshot.
  static func sentenceFromOCRText(_ text: String, containing word: String) -> String {
    let normalized = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard let match = normalized.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return String(normalized.prefix(600))
    }
    let prefix = normalized[..<match.lowerBound]
    let start = prefix.lastIndex(where: { ".!?。！？".contains($0) }).map { normalized.index(after: $0) } ?? normalized.startIndex
    let suffix = normalized[match.upperBound...]
    let end = suffix.firstIndex(where: { ".!?。！？".contains($0) }).map { normalized.index(after: $0) } ?? normalized.endIndex
    let sentence = normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    return String(sentence.prefix(600))
  }

  private static func accessibleAncestors(startingAt element: AXUIElement) -> [AXUIElement] {
    var result = [element]
    var current = element
    for _ in 0..<10 {
      var parentValue: CFTypeRef?
      guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
            let parentValue else { break }
      let parent = parentValue as! AXUIElement
      result.append(parent)
      current = parent
    }
    return result
  }

  private static func sentenceContext(in element: AXUIElement) -> String? {
    var textValue: CFTypeRef?
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue else { return nil }
    guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    let axRange = unsafeBitCast(rangeValue, to: AXValue.self)

    var range = CFRange()
    guard AXValueGetValue(axRange, .cfRange, &range), range.location != kCFNotFound else { return nil }
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue) == .success,
       let text = textValue as? String {
      return sentence(in: text, selectedRange: range)
    }

    // Browsers and PDF readers often deliberately omit AXValue for large text,
    // but still implement the parameterized range request. Ask only for the
    // small neighborhood around the selection, never for the whole document.
    var neighborhood = CFRange(location: max(0, range.location - 360), length: range.length + 720)
    guard let neighborhoodValue = AXValueCreate(.cfRange, &neighborhood) else { return nil }
    guard let text = textForRange(in: element, rangeValue: neighborhoodValue) else { return nil }
    let relativeRange = CFRange(location: max(0, range.location - neighborhood.location), length: range.length)
    return sentence(in: text, selectedRange: relativeRange)
  }

  private static func selectedTextBounds(in element: AXUIElement) -> CGRect? {
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue,
          CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    var boundsValue: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXBoundsForRangeParameterizedAttribute as CFString,
      rangeValue,
      &boundsValue
    ) == .success, let boundsValue,
      CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
    let axBounds = unsafeBitCast(boundsValue, to: AXValue.self)
    var bounds = CGRect.zero
    return AXValueGetValue(axBounds, .cgRect, &bounds) ? bounds : nil
  }

  /// Some browsers expose a selection through a small leaf node but represent
  /// its sentence as a sibling AXStaticText. Select the matching sentence
  /// nearest the selected range, never merely the first matching word.
  private static func nearbyTextSentence(in roots: [AXUIElement], containing word: String, around selectionBounds: CGRect) -> String? {
    var pending = roots.map { (element: $0, depth: 0) }
    var candidates: [(sentence: String, distance: CGFloat)] = []
    var visited = 0
    while let next = pending.popLast(), visited < 800 {
      visited += 1
      if let text = readableText(in: next.element), text.count > word.count,
         text.count <= 1_500,
         text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
         let bounds = elementBounds(of: next.element) {
        let sentence = sentenceFromOCRText(text, containing: word)
        if isUsableSentence(sentence, containing: word) {
          candidates.append((sentence, rectangleDistance(from: selectionBounds, to: bounds)))
        }
      }
      guard next.depth < 6 else { continue }
      var childrenValue: CFTypeRef?
      if AXUIElementCopyAttributeValue(next.element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
         let children = childrenValue as? [AXUIElement] {
        pending.append(contentsOf: children.map { ($0, next.depth + 1) })
      }
    }
    return candidates.min { lhs, rhs in
      lhs.distance == rhs.distance ? lhs.sentence.count < rhs.sentence.count : lhs.distance < rhs.distance
    }?.sentence
  }

  private static func elementBounds(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, let sizeValue,
          CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
    let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
    guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
  }

  private static func rectangleDistance(from source: CGRect, to target: CGRect) -> CGFloat {
    let horizontal = max(source.minX - target.maxX, target.minX - source.maxX, 0)
    let vertical = max(source.minY - target.maxY, target.minY - source.maxY, 0)
    return hypot(horizontal, vertical)
  }

  private static func isUsableSentence(_ text: String, containing word: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
    let hasTerminator = trimmed.contains { ".!?。！？".contains($0) }
    return trimmed.count >= word.count + 12 && wordCount >= 4 && hasTerminator
  }

  private static func readableText(in element: AXUIElement) -> String? {
    for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let text = value as? String else { continue }
      let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty, normalized.count <= 8_000 { return normalized }
    }
    return nil
  }

  private static func textForRange(in element: AXUIElement, rangeValue: AXValue) -> String? {
    var textValue: CFTypeRef?
    if AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &textValue
    ) == .success, let text = textValue as? String {
      return text
    }
    if AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXAttributedStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &textValue
    ) == .success, let text = textValue as? NSAttributedString {
      return text.string
    }
    return nil
  }

  private static func sentence(in text: String, selectedRange: CFRange) -> String? {
    let nsText = text as NSString
    guard selectedRange.location >= 0, selectedRange.location <= nsText.length else { return nil }
    let isSeparator: (unichar) -> Bool = { character in
      character == 46 || character == 33 || character == 63 || character == 12290 || character == 65281 || character == 65311 || character == 10
    }
    var start = selectedRange.location
    var end = min(nsText.length, selectedRange.location + selectedRange.length)
    while start > 0, !isSeparator(nsText.character(at: start - 1)) { start -= 1 }
    while end < nsText.length, !isSeparator(nsText.character(at: end)) { end += 1 }
    if end < nsText.length { end += 1 }
    let sentence = nsText.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
    return sentence.isEmpty ? nil : String(sentence.prefix(600))
  }
}
