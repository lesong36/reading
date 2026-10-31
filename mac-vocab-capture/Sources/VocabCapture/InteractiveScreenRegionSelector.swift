import AppKit

struct ScreenCaptureRegion: Equatable, Sendable {
  let screenFrame: CGRect
  let selectionRect: CGRect

  var normalizedSelection: CGRect {
    guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
    return CGRect(
      x: (selectionRect.minX - screenFrame.minX) / screenFrame.width,
      y: (selectionRect.minY - screenFrame.minY) / screenFrame.height,
      width: selectionRect.width / screenFrame.width,
      height: selectionRect.height / screenFrame.height)
  }
}

@MainActor
protocol ScreenRegionSelecting: AnyObject {
  func present(on screen: NSScreen?, completion: @escaping (ScreenCaptureRegion?) -> Void)
}

@MainActor
final class InteractiveScreenRegionSelector: ScreenRegionSelecting {
  private var panel: NSPanel?
  private var completion: ((ScreenCaptureRegion?) -> Void)?

  func present(on screen: NSScreen? = NSScreen.main, completion: @escaping (ScreenCaptureRegion?) -> Void) {
    guard panel == nil, let screen else { completion(nil); return }
    self.completion = completion
    let view = RegionSelectionView(frame: screen.frame)
    view.onFinish = { [weak self] rect in self?.finish(rect, screenFrame: screen.frame) }
    let panel = NSPanel(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = view
    self.panel = panel
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
  }

  func cancel() { finish(nil, screenFrame: panel?.frame ?? .zero) }

  private func finish(_ selection: CGRect?, screenFrame: CGRect) {
    guard panel != nil else { return }
    panel?.orderOut(nil)
    panel = nil
    let result = selection.flatMap { rect -> ScreenCaptureRegion? in
      let normalized = rect.standardized.intersection(screenFrame)
      guard normalized.width >= 2, normalized.height >= 2 else { return nil }
      return ScreenCaptureRegion(screenFrame: screenFrame, selectionRect: normalized)
    }
    let callback = completion
    completion = nil
    callback?(result)
  }
}

@MainActor
private final class RegionSelectionView: NSView {
  var onFinish: ((CGRect?) -> Void)?
  private var start: CGPoint?
  private var current: CGPoint?

  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.12).setFill()
    bounds.fill()
    if let start, let current {
      let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                        width: abs(current.x - start.x), height: abs(current.y - start.y))
      NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
      rect.fill()
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 2
      path.stroke()
    }
  }

  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    current = start
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    current = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    current = convert(event.locationInWindow, from: nil)
    let rect = start.flatMap { start in
      CGRect(x: min(start.x, current?.x ?? start.x), y: min(start.y, current?.y ?? start.y),
             width: abs((current?.x ?? start.x) - start.x), height: abs((current?.y ?? start.y) - start.y))
    }
    onFinish?(rect)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onFinish?(nil); return }
    super.keyDown(with: event)
  }
}
