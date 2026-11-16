import XCTest
@testable import VocabCapture
final class CaptureGestureTests: XCTestCase {
  private func points(_ n: Int, offset: Double = 0) -> [CaptureGesture.Point] {
    (0..<n).map { .init(id: $0, x: Double($0) * 0.1 + offset, y: 0.5) }
  }
  func testDoubleTapsAndCooldown() {
    for n in [3, 4] {
      var g = CaptureGesture()
      XCTAssertNil(g.consume(points(1), timestamp: 1))
      XCTAssertNil(g.consume(points(n), timestamp: 1.02))
      XCTAssertNil(g.consume([], timestamp: 1.1))
      XCTAssertNil(g.consume(points(n), timestamp: 1.2))
      XCTAssertEqual(g.consume([], timestamp: 1.3), n == 3 ? .left : .right)
      XCTAssertNil(g.consume(points(n), timestamp: 1.4))
      XCTAssertNil(g.consume([], timestamp: 1.5))
    }
  }
  func testRejectsMovementWrongCountAndTimeout() {
    var g = CaptureGesture()
    _ = g.consume(points(3), timestamp: 1)
    _ = g.consume(points(3, offset: 0.1), timestamp: 1.05)
    XCTAssertNil(g.consume([], timestamp: 1.1))
    _ = g.consume(points(3), timestamp: 1.2)
    XCTAssertNil(g.consume([], timestamp: 1.3))
    _ = g.consume(points(3), timestamp: 3)
    XCTAssertNil(g.consume([], timestamp: 3.1))
    _ = g.consume(points(4), timestamp: 3.2)
    XCTAssertNil(g.consume([], timestamp: 3.3))
    _ = g.consume(points(2), timestamp: 3.4)
    XCTAssertNil(g.consume([], timestamp: 3.5))
  }
  func testStaggeredLiftUsesPeakCountAndLongHoldClearsPending() {
    var g = CaptureGesture()
    _ = g.consume(points(4), timestamp: 1)
    _ = g.consume(points(3), timestamp: 1.05)
    XCTAssertNil(g.consume([], timestamp: 1.1))
    _ = g.consume(points(4), timestamp: 1.2)
    _ = g.consume(points(1), timestamp: 1.25)
    XCTAssertEqual(g.consume([], timestamp: 1.3), .right)
    _ = g.consume(points(3), timestamp: 2)
    XCTAssertNil(g.consume([], timestamp: 3))
    _ = g.consume(points(3), timestamp: 3.1)
    XCTAssertNil(g.consume([], timestamp: 3.2))
  }

}
