import AppKit
import XCTest

@testable import VocabCapture

final class ScreenRegionTests: XCTestCase {
  @MainActor
  func testSelectionOnAnotherDisplayUsesThatDisplayAndClosesAllOverlays() throws {
    _ = NSApplication.shared
    let frames = [CGRect(x: 0, y: 0, width: 900, height: 700),
      CGRect(x: -800, y: -200, width: 800, height: 600),
      CGRect(x: 900, y: 100, width: 700, height: 500)]
    let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
    let selector = InteractiveScreenRegionSelector()
    var results: [ScreenCaptureRegion?] = []
    selector.present(screenFrames: frames, preferredFrame: frames[0]) { results.append($0) }
    defer { selector.cancel() }
    let overlays = NSApp.windows.filter { !previous.contains(ObjectIdentifier($0)) && $0.isVisible }
    XCTAssertEqual(Set(overlays.map(\.frame)), Set(frames))
    let other = try XCTUnwrap(overlays.first { $0.frame == frames[1] })
    let view = try XCTUnwrap(other.contentView)
    XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: 0, windowNumber: other.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 20, y: 30)))
    view.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 220, y: 180)))
    view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 220, y: 180)))
    let result = try XCTUnwrap(results.first.flatMap { $0 })
    XCTAssertEqual(result.screenFrame, frames[1])
    XCTAssertEqual(result.selectionRect, CGRect(x: -780, y: -170, width: 200, height: 150))
    XCTAssertTrue(overlays.allSatisfy { !$0.isVisible })
    selector.cancel()
    XCTAssertEqual(results.count, 1)
  }

  @MainActor
  func testRegionSelectorOwnsKeyboardAndExplainsHiddenQuestionWindow() throws {
    _ = NSApplication.shared
    let selector = InteractiveScreenRegionSelector()
    var cancelled = false
    selector.present(on: try XCTUnwrap(NSScreen.main)) { cancelled = $0 == nil }
    defer { selector.cancel() }
    let panel = try XCTUnwrap(NSApp.windows.first { $0.level == .screenSaver && $0.isVisible })
    XCTAssertTrue(panel.canBecomeKey, "Borderless selectors must explicitly accept Escape and keyboard focus")
    XCTAssertFalse(panel.hidesOnDeactivate, "Switching app focus must not hide the only selection UI")
    XCTAssertEqual(panel.accessibilityLabel(), "截图选区")
    let labels = panel.contentView?.subviews.compactMap { $0 as? NSTextField } ?? []
    XCTAssertTrue(labels.contains { $0.stringValue.contains("拖动") && $0.stringValue.contains("Esc") })
    let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 40, y: 40),
      modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 0))
    panel.contentView?.mouseUp(with: release)
    XCTAssertFalse(cancelled, "The release that opened the selector must not immediately cancel it")
    XCTAssertTrue(panel.isVisible)
    selector.cancel()
    XCTAssertTrue(cancelled)
  }

  @MainActor
  func testLiveCaptureRemainsStableWhenScreenDoesNotChange() async throws {
    guard ProcessInfo.processInfo.environment["VOCAB_LIVE_STABILITY_TEST"] == "1" else {
      throw XCTSkip("Opt-in live screen stability validation")
    }
    guard #available(macOS 14.0, *) else { throw XCTSkip("Requires ScreenCaptureKit screenshots") }
    let screen = try XCTUnwrap(NSScreen.screens.last)
    let local = CGRect(x: screen.frame.width / 2 - 120, y: screen.frame.height / 2 - 80,
      width: 240, height: 160)
    let region = try XCTUnwrap(ScreenCaptureRegion.fromLocalSelection(local, screenFrame: screen.frame))
    let capture = ScreenshotRegionCapture()
    let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
      capture.capture(region: region) { continuation.resume(with: $0.mapError { $0 as Error }) }
    }
    var changes = 0
    let baselineImage = try XCTUnwrap(image)
    let monitor = ScreenContentMonitor(region: region, original: baselineImage) { changes += 1 }
    defer { monitor.stop() }
    let current = try await monitor.capture()
    let baseline = try XCTUnwrap(ScreenContentMonitor.signature(baselineImage))
    let signature = try XCTUnwrap(ScreenContentMonitor.signature(current))
    XCTAssertFalse(ScreenContentMonitor.changed(baseline, signature))
    monitor.start()
    try await Task.sleep(nanoseconds: 2_000_000_000)
    XCTAssertEqual(changes, 0, "Unchanged screen content should not dismiss the OCR layer")
  }

  @MainActor
  func testRenderedPDFScrollAndPageChangeTriggerContentInvalidation() throws {
    guard let firstPath = ProcessInfo.processInfo.environment["VOCAB_PDF_PAGE_1"],
      let secondPath = ProcessInfo.processInfo.environment["VOCAB_PDF_PAGE_2"] else {
      throw XCTSkip("Opt-in rendered PDF validation")
    }
    func image(_ path: String) throws -> CGImage {
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
      return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    let first = try image(firstPath)
    let second = try image(secondPath)
    let rect = CGRect(x: 100, y: 200, width: 700, height: 500)
    let baseline = try XCTUnwrap(ScreenContentMonitor.signature(try XCTUnwrap(first.cropping(to: rect))))
    let unchanged = try XCTUnwrap(ScreenContentMonitor.signature(try XCTUnwrap(first.cropping(to: rect))))
    let scrolled = try XCTUnwrap(ScreenContentMonitor.signature(
      try XCTUnwrap(first.cropping(to: rect.offsetBy(dx: 0, dy: 2)))))
    let nextPage = try XCTUnwrap(ScreenContentMonitor.signature(try XCTUnwrap(second.cropping(to: rect))))
    XCTAssertFalse(ScreenContentMonitor.changed(baseline, unchanged))
    XCTAssertTrue(ScreenContentMonitor.changed(baseline, scrolled))
    XCTAssertTrue(ScreenContentMonitor.changed(baseline, nextPage))
  }

  @MainActor
  func testContentComparisonDistinguishesPageChangeFromSmallRenderingNoise() {
    let original = [UInt8](repeating: 230, count: 10_000)
    var noise = original
    for index in 0..<200 { noise[index] = 220 }
    XCTAssertFalse(ScreenContentMonitor.changed(original, noise))
    var newPage = original
    for index in 0..<1_000 { newPage[index] = 80 }
    XCTAssertTrue(ScreenContentMonitor.changed(original, newPage))
  }

  @MainActor
  func testSourceWindowChangeDismissesOverlayAndNotifiesOnce() async throws {
    var valid = true
    let overlay = try makeTrackedOverlay { valid }
    var closes = 0
    overlay.onClose = { closes += 1 }
    overlay.present()
    XCTAssertTrue(overlay.isVisible)
    valid = false
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertFalse(overlay.isVisible)
    overlay.validateSource()
    overlay.close()
    XCTAssertEqual(closes, 1)
  }

  @MainActor
  func testSourceChangedDuringOCRNeverShowsStaleOverlay() throws {
    let overlay = try makeTrackedOverlay { false }
    var closes = 0
    overlay.onClose = { closes += 1 }
    overlay.present()
    XCTAssertFalse(overlay.isVisible)
    XCTAssertEqual(closes, 1)
  }

  @MainActor
  func testSwitchingAwayDismissesOverlay() throws {
    let overlay = try makeTrackedOverlay { true }
    overlay.present()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    XCTAssertFalse(overlay.isVisible)
  }

  @MainActor
  private func makeTrackedOverlay(valid: @escaping () -> Bool) throws -> ScreenOCROverlayWindow {
    _ = NSApplication.shared
    let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 60,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    let frame = CGRect(x: 100, y: 100, width: 100, height: 60)
    return ScreenOCROverlayWindow(image: image,
      region: ScreenCaptureRegion(screenFrame: frame, selectionRect: frame), tokens: [],
      sourceIsValid: valid)
  }

  @MainActor
  func testLiveRegionCaptureOnEveryConnectedDisplay() async throws {
    guard ProcessInfo.processInfo.environment["VOCAB_LIVE_CAPTURE_TEST"] == "1" else {
      throw XCTSkip("Opt-in screen recording integration test")
    }
    let capture = ScreenshotRegionCapture()
    print("LIVE_CAPTURE_DISPLAY_COUNT: \(NSScreen.screens.count)")
    for screen in NSScreen.screens {
      let region = try XCTUnwrap(ScreenCaptureRegion.fromLocalSelection(
        CGRect(x: 100, y: 100, width: 240, height: 160), screenFrame: screen.frame))
      let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
        capture.capture(region: region) { continuation.resume(with: $0.mapError { $0 as Error }) }
      }
      XCTAssertGreaterThan(try XCTUnwrap(image).width, 0)
      XCTAssertGreaterThan(try XCTUnwrap(image).height, 0)
      print("LIVE_CAPTURE_DISPLAY: \(screen.frame) -> \(try XCTUnwrap(image).width)x\(try XCTUnwrap(image).height)")
    }
  }

  @MainActor
  func testSelectionAndCaptureCoordinatesOnUpperLeftDisplay() throws {
    let screen = CGRect(x: -883, y: 1653, width: 3840, height: 2160)
    let region = try XCTUnwrap(ScreenCaptureRegion.fromLocalSelection(
      CGRect(x: 100, y: 200, width: 600, height: 300), screenFrame: screen))
    XCTAssertEqual(region.selectionRect, CGRect(x: -783, y: 1853, width: 600, height: 300))
    XCTAssertEqual(ScreenshotRegionCapture.sourceRect(for: region),
      CGRect(x: 100, y: 1660, width: 600, height: 300))
  }

  @MainActor
  func testSelectionClipsInLocalCoordinatesBeforeConvertingToScreen() throws {
    let screen = CGRect(x: 1920, y: -500, width: 1000, height: 800)
    let region = try XCTUnwrap(ScreenCaptureRegion.fromLocalSelection(
      CGRect(x: -20, y: 700, width: 200, height: 200), screenFrame: screen))
    XCTAssertEqual(region.selectionRect, CGRect(x: 1920, y: 200, width: 180, height: 100))
    XCTAssertEqual(ScreenshotRegionCapture.sourceRect(for: region),
      CGRect(x: 0, y: 0, width: 180, height: 100))
    XCTAssertNil(ScreenCaptureRegion.fromLocalSelection(.zero, screenFrame: screen))
  }

  func testNormalizedSelectionUsesScreenFrameCoordinates() {
    let region = ScreenCaptureRegion(
      screenFrame: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
      selectionRect: CGRect(x: 2_400, y: 270, width: 960, height: 540))

    XCTAssertEqual(region.normalizedSelection.origin.x, 0.25, accuracy: 0.0001)
    XCTAssertEqual(region.normalizedSelection.origin.y, 0.25, accuracy: 0.0001)
    XCTAssertEqual(region.normalizedSelection.size.width, 0.5, accuracy: 0.0001)
    XCTAssertEqual(region.normalizedSelection.size.height, 0.5, accuracy: 0.0001)
  }

  func testNormalizedSelectionReturnsZeroForInvalidScreenFrame() {
    let region = ScreenCaptureRegion(
      screenFrame: .zero,
      selectionRect: CGRect(x: 10, y: 10, width: 20, height: 20))

    XCTAssertEqual(region.normalizedSelection, .zero)
  }

  @MainActor
  func testOriginalPositionOCRLayerIsOrderedVisibleEvenWithoutRecognizedTokens() throws {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
    let image = try XCTUnwrap(context.makeImage())
    let frame = CGRect(x: 100, y: 100, width: 100, height: 60)
    let overlay = ScreenOCROverlayWindow(
      image: image,
      region: ScreenCaptureRegion(screenFrame: frame, selectionRect: frame),
      tokens: [])
    defer { overlay.close() }

    overlay.present()

    XCTAssertTrue(overlay.isVisible)
  }
}
