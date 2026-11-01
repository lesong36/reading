import AppKit

@MainActor
final class ScreenOCROverlayWindow {
  private var panel: NSPanel?
  private var closeDelegate: CloseDelegate?
  private let region: ScreenCaptureRegion
  private let image: NSImage
  private let tokens: [OCROverlayToken]
  var onSelection: ((String, [Int]) -> Void)?
  var onClose: (() -> Void)?
  var isVisible: Bool { panel?.isVisible == true }

  init(image: CGImage, region: ScreenCaptureRegion, tokens: [OCROverlayToken]) {
    self.region = region
    self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    self.tokens = tokens
  }

  func present() {
    guard panel == nil else { return }
    // The captured screen remains visible underneath. This window is only the
    // OCR interaction layer, so it never obscures the original reading surface.
    let view = OCRImageOverlayView(image: image, tokens: tokens, drawsSourceImage: false)
    view.onCancel = { [weak self] in self?.close() }
    view.onSelectionWithIndices = { [weak self] text, indices in
      self?.onSelection?(text, indices)
    }
    view.setAccessibilityRole(.image)
    view.setAccessibilityLabel("原位置截图文字选择层")
    view.setAccessibilityHelp("点击或拖选原位置文字；按住 Shift 连续选词；按回车确认；Escape 关闭选择层。")
    view.translatesAutoresizingMaskIntoConstraints = false
    let panel = NSPanel(
      contentRect: region.selectionRect, styleMask: [.borderless], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = view
    let closeDelegate = CloseDelegate { [weak self] in self?.close() }
    panel.delegate = closeDelegate
    self.closeDelegate = closeDelegate
    self.panel = panel
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
  }

  func close() {
    guard panel != nil else { return }
    panel?.orderOut(nil)
    panel = nil
    closeDelegate = nil
    onClose?()
  }
}

private final class CloseDelegate: NSObject, NSWindowDelegate {
  let action: () -> Void
  init(action: @escaping () -> Void) { self.action = action }
  func windowWillClose(_ notification: Notification) { action() }
}
