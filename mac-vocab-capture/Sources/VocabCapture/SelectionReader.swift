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
    let accessibilityContext = accessibleAncestors(startingAt: element as! AXUIElement)
      .lazy
      .compactMap { sentenceContext(in: $0) ?? visibleSentenceContext(in: $0, containing: selection.word) }
      .first(where: { $0.count > selection.context.count }) ?? selection.context
    let context = ReaderContextBridge.shared.sentence(for: selection.word) ?? accessibilityContext
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
    var parameterizedText: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      neighborhoodValue,
      &parameterizedText
    ) == .success, let text = parameterizedText as? String else { return nil }
    let relativeRange = CFRange(location: max(0, range.location - neighborhood.location), length: range.length)
    return sentence(in: text, selectedRange: relativeRange)
  }

  /// Chromium can expose the selected text on a leaf but only expose the page's
  /// visible text on its AXWebArea ancestor. Use that visible text as a final
  /// contextual source when its selected range is unavailable.
  private static func visibleSentenceContext(in element: AXUIElement, containing word: String) -> String? {
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue,
          CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    let axRange = unsafeBitCast(rangeValue, to: AXValue.self)
    guard AXValueGetValue(axRange, .cfRange, &range), range.location != kCFNotFound else { return nil }
    range.length = min(range.length, 4_000)
    guard let visibleRange = AXValueCreate(.cfRange, &range) else { return nil }
    var textValue: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      visibleRange,
      &textValue
    ) == .success, let text = textValue as? String,
      text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
    return sentenceFromOCRText(text, containing: word)
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
