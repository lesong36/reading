import AppKit

struct OCROverlayToken: Equatable, Sendable {
  let text: String
  let boundingBox: CGRect
  let confidence: Float
}

enum OCROverlayLayout {
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
    tokens.enumerated().filter { _, token in
      let rect = rect(for: token.boundingBox, imageRect: imageRect)
      return selectionRect.width < 4 && selectionRect.height < 4
        ? rect.insetBy(dx: -4, dy: -4).contains(point)
        : rect.intersects(selectionRect)
    }.sorted {
      if abs($0.element.boundingBox.maxY - $1.element.boundingBox.maxY) > 0.02 {
        return $0.element.boundingBox.maxY > $1.element.boundingBox.maxY
      }
      return $0.element.boundingBox.minX < $1.element.boundingBox.minX
    }.map(\.offset)
  }
}

@MainActor
final class OCRImageOverlayView: NSView {
  var tokens: [OCROverlayToken] = [] { didSet { needsDisplay = true } }
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
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    toolTip = "点击单词或拖选词组"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let imageRect = OCROverlayLayout.imageRect(for: image.size, in: bounds)
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    for (index, token) in tokens.enumerated() {
      let confidence = max(0.08, min(0.28, CGFloat(token.confidence) * 0.28))
      NSColor.systemBlue.withAlphaComponent(confidence).setFill()
      let rect = OCROverlayLayout.rect(for: token.boundingBox, imageRect: imageRect).insetBy(dx: -2, dy: -2)
      rect.fill()
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
    let text = indices.map { tokens[$0].text }.joined(separator: " ")
    onSelection?(text)
    onSelectionWithIndices?(text, indices)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let imageRect = OCROverlayLayout.imageRect(for: image.size, in: bounds)
    let next = tokens.firstIndex {
      OCROverlayLayout.rect(for: $0.boundingBox, imageRect: imageRect).insetBy(dx: -4, dy: -4).contains(point)
    }
    guard next != hoveredIndex else { return }
    hoveredIndex = next
    toolTip = next.map { "选择：\(tokens[$0].text)" } ?? "点击单词或拖选词组"
    needsDisplay = true
  }
}
