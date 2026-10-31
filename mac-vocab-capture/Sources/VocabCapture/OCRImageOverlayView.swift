import AppKit

struct OCROverlayToken: Equatable, Sendable {
  let text: String
  let boundingBox: CGRect
  let confidence: Float
}

enum OCROverlayLayout {
  static let lowConfidenceThreshold: Float = 0.6
  static func imageRect(
    for imageSize: CGSize, in bounds: CGRect, scale: CGFloat = 1, offset: CGPoint = .zero
  ) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * fitScale * scale, height: imageSize.height * fitScale * scale)
    return CGRect(
      x: bounds.midX - size.width / 2 + offset.x,
      y: bounds.midY - size.height / 2 + offset.y,
      width: size.width, height: size.height)
  }

  static func rect(for normalized: CGRect, imageRect: CGRect) -> CGRect {
    CGRect(
      x: imageRect.minX + normalized.minX * imageRect.width,
      y: imageRect.minY + (1 - normalized.maxY) * imageRect.height,
      width: normalized.width * imageRect.width,
      height: normalized.height * imageRect.height)
  }

  static func selectedTokenIndices(
    tokens: [OCROverlayToken], imageRect: CGRect, selectionRect: CGRect, point: CGPoint
  ) -> [Int] {
    let isClick = selectionRect.width < 4 && selectionRect.height < 4
    let matches = tokens.enumerated().filter { _, token in
      let rect = rect(for: token.boundingBox, imageRect: imageRect)
      return isClick ? hitRect(for: rect).contains(point) : rect.intersects(selectionRect)
    }.sorted {
      if isClick {
        let a = rect(for: $0.element.boundingBox, imageRect: imageRect)
        let b = rect(for: $1.element.boundingBox, imageRect: imageRect)
        return a.distanceSquared(to: point) < b.distanceSquared(to: point)
      }
      return readingOrder(lhs: $0.element, rhs: $1.element)
    }.map(\.offset)
    return isClick ? Array(matches.prefix(1)) : matches
  }

  static func readingOrder(lhs: OCROverlayToken, rhs: OCROverlayToken) -> Bool {
    if abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY) > 0.02 {
      return lhs.boundingBox.maxY > rhs.boundingBox.maxY
    }
    return lhs.boundingBox.minX < rhs.boundingBox.minX
  }

  static func hitRect(for rect: CGRect, minimumSize: CGFloat = 12) -> CGRect {
    let dx = max(0, (minimumSize - rect.width) / 2)
    let dy = max(0, (minimumSize - rect.height) / 2)
    return rect.insetBy(dx: -dx, dy: -dy)
  }
}

private extension CGRect {
  func distanceSquared(to point: CGPoint) -> CGFloat {
    let dx = point.x - midX
    let dy = point.y - midY
    return dx * dx + dy * dy
  }
}

@MainActor
final class OCRImageOverlayView: NSView {
  var tokens: [OCROverlayToken] = [] {
    didSet {
      hoveredIndex = nil
      selectedIndices.removeAll()
      toolTip = "点击单词或拖选词组"
      needsDisplay = true
    }
  }
  var onSelection: ((String) -> Void)?
  var onSelectionWithIndices: ((String, [Int]) -> Void)?
  private let image: NSImage
  private var dragStart: CGPoint?
  private var dragCurrent: CGPoint?
  private var hoveredIndex: Int?
  private var selectedIndices: Set<Int> = []
  private var zoomScale: CGFloat = 1
  private var panOffset: CGPoint = .zero
  private var panStart: CGPoint?
  private var panOrigin: CGPoint = .zero

