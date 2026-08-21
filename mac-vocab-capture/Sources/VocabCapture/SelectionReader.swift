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
    let system = AXUIElementCreateSystemWide()
    var focusedApplication: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApplication) == .success,
          let app = focusedApplication else { return clipboardFallback() }

    let application = app as! AXUIElement
    var focusedElement: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
          let element = focusedElement else { return clipboardFallback() }

    var selectedText: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
          let text = selectedText as? String else { return clipboardFallback() }
    guard let selection = sanitize(text) else { return nil }
    return SelectedText(word: selection.word, context: sentenceContext(in: element as! AXUIElement, fallback: selection.context))
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

  private static func sentenceContext(in element: AXUIElement, fallback: String) -> String {
    var textValue: CFTypeRef?
    var rangeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue else { return fallback }
    guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return fallback }
    let axRange = unsafeBitCast(rangeValue, to: AXValue.self)

    var range = CFRange()
    guard AXValueGetValue(axRange, .cfRange, &range), range.location != kCFNotFound else { return fallback }
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue) == .success,
       let text = textValue as? String {
      return sentence(in: text, selectedRange: range, fallback: fallback)
    }

    // Browsers and PDF readers often deliberately omit AXValue for large text,
    // but still implement the parameterized range request. Ask only for the
    // small neighborhood around the selection, never for the whole document.
    var neighborhood = CFRange(location: max(0, range.location - 360), length: range.length + 720)
    guard let neighborhoodValue = AXValueCreate(.cfRange, &neighborhood) else { return fallback }
    var parameterizedText: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      neighborhoodValue,
      &parameterizedText
    ) == .success, let text = parameterizedText as? String else { return fallback }
    let relativeRange = CFRange(location: max(0, range.location - neighborhood.location), length: range.length)
    return sentence(in: text, selectedRange: relativeRange, fallback: fallback)
  }

  private static func sentence(in text: String, selectedRange: CFRange, fallback: String) -> String {
    let nsText = text as NSString
    guard selectedRange.location >= 0, selectedRange.location <= nsText.length else { return fallback }
    let isSeparator: (unichar) -> Bool = { character in
      character == 46 || character == 33 || character == 63 || character == 12290 || character == 65281 || character == 65311 || character == 10
    }
    var start = selectedRange.location
    var end = min(nsText.length, selectedRange.location + selectedRange.length)
    while start > 0, !isSeparator(nsText.character(at: start - 1)) { start -= 1 }
    while end < nsText.length, !isSeparator(nsText.character(at: end)) { end += 1 }
    if end < nsText.length { end += 1 }
    let sentence = nsText.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
    return sentence.isEmpty ? fallback : String(sentence.prefix(600))
  }
}
