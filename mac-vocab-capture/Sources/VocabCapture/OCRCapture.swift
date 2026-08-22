import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Vision

enum OCRCaptureError: LocalizedError {
  case permissionRequired
  case screenshotUnavailable
  case noTextFound

  var errorDescription: String? {
    switch self {
    case .permissionRequired: "请在系统设置中允许拾词助手进行屏幕录制，然后再试一次。"
    case .screenshotUnavailable: "无法读取当前屏幕。"
    case .noTextFound: "没有识别到英文文字，请框选得更紧一些。"
    }
  }
}

enum OCRClient {
  static func recognize(_ image: CGImage) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest { request, error in
          if let error { continuation.resume(throwing: error); return }
          let lines = (request.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          lines.isEmpty ? continuation.resume(throwing: OCRCaptureError.noTextFound) : continuation.resume(returning: lines)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(cgImage: image).perform([request])
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}

final class OCRSelectionWindow: NSWindow {
  private let screenshot: CGImage
  private let displayScale: CGSize
  private let completion: (CGImage) -> Void
  private let cancellation: () -> Void

  init(screen: NSScreen, screenshot: CGImage, completion: @escaping (CGImage) -> Void, cancellation: @escaping () -> Void) {
    self.screenshot = screenshot
    displayScale = CGSize(width: CGFloat(screenshot.width) / screen.frame.width, height: CGFloat(screenshot.height) / screen.frame.height)
    self.completion = completion
    self.cancellation = cancellation
    super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    ignoresMouseEvents = false
    hasShadow = false
    contentView = OCRSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), finish: { [weak self] selection in
      self?.finish(selection)
    }, cancel: { [weak self] in self?.cancel() })
  }

  private func finish(_ selection: NSRect) {
    let pixelRect = CGRect(
      x: selection.minX * displayScale.width,
      y: (frame.height - selection.maxY) * displayScale.height,
      width: selection.width * displayScale.width,
      height: selection.height * displayScale.height
    ).integral
    orderOut(nil)
    guard pixelRect.width > 8, pixelRect.height > 8, let crop = screenshot.cropping(to: pixelRect) else {
      cancellation()
      return
    }
    completion(crop)
  }

  private func cancel() {
    orderOut(nil)
    cancellation()
  }
}

private final class OCRSelectionView: NSView {
  private var start: NSPoint?
  private var selection: NSRect?
  private let finish: (NSRect) -> Void
  private let cancel: () -> Void

  init(frame: NSRect, finish: @escaping (NSRect) -> Void, cancel: @escaping () -> Void) {
    self.finish = finish
    self.cancel = cancel
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func mouseDown(with event: NSEvent) {
    start = convert(event.locationInWindow, from: nil)
    selection = nil
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    selection = NSRect(origin: start, size: .zero).union(NSRect(origin: convert(event.locationInWindow, from: nil), size: .zero))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let selection, selection.width > 8, selection.height > 8 else { cancel(); return }
    finish(selection)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) { cancel() }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.20).setFill()
    bounds.fill()
    guard let selection else { return }
    NSGraphicsContext.current?.compositingOperation = .clear
    NSBezierPath(rect: selection).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    NSColor.controlAccentColor.setStroke()
    let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
    border.lineWidth = 2
    border.stroke()
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
  }
}
