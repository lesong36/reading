import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class OCRImageOverlayViewTests: XCTestCase {
  func testAspectFitAndVisionBottomLeftCoordinateConversion() {
    let imageRect = OCROverlayLayout.imageRect(for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600))
    XCTAssertEqual(imageRect, CGRect(x: 0, y: 150, width: 600, height: 300))
    let token = OCROverlayLayout.rect(for: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2), imageRect: imageRect)
    XCTAssertEqual(token, CGRect(x: 60, y: 210, width: 120, height: 60))
  }

  func testImageOverlayAcceptsTokensAndUsesStableAspectFitFrame() {
    let image = NSImage(size: NSSize(width: 100, height: 50))
    let view = OCRImageOverlayView(image: image, tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    XCTAssertEqual(OCROverlayLayout.imageRect(for: image.size, in: view.bounds).size, CGSize(width: 300, height: 150))
    XCTAssertEqual(view.tokens.map(\.text), ["word"])
  }
}
