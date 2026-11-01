import AppKit
import XCTest

@testable import VocabCapture

final class ScreenRegionTests: XCTestCase {
  @MainActor
  func testLiveRegionCaptureOnEveryConnectedDisplay() async throws {
    guard ProcessInfo.processInfo.environment["VOCAB_LIVE_CAPTURE_TEST"] == "1" else {
      throw XCTSkip("Opt-in screen recording integration test")
    }
    let capture = ScreenshotRegionCapture()
    for screen in NSScreen.screens {
      let region = try XCTUnwrap(ScreenCaptureRegion.fromLocalSelection(
        CGRect(x: 100, y: 100, width: 240, height: 160), screenFrame: screen.frame))
      let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
        capture.capture(region: region) { continuation.resume(with: $0.mapError { $0 as Error }) }
      }
      XCTAssertGreaterThan(try XCTUnwrap(image).width, 0)
      XCTAssertGreaterThan(try XCTUnwrap(image).height, 0)
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
