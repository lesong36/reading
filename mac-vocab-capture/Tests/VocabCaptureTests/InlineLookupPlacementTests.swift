import AppKit
import XCTest
@testable import VocabCapture

final class InlineLookupPlacementTests: XCTestCase {
  func testDenseParagraphPlacesCardOutsideTextWhileStayingOnScreen() {
    let capture = CGRect(x: 100, y: 300, width: 900, height: 500)
    let anchor = CGRect(x: 400, y: 500, width: 100, height: 30)
    let size = CGSize(width: 340, height: 240)
    let visible = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    let origin = InlineLookupPlacement.origin(size: size, anchor: anchor,
      occupied: [capture], capture: capture, visible: visible)
    let card = CGRect(origin: origin, size: size)
    XCTAssertFalse(card.intersects(capture))
    XCTAssertTrue(visible.contains(card))
  }

  func testSingleWordUsesNearbyWhitespaceOnNegativeOriginDisplay() {
    let anchor = CGRect(x: -700, y: 1900, width: 100, height: 30)
    let visible = CGRect(x: -883, y: 1653, width: 2000, height: 1200)
    let size = CGSize(width: 340, height: 240)
    let card = CGRect(origin: InlineLookupPlacement.origin(size: size, anchor: anchor,
      occupied: [anchor], capture: visible, visible: visible), size: size)
    XCTAssertFalse(card.intersects(anchor))
    XCTAssertTrue(visible.contains(card))
    XCTAssertLessThan(abs(card.minY - anchor.maxY), 20)
  }
}
