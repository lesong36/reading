import AppKit
import XCTest

@testable import VocabCapture

final class ScreenRegionTests: XCTestCase {
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
}
