import ApplicationServices
import AppKit
import Foundation

struct SelectedText: Sendable {
  let word: String
  let context: String
}

private final class SelectionCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum SelectionReader {
  private static let executor = DispatchQueue(label: "com.coty.vocab-capture.selection", qos: .userInitiated)
  static func readFocusedSelectionAsync(browserBridge: BrowserContextBridge = .shared) async -> SelectedText? {
    await readOnExecutor(includeClipboard: false, browserBridge: browserBridge)
  }
  static func readAsync(browserBridge: BrowserContextBridge = .shared) async -> SelectedText? {
    await readOnExecutor(includeClipboard: true, browserBridge: browserBridge)
  }
  private static func readOnExecutor(includeClipboard: Bool, browserBridge: BrowserContextBridge) async -> SelectedText? {
    let cancellation = SelectionCancellation()
    let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        executor.async {
          guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
          Thread.current.threadDictionary["vocabSelectionDeadline"] = ProcessInfo.processInfo.systemUptime + 0.45
          Thread.current.threadDictionary["vocabSelectionCancellation"] = cancellation
          defer {
            Thread.current.threadDictionary.removeObject(forKey: "vocabSelectionDeadline")
            Thread.current.threadDictionary.removeObject(forKey: "vocabSelectionCancellation")
          }
          let selected = includeClipboard ? read(browserBridge: browserBridge) : readFocusedSelection(browserBridge: browserBridge)
          guard !cancellation.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            continuation.resume(returning: nil); return
          }
          continuation.resume(returning: selected)
        }
      }
    }, onCancel: { cancellation.cancel() })
  }
  private static var withinBudget: Bool {
    if let cancellation = Thread.current.threadDictionary["vocabSelectionCancellation"] as? SelectionCancellation,
      cancellation.isCancelled { return false }
    return (Thread.current.threadDictionary["vocabSelectionDeadline"] as? Double).map { ProcessInfo.processInfo.systemUptime < $0 } ?? true
  }
  private static func copyAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    guard withinBudget else { return .cannotComplete }
    AXUIElementSetMessagingTimeout(element, 0.08)
    return AXUIElementCopyAttributeValue(element, attribute, value)
  }
  private static func copyParameterized(_ element: AXUIElement, _ attribute: CFString, _ parameter: CFTypeRef, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    guard withinBudget else { return .cannotComplete }
    AXUIElementSetMessagingTimeout(element, 0.08)
    return AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, value)
  }

  /// Uses Accessibility only after an explicit user action (service/hot key).
  /// It never polls the foreground application or records keystrokes.
  static func read(browserBridge: BrowserContextBridge = .shared) -> SelectedText? {
    readFocusedSelection(browserBridge: browserBridge) ?? clipboardFallback()
  }

  /// Reads only the active app's current selection. Used after the user drags
  /// to select text, so a stale clipboard value never creates a floating UI.
  static func readFocusedSelection(browserBridge: BrowserContextBridge = .shared) -> SelectedText? {
    let system = AXUIElementCreateSystemWide()
    var focusedApplication: CFTypeRef?
    guard copyAttribute(system, kAXFocusedApplicationAttribute as CFString, &focusedApplication) == .success,
          let app = focusedApplication else { return nil }

    let application = app as! AXUIElement
    var focusedElement: CFTypeRef?
    guard copyAttribute(application, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
          let element = focusedElement else { return nil }

    var selectedText: CFTypeRef?
    guard copyAttribute(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
          let text = selectedText as? String else { return nil }
    guard let selection = sanitize(text) else { return nil }
    ContextDebugLog.write("辅助功能读取到选区", word: selection.word, context: selection.context)
    if let browserContext = browserBridge.sentence(for: selection.word,
      browserBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
      ContextDebugLog.write("浏览器扩展缓存命中", word: selection.word, context: browserContext)
      return SelectedText(word: selection.word, context: browserContext)
    }
    let ancestors = accessibleAncestors(startingAt: element as! AXUIElement)
    let directContext = ancestors
      .lazy
      .compactMap { sentenceContext(in: $0) }
      .first(where: { isUsableSentence($0, containing: selection.word) }) ?? selection.context
    let selectionBounds = ancestors.lazy.compactMap { selectedTextBounds(in: $0) }.first
    ContextDebugLog.write(
      "辅助功能选区位置：\(selectionBounds.map { NSStringFromRect($0) } ?? "未提供")；祖先节点数：\(ancestors.count)",
      word: selection.word
    )
    if ContextDebugLog.isRawDiagnosticsEnabled { logAccessibilityAncestors(ancestors, word: selection.word) }
    let context = isUsableSentence(directContext, containing: selection.word)
      ? directContext
      : selectionBounds.flatMap { nearbyTextSentence(in: Array(ancestors.prefix(5)), containing: selection.word, around: $0) } ?? selection.context
    ContextDebugLog.write(
      selectionBounds == nil ? "未取得选区位置，无法按上下左右定位" : "已按选区位置定位附近文本",
      word: selection.word,
      context: context
    )
    return SelectedText(word: selection.word, context: context)
  }

  private static func clipboardFallback() -> SelectedText? {
    sanitize(NSPasteboard.general.string(forType: .string) ?? "")
  }

  private static func sanitize(_ input: String) -> SelectedText? {
    guard let word = SelectionTextContract.phrase(input) else { return nil }
    return SelectedText(word: word, context: SelectionTextContract.normalized(input))
  }

  static func fromServicePasteboard(_ pasteboard: NSPasteboard) -> SelectedText? {
    sanitize(pasteboard.string(forType: .string) ?? "")
  }

  static func fromBrowserExtension(word: String, context: String) -> SelectedText? {
    guard let selection = sanitize(word) else { return nil }
    let sentence = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard sentence.count > selection.word.count,
          sentence.count <= 800,
          SelectionTextContract.match(selection.word, in: sentence) != nil else { return nil }
    return SelectedText(word: selection.word, context: sentence)
  }

  /// OCR commonly wraps one sentence across multiple visual lines. Normalize
  /// those wraps first, then retain the full grammatical sentence containing
  /// the selected word or phrase instead of passing the whole screenshot.
  static func sentenceFromOCRText(_ text: String, containing word: String) -> String {
    let normalized = SelectionTextContract.normalized(text)
    guard let range = SelectionTextContract.match(word, in: normalized) else { return String(normalized.prefix(800)) }
    return SelectionTextContract.sentence(normalized, selectedRange: range) ?? String(normalized.prefix(800))
  }

  private static func accessibleAncestors(startingAt element: AXUIElement) -> [AXUIElement] {
    var result = [element]
    var current = element
    for _ in 0..<10 {
      var parentValue: CFTypeRef?
      guard copyAttribute(current, kAXParentAttribute as CFString, &parentValue) == .success,
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
    guard copyAttribute(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue else { return nil }
    guard CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    let axRange = unsafeBitCast(rangeValue, to: AXValue.self)

    var range = CFRange()
    guard AXValueGetValue(axRange, .cfRange, &range), range.location != kCFNotFound else { return nil }
    var candidates: [String] = []
    if copyAttribute(element, kAXValueAttribute as CFString, &textValue) == .success,
       let text = textValue as? String,
       let valueSentence = sentence(in: text, selectedRange: range) {
      candidates.append(valueSentence)
    }

    // Safari can expose a selected phrase through a leaf whose AXValue starts
    // after the beginning of its visual sentence. Its parameterized range is
    // usually wider, so collect both forms and retain the fuller sentence.
    // Browsers and PDF readers can omit AXValue entirely but still implement
    // this small neighborhood request.
    var neighborhood = CFRange(location: max(0, range.location - 360), length: range.length + 720)
    if let neighborhoodValue = AXValueCreate(.cfRange, &neighborhood),
       let text = textForRange(in: element, rangeValue: neighborhoodValue) {
      let relativeRange = CFRange(location: max(0, range.location - neighborhood.location), length: range.length)
      if let rangeSentence = sentence(in: text, selectedRange: relativeRange) {
        candidates.append(rangeSentence)
      }
    }
    return candidates.max(by: { $0.count < $1.count })
  }

  private static func selectedTextBounds(in element: AXUIElement) -> CGRect? {
    var rangeValue: CFTypeRef?
    guard copyAttribute(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
          let rangeValue,
          CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
    var boundsValue: CFTypeRef?
    guard copyParameterized(
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
    while withinBudget, let next = pending.popLast(), visited < 160 {
      visited += 1
      if let text = readableText(in: next.element), text.count > word.count,
         text.count <= 1_500,
         text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
         let bounds = elementBounds(of: next.element) {
        let sentence = sentenceFromOCRText(text, containing: word)
        let distance = rectangleDistance(from: selectionBounds, to: bounds)
        ContextDebugLog.write(
          "附近命中文本节点：角色 \(role(of: next.element))；距离 \(Int(distance))；句子有效 \(isUsableSentence(sentence, containing: word))",
          word: word,
          context: text
        )
        if isUsableSentence(sentence, containing: word) {
          candidates.append((sentence, distance))
        }
      }
      guard next.depth < 6 else { continue }
      var childrenValue: CFTypeRef?
      if copyAttribute(next.element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
         let children = childrenValue as? [AXUIElement] {
        pending.append(contentsOf: children.map { ($0, next.depth + 1) })
      }
    }
    let result = candidates.min { lhs, rhs in
      lhs.distance == rhs.distance ? lhs.sentence.count < rhs.sentence.count : lhs.distance < rhs.distance
    }?.sentence
    ContextDebugLog.write("附近节点扫描结束：访问 \(visited) 个节点，完整句候选 \(candidates.count) 个", word: word, context: result)
    return result
  }

  private static func logAccessibilityAncestors(_ ancestors: [AXUIElement], word: String) {
    for (index, element) in ancestors.prefix(5).enumerated() {
      var childrenValue: CFTypeRef?
      let childCount: Int
      if copyAttribute(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
         let children = childrenValue as? [AXUIElement] {
        childCount = children.count
      } else {
        childCount = 0
      }
      ContextDebugLog.write("祖先节点 #\(index)：角色 \(role(of: element))；子节点 \(childCount)", word: word)
    }
  }

  private static func role(of element: AXUIElement) -> String {
    var roleValue: CFTypeRef?
    guard copyAttribute(element, kAXRoleAttribute as CFString, &roleValue) == .success,
          let role = roleValue as? String else { return "未知" }
    return role
  }

  private static func elementBounds(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard copyAttribute(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          copyAttribute(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
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
      guard copyAttribute(element, attribute as CFString, &value) == .success,
            let text = value as? String else { continue }
      let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty, normalized.count <= 8_000 { return normalized }
    }
    return nil
  }

  private static func textForRange(in element: AXUIElement, rangeValue: AXValue) -> String? {
    var textValue: CFTypeRef?
    if copyParameterized(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      rangeValue,
      &textValue
    ) == .success, let text = textValue as? String {
      return text
    }
    if copyParameterized(
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
    SelectionTextContract.sentence(text, selectedRange: NSRange(location: selectedRange.location, length: selectedRange.length))
  }
}
