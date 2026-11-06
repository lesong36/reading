import AppKit

struct ScreenCaptureRegion: Equatable, Sendable {
  let screenFrame: CGRect
  let selectionRect: CGRect
  var sourceWindow: CapturedSourceWindow? = nil

  static func fromLocalSelection(_ selection: CGRect, screenFrame: CGRect) -> ScreenCaptureRegion? {
    let rect = selection.standardized.intersection(CGRect(origin: .zero, size: screenFrame.size))
    guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
    return ScreenCaptureRegion(screenFrame: screenFrame,
      selectionRect: rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
  }

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
  private var panels: [NSPanel] = []
  private var completion: ((ScreenCaptureRegion?) -> Void)?

  func present(on screen: NSScreen? = NSScreen.main, completion: @escaping (ScreenCaptureRegion?) -> Void) {
    present(screenFrames: NSScreen.screens.map(\.frame), preferredFrame: screen?.frame,
      completion: completion)
  }

  func present(screenFrames: [CGRect], preferredFrame: CGRect?,
    completion: @escaping (ScreenCaptureRegion?) -> Void) {
    guard panels.isEmpty, !screenFrames.isEmpty else { completion(nil); return }
    self.completion = completion
    for frame in screenFrames {
      let view = RegionSelectionView(frame: CGRect(origin: .zero, size: frame.size))
      view.onFinish = { [weak self] rect in self?.finish(rect, screenFrame: frame) }
      let panel = RegionSelectionPanel(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      panel.level = .screenSaver
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.ignoresMouseEvents = false
      panel.hidesOnDeactivate = false
      panel.setAccessibilityLabel("截图选区")
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.contentView = view
      panels.append(panel)
    }
    NSApp.activate(ignoringOtherApps: true)
    panels.forEach { $0.orderFrontRegardless() }
    let preferred = panels.first { $0.frame == preferredFrame } ?? panels[0]
    preferred.makeKeyAndOrderFront(nil)
    preferred.makeFirstResponder(preferred.contentView)
  }

  func cancel() { finish(nil, screenFrame: panels.first?.frame ?? .zero) }

  private func finish(_ selection: CGRect?, screenFrame: CGRect) {
    guard !panels.isEmpty else { return }
    panels.forEach { $0.orderOut(nil) }
    panels.removeAll()
    let result = selection.flatMap { ScreenCaptureRegion.fromLocalSelection($0, screenFrame: screenFrame) }
    let callback = completion
    completion = nil
    callback?(result)
  }
}

@MainActor
private final class RegionSelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
  var onFinish: ((CGRect?) -> Void)?
  private var start: CGPoint?
  private var current: CGPoint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let hint = NSTextField(labelWithString: "拖动框选截图区域 · 按 Esc 取消并返回问答")
    hint.font = .systemFont(ofSize: 18, weight: .medium)
    hint.textColor = .white
    hint.backgroundColor = NSColor.black.withAlphaComponent(0.8)
    hint.drawsBackground = true
    hint.alignment = .center
    hint.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hint)
    NSLayoutConstraint.activate([
      hint.centerXAnchor.constraint(equalTo: centerXAnchor),
      hint.topAnchor.constraint(equalTo: topAnchor, constant: 64),
      hint.heightAnchor.constraint(equalToConstant: 44),
      hint.widthAnchor.constraint(equalToConstant: 480),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

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

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeKey()
    window?.makeFirstResponder(self)
    start = convert(event.locationInWindow, from: nil)
    current = start
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    current = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    // Ignore the button/menu release that opened this overlay. A region can
    // finish only after its own mouseDown established the drag origin.
    guard start != nil else { return }
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
