import Foundation
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionPerformanceTests: XCTestCase {
  func testUsageRetainsExactReportedCountsIncludingZeroAndReasoning() throws {
    let usage = try XCTUnwrap(
      ScreenshotQuestionUsage.decode(
        ["input_tokens": 100, "output_tokens": 0, "reasoning_tokens": 0]))
    XCTAssertEqual(
      usage, ScreenshotQuestionUsage(inputTokens: 100, outputTokens: 0, reasoningTokens: 0))
    XCTAssertEqual(
      ScreenshotQuestionUsage.decode(["output_tokens": 20]),
      ScreenshotQuestionUsage(outputTokens: 20))
  }

  func testMalformedUsageDoesNotBecomeInventedTokenCounts() {
    for value: Any in [
      ["output_tokens": true], ["output_tokens": -1], ["output_tokens": 1.5],
      ["output_tokens": 4.0],
      ["output_tokens": "10"], ["output_tokens": NSNull()],
      ["input_tokens": 5, "output_tokens": false],
      ["output_tokens": UInt64.max], [:], "missing",
    ] {
      XCTAssertNil(ScreenshotQuestionUsage.decode(value), "Invalid usage: \(value)")
    }
  }

  func testFirstVisibleTextLatencyAndAverageTPSIncludeTheEntireRequest() throws {
    let performance = ScreenshotQuestionPerformance(
      startedAt: 10, firstTextAt: 14, completedAt: 20,
      usage: ScreenshotQuestionUsage(inputTokens: 100, outputTokens: 30, reasoningTokens: 10))
    XCTAssertEqual(try XCTUnwrap(performance.firstTokenLatency), 4)
    XCTAssertEqual(try XCTUnwrap(performance.elapsed), 10)
    XCTAssertEqual(try XCTUnwrap(performance.averageTokensPerSecond), 3)
  }

  func testUnavailableUsageAndIncompleteTimingStayUnknown() {
    let pending = ScreenshotQuestionPerformance(startedAt: 10)
    XCTAssertNil(pending.firstTokenLatency)
    XCTAssertNil(pending.elapsed)
    XCTAssertNil(pending.averageTokensPerSecond)
    let finishedWithoutUsage = ScreenshotQuestionPerformance(startedAt: 10, completedAt: 12)
    XCTAssertNil(finishedWithoutUsage.averageTokensPerSecond)
    XCTAssertNil(
      ScreenshotQuestionPerformance(
        startedAt: 10, completedAt: 10, usage: ScreenshotQuestionUsage(outputTokens: 5)
      ).averageTokensPerSecond)
    XCTAssertEqual(
      ScreenshotQuestionPerformance(
        startedAt: 10, completedAt: 12, usage: ScreenshotQuestionUsage(outputTokens: 0)
      ).averageTokensPerSecond, 0)
  }

  func testInvalidClocksDoNotProduceNegativeOrNonfiniteValues() {
    for performance in [
      ScreenshotQuestionPerformance(startedAt: 10, firstTextAt: 9, completedAt: 9),
      ScreenshotQuestionPerformance(
        startedAt: .infinity, firstTextAt: .infinity, completedAt: .infinity),
      ScreenshotQuestionPerformance(startedAt: 10, firstTextAt: .nan, completedAt: .nan),
    ] {
      XCTAssertNil(performance.firstTokenLatency)
      XCTAssertNil(performance.elapsed)
      XCTAssertNil(performance.averageTokensPerSecond)
    }
  }
}
