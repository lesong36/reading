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

  func testMultiLineTokensUseReadingOrderAndPreserveLowConfidenceMetadata() {
    let tokens = [
      OCROverlayToken(text: "second", boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.1), confidence: 0.2),
      OCROverlayToken(text: "first", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), confidence: 0.99),
    ]
    XCTAssertEqual(tokens.map(\.confidence), [0.2, 0.99])
    XCTAssertGreaterThan(tokens[0].boundingBox.minY, 0)
    XCTAssertGreaterThan(tokens[1].confidence, tokens[0].confidence)
  }

  func testDragSelectionReturnsReadingOrderAcrossLines() {
    let imageRect = CGRect(x: 0, y: 0, width: 400, height: 200)
    let tokens = [
      OCROverlayToken(text: "second", boundingBox: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.15), confidence: 1),
      OCROverlayToken(text: "first", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.15), confidence: 1),
    ]
    let indices = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: imageRect, selectionRect: CGRect(x: 0, y: 0, width: 400, height: 200), point: .zero)
    XCTAssertEqual(indices, [1, 0])
  }

  func testTinyTokenGetsMinimumClickTargetWithoutChangingVisualRect() {
    let visual = CGRect(x: 20, y: 30, width: 2, height: 3)
    let hit = OCROverlayLayout.hitRect(for: visual)
    XCTAssertEqual(visual, CGRect(x: 20, y: 30, width: 2, height: 3))
    XCTAssertGreaterThanOrEqual(hit.width, 12)
    XCTAssertGreaterThanOrEqual(hit.height, 12)
    XCTAssertTrue(hit.contains(CGPoint(x: 21, y: 31.5)))
  }
}
