import AppKit

struct OCROverlayToken: Equatable, Sendable {
  let text: String
  let boundingBox: CGRect
  let confidence: Float
}

enum OCROverlayLayout {
  static let lowConfidenceThreshold: Float = 0.6
  static func imageRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
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

  init(image: NSImage, tokens: [OCROverlayToken]) {
    self.image = image
    self.tokens = tokens
    super.init(frame: .zero)
    wantsLayer = true
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self))
    toolTip = "点击单词或拖选词组"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let imageRect = OCROverlayLayout.imageRect(for: image.size, in: bounds)
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    for (index, token) in tokens.enumerated() {
      let confidence = max(0.08, min(0.28, CGFloat(token.confidence) * 0.28))
      NSColor.systemBlue.withAlphaComponent(confidence).setFill()
      let rect = OCROverlayLayout.rect(for: token.boundingBox, imageRect: imageRect).insetBy(dx: -2, dy: -2)
      rect.fill()
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
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    dragStart = convert(event.locationInWindow, from: nil)
    dragCurrent = dragStart
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    dragCurrent = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
    let point = convert(event.locationInWindow, from: nil)
    let imageRect = OCROverlayLayout.imageRect(for: image.size, in: bounds)
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
    let ordered = tokens.indices.sorted { OCROverlayLayout.readingOrder(lhs: tokens[$0], rhs: tokens[$1]) }
    switch event.keyCode {
    case 123, 124:
      let current = hoveredIndex.flatMap { ordered.firstIndex(of: $0) } ?? (event.keyCode == 123 ? 0 : -1)
      let next = max(0, min(ordered.count - 1, current + (event.keyCode == 123 ? -1 : 1)))
      hoveredIndex = ordered[next]
      toolTip = tooltip(for: ordered[next])
      needsDisplay = true
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
    onSelection?(text)
    onSelectionWithIndices?(text, indices)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let imageRect = OCROverlayLayout.imageRect(for: image.size, in: bounds)
    let next = tokens.firstIndex {
      OCROverlayLayout.hitRect(
        for: OCROverlayLayout.rect(for: $0.boundingBox, imageRect: imageRect)).contains(point)
    }
    guard next != hoveredIndex else { return }
    hoveredIndex = next
    toolTip = next.map(tooltip(for:)) ?? "点击单词或拖选词组"
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hoveredIndex = nil
    toolTip = "点击单词或拖选词组"
    needsDisplay = true
  }

  private func tooltip(for index: Int) -> String {
    tokens[index].confidence < OCROverlayLayout.lowConfidenceThreshold
      ? "选择：\(tokens[index].text)（识别置信度较低，请核对）"
      : "选择：\(tokens[index].text)"
  }
}