  init(image: NSImage, tokens: [OCROverlayToken]) {
    self.image = image
    self.tokens = tokens
    super.init(frame: .zero)
    wantsLayer = true
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self))
    addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:))))
    toolTip = "点击单词或拖选词组"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    let constrained = constrainedPanOffset(panOffset)
    if constrained != panOffset {
      panOffset = constrained
      needsDisplay = true
    }
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let becameFirstResponder = super.becomeFirstResponder()
    guard becameFirstResponder, hoveredIndex == nil, let first = tokens.indices.min(by: {
      OCROverlayLayout.readingOrder(lhs: tokens[$0], rhs: tokens[$1])
    }) else { return becameFirstResponder }
    hoveredIndex = first
    toolTip = tooltip(for: first)
    setAccessibilityValue(tokens[first].text)
    needsDisplay = true
    return becameFirstResponder
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let imageRect = currentImageRect()
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    for (index, token) in tokens.enumerated() {
      // Keep the source image legible; interaction states provide the stronger signal.
      let confidence = max(0.025, min(0.12, CGFloat(token.confidence) * 0.12))
      NSColor.systemBlue.withAlphaComponent(confidence).setFill()
      let rect = OCROverlayLayout.rect(for: token.boundingBox, imageRect: imageRect).insetBy(dx: -2, dy: -2)
      rect.fill()
      if selectedIndices.contains(index) {
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        rect.fill()
      }
      if token.confidence < OCROverlayLayout.lowConfidenceThreshold {
        NSColor.systemOrange.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        path.stroke()
      }
      if index == hoveredIndex || selectedIndices.contains(index) {
        NSColor.controlAccentColor.withAlphaComponent(index == hoveredIndex ? 0.8 : 0.55).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = index == hoveredIndex ? 2 : 1
        path.stroke()
      }
    }
    if let start = dragStart, let current = dragCurrent {
      NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
      NSBezierPath(rect: CGRect(
        x: min(start.x, current.x), y: min(start.y, current.y),
        width: abs(current.x - start.x), height: abs(current.y - start.y))).fill()
    }
    if zoomScale > 1.001 {
      let label = "\(Int((zoomScale * 100).rounded()))%"
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white,
      ]
      let textSize = (label as NSString).size(withAttributes: attributes)
      let badge = CGRect(
        x: bounds.maxX - textSize.width - 20, y: bounds.minY + 10,
        width: textSize.width + 12, height: textSize.height + 6)
      NSColor.black.withAlphaComponent(0.62).setFill()
      NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
      (label as NSString).draw(
        at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if zoomScale > 1, event.modifierFlags.contains(.option) {
      panStart = convert(event.locationInWindow, from: nil)
      panOrigin = panOffset
      NSCursor.closedHand.set()
      return
    }
    if event.clickCount == 2, zoomScale > 1 {
      setZoomScale(1)
      hoveredIndex = nil
      toolTip = "点击单词或拖选词组"
      setAccessibilityValue(nil)
      return
    }
    dragStart = convert(event.locationInWindow, from: nil)
    dragCurrent = dragStart
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    if let panStart {
      let point = convert(event.locationInWindow, from: nil)
      panOffset = constrainedPanOffset(CGPoint(
        x: panOrigin.x + point.x - panStart.x,
        y: panOrigin.y + point.y - panStart.y))
      needsDisplay = true
      return
    }
    dragCurrent = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    if panStart != nil {
      panStart = nil
      NSCursor.openHand.set()
      return
    }
    defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
    if event.clickCount == 2, zoomScale == 1 { return }
    let point = convert(event.locationInWindow, from: nil)
    let imageRect = currentImageRect()
    let selectionRect = CGRect(
      x: min(dragStart?.x ?? point.x, point.x), y: min(dragStart?.y ?? point.y, point.y),
      width: abs(point.x - (dragStart?.x ?? point.x)), height: abs(point.y - (dragStart?.y ?? point.y)))
    let indices = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: imageRect, selectionRect: selectionRect, point: point)
    selectedIndices = Set(indices)
    guard !indices.isEmpty else { return }
    emitSelection(indices)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, dragStart != nil {
      dragStart = nil
      dragCurrent = nil
      needsDisplay = true
      return
    }
    guard !tokens.isEmpty else { super.keyDown(with: event); return }
    if event.modifierFlags.contains(.command), event.keyCode == 8, !selectedIndices.isEmpty {
      copySelectedOCRText()
      return
    }
    if event.charactersIgnoringModifiers == "0" {
      setZoomScale(1)
      return
    }
    if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
      setZoomScale(zoomScale + 0.25)
      return
    }
    if event.charactersIgnoringModifiers == "-" || event.charactersIgnoringModifiers == "_" {
      setZoomScale(zoomScale - 0.25)
      return
    }
    let ordered = tokens.indices.sorted { OCROverlayLayout.readingOrder(lhs: tokens[$0], rhs: tokens[$1]) }
    switch event.keyCode {
    case 115, 119:
      let next = event.keyCode == 115 ? ordered.first! : ordered.last!
      hoveredIndex = next
      ensureTokenVisible(next)
      selectedIndices.removeAll()
      toolTip = tooltip(for: next)
      setAccessibilityValue(tokens[next].text)
      needsDisplay = true
    case 123, 124:
      let current = hoveredIndex.flatMap { ordered.firstIndex(of: $0) } ?? (event.keyCode == 123 ? 0 : -1)
      let next = max(0, min(ordered.count - 1, current + (event.keyCode == 123 ? -1 : 1)))
      hoveredIndex = ordered[next]
      ensureTokenVisible(ordered[next])
      selectedIndices.removeAll()
      toolTip = tooltip(for: ordered[next])
      setAccessibilityValue(tokens[ordered[next]].text)
      needsDisplay = true
    case 125, 126:
      let current = hoveredIndex ?? ordered.first!
      let currentBox = tokens[current].boundingBox
      let goingUp = event.keyCode == 126
      let candidates = tokens.indices.filter { index in
        guard index != current else { return false }
        let delta = tokens[index].boundingBox.midY - currentBox.midY
        return goingUp ? delta > 0.01 : delta < -0.01
      }
      if let next = candidates.min(by: { a, b in
        let aDelta = abs(tokens[a].boundingBox.midY - currentBox.midY)
        let bDelta = abs(tokens[b].boundingBox.midY - currentBox.midY)
        if abs(aDelta - bDelta) > 0.01 { return aDelta < bDelta }
        return abs(tokens[a].boundingBox.midX - currentBox.midX)
          < abs(tokens[b].boundingBox.midX - currentBox.midX)
      }) {
        hoveredIndex = next
        ensureTokenVisible(next)
        selectedIndices.removeAll()
        toolTip = tooltip(for: next)
        setAccessibilityValue(tokens[next].text)
        needsDisplay = true
      }
    case 36, 76:
      if let hoveredIndex { emitSelection([hoveredIndex]) }
    default:
      super.keyDown(with: event)
    }
  }

  private func emitSelection(_ indices: [Int]) {
    guard !indices.isEmpty else { return }
    selectedIndices = Set(indices)
    needsDisplay = true
    let text = indices.map { tokens[$0].text }.joined(separator: " ")
    setAccessibilityValue(text)
    onSelection?(text)
    onSelectionWithIndices?(text, indices)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let imageRect = currentImageRect()
    let next = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: imageRect, selectionRect: .zero, point: point).first
    updateCursor(hasToken: next != nil)
    guard next != hoveredIndex else { return }
    hoveredIndex = next
    toolTip = next.map(tooltip(for:)) ?? "点击单词或拖选词组"
    setAccessibilityValue(next.map { tokens[$0].text })
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    updateCursor(hasToken: false)
    hoveredIndex = nil
    toolTip = "点击单词或拖选词组"
    setAccessibilityValue(nil)
    needsDisplay = true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let index = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: currentImageRect(), selectionRect: .zero, point: point).first
    guard let index else { return nil }
    hoveredIndex = index
    selectedIndices = [index]
    setAccessibilityValue(tokens[index].text)
    let menu = NSMenu()
    menu.addItem(withTitle: "查询“\(tokens[index].text)”", action: #selector(queryContextToken), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "复制识别文字", action: #selector(copySelectedOCRText), keyEquivalent: "")
    menu.items.forEach { $0.target = self }
    return menu
  }

  @objc private func queryContextToken() {
    guard let index = selectedIndices.first else { return }
    emitSelection([index])
  }

  @objc private func copySelectedOCRText() {
    let ordered = selectedIndices.sorted { OCROverlayLayout.readingOrder(lhs: tokens[$0], rhs: tokens[$1]) }
    guard !ordered.isEmpty else { return }
    let text = ordered.map { tokens[$0].text }.joined(separator: " ")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    toolTip = "已复制：\(text)"
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  private func updateCursor(hasToken: Bool) {
    NSCursor.setHiddenUntilMouseMoves(false)
    (hasToken ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  override func scrollWheel(with event: NSEvent) {
    guard zoomScale > 1 else {
      super.scrollWheel(with: event)
      return
    }
    panOffset.x += event.scrollingDeltaX
    panOffset.y += event.scrollingDeltaY
    panOffset = constrainedPanOffset(panOffset)
    needsDisplay = true
  }

  @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
    let point = gesture.location(in: self)
    let oldRect = currentImageRect()
    let next = min(3, max(1, zoomScale * (1 + gesture.magnification)))
    guard abs(next - zoomScale) > 0.001 else { return }
    let imagePoint = CGPoint(
      x: (point.x - oldRect.minX) / max(oldRect.width, 1),
      y: (point.y - oldRect.minY) / max(oldRect.height, 1))
    setZoomScale(next)
    let centered = OCROverlayLayout.imageRect(for: image.size, in: bounds, scale: zoomScale)
    panOffset = constrainedPanOffset(CGPoint(
      x: point.x - centered.minX - imagePoint.x * centered.width,
      y: point.y - centered.minY - imagePoint.y * centered.height))
    gesture.magnification = 0
    needsDisplay = true
  }

  private func setZoomScale(_ value: CGFloat) {
    zoomScale = min(3, max(1, value))
    if zoomScale == 1 { panOffset = .zero }
    else { panOffset = constrainedPanOffset(panOffset) }
    needsDisplay = true
  }

  private func currentImageRect() -> CGRect {
    OCROverlayLayout.imageRect(for: image.size, in: bounds, scale: zoomScale, offset: panOffset)
  }

  private func ensureTokenVisible(_ index: Int) {
    guard zoomScale > 1, tokens.indices.contains(index) else { return }
    let rect = OCROverlayLayout.rect(for: tokens[index].boundingBox, imageRect: currentImageRect())
    var delta = CGPoint.zero
    if rect.minX < bounds.minX { delta.x = bounds.minX - rect.minX }
    else if rect.maxX > bounds.maxX { delta.x = bounds.maxX - rect.maxX }
    if rect.minY < bounds.minY { delta.y = bounds.minY - rect.minY }
    else if rect.maxY > bounds.maxY { delta.y = bounds.maxY - rect.maxY }
    guard delta != .zero else { return }
    panOffset = constrainedPanOffset(CGPoint(x: panOffset.x + delta.x, y: panOffset.y + delta.y))
  }

  private func constrainedPanOffset(_ offset: CGPoint) -> CGPoint {
    let centered = OCROverlayLayout.imageRect(for: image.size, in: bounds, scale: zoomScale)
    let maxX = max(0, (centered.width - bounds.width) / 2)
    let maxY = max(0, (centered.height - bounds.height) / 2)
    return CGPoint(
      x: min(max(offset.x, -maxX), maxX),
      y: min(max(offset.y, -maxY), maxY))
  }

  private func tooltip(for index: Int) -> String {
    tokens[index].confidence < OCROverlayLayout.lowConfidenceThreshold
      ? "选择：\(tokens[index].text)（识别置信度较低，请核对）"
      : "选择：\(tokens[index].text)"
  }
}
