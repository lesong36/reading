import Foundation
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionPerformanceTests: XCTestCase {
  func testBreakdownSeparatesOuterDurationsFromNestedEngineAndStreamLandmarks() {
    let performance = ScreenshotQuestionPerformance(
      startedAt: 10, firstTextAt: 15.5, completedAt: 16,
      usage: ScreenshotQuestionUsage(outputTokens: 20, engineTimings: [
        "engine_preparation": 0.1, "model_acquisition": 0.2, "tool_binding": 0.1,
        "stream_total": 4, "submission_validation": 0.1, "engine_total": 4.6,
        "first_sdk_chunk": 1, "first_tool_arguments": 1.5, "arguments_to_stream_end": 2.5,
      ]))
    let report = performance.breakdown(localDurations: [
      "methodLookup": 0.1, "sourceIndex": 0.2, "skillRetrieval": 0.1,
      "promptAssembly": 0.1, "modelRequest": 5, "answerProcessing": 0.1,
      "transcriptRendering": 0.1,
    ])
    XCTAssertTrue(report.contains("本次总耗时：6.000 秒"))
    XCTAssertTrue(report.contains("首次可见文字：5.500 秒"))
    XCTAssertTrue(report.contains("未单独记录的其余耗时：0.300 秒"))
    XCTAssertTrue(report.contains("引擎其余未细分耗时：0.100 秒"))
    XCTAssertTrue(report.contains("引擎以外的未细分耗时：0.400 秒"))
    XCTAssertTrue(report.contains("开始至首块 1.000 秒；首块至首段参数 0.500 秒；首段参数至流结束 2.500 秒"))
    XCTAssertFalse(report.contains("时钟存在重叠"))
    XCTAssertEqual(performance.averageTokensPerSecond, 20.0 / 6)
  }

  func testBreakdownMissingAndInvalidClocksRemainUnknownAndNeverExposeUnknownFields() {
    let performance = ScreenshotQuestionPerformance(startedAt: 0,
      usage: ScreenshotQuestionUsage(engineTimings: [
        "engine_total": .infinity, "stream_total": -1, "first_sdk_chunk": .nan,
        "private-provider-text": 99,
      ], failurePhase: "private-provider-text", failureIssue: "secret"))
    let report = performance.breakdown(localDurations: [
      "sourceIndex": .infinity, "methodLookup": -1, "private-provider-text": 9,
    ])
    XCTAssertTrue(report.contains("本次总耗时：未记录"))
    XCTAssertTrue(report.contains("本机方法读取：未记录"))
    XCTAssertTrue(report.contains("SDK 请求流（等待与接收）：未记录"))
    XCTAssertTrue(report.contains("无法分别测出网络、服务端排队、模型思考和生成耗时"))
    for forbidden in ["private-provider-text", "secret", "nan", "inf", "-1.000"] {
      XCTAssertFalse(report.contains(forbidden), forbidden)
    }
  }

  func testBreakdownFailureRetainsPartialDurationsWithoutInventingUnreachedStages() throws {
    let usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "stream", "timings": [
        "engine_total": 4, "engine_preparation": 0.1, "model_acquisition": 0.1,
        "tool_binding": 0.1, "stream_total": 3.6, "first_sdk_chunk": 1,
      ],
    ]))
    let report = ScreenshotQuestionPerformance(startedAt: 0, completedAt: 4.2, usage: usage)
      .breakdown(localDurations: ["modelRequest": 4.1])
    XCTAssertTrue(report.contains("本次失败阶段：SDK 请求流"))
    XCTAssertTrue(report.contains("引擎提交校验：未记录"))
    XCTAssertTrue(report.contains("首段工具参数：未记录"))
    XCTAssertFalse(report.contains("流内不重叠分段："))
    XCTAssertNil(usage.outputTokens)
  }

  func testBreakdownRejectsOverlappingAndContradictoryDurationsWithoutNegativeResiduals() {
    let report = ScreenshotQuestionPerformance(startedAt: 0, completedAt: 2,
      usage: ScreenshotQuestionUsage(engineTimings: [
        "engine_total": 4, "stream_total": 5, "first_sdk_chunk": 3,
        "first_tool_arguments": 2, "arguments_to_stream_end": 3,
      ])).breakdown(localDurations: ["modelRequest": 3])
    XCTAssertTrue(report.contains("本机分段合计超过总耗时"))
    XCTAssertTrue(report.contains("引擎分段合计超过引擎总计"))
    XCTAssertTrue(report.contains("引擎总计超过模型请求往返"))
    XCTAssertTrue(report.contains("SDK 流内时间点顺序或总长不一致"))
    XCTAssertFalse(report.contains("-1.000"))
    XCTAssertFalse(report.contains("流内不重叠分段："))
  }

  func testBreakdownRejectsTailThatDoesNotMatchStreamLandmarks() {
    let report = ScreenshotQuestionPerformance(startedAt: 0, completedAt: 5,
      usage: ScreenshotQuestionUsage(engineTimings: [
        "stream_total": 4, "first_sdk_chunk": 1, "first_tool_arguments": 2,
        "arguments_to_stream_end": 3,
      ])).breakdown(localDurations: [:])
    XCTAssertTrue(report.contains("SDK 流内时间点顺序或总长不一致"))
    XCTAssertFalse(report.contains("流内不重叠分段："))
  }

  func testEngineTimingTelemetryIsFiniteAllowlistedAndDoesNotChangeCounts() throws {
    let usage = try XCTUnwrap(ScreenshotQuestionUsage.decode(["output_tokens": 20], timings: [
      "stream_total": 1.25, "first_sdk_chunk": 0.3, "engine_total": Double.infinity,
      "tool_binding": -1, "first_tool_arguments": true, "secret": "hidden"
    ]))
    XCTAssertEqual(usage.outputTokens, 20)
    XCTAssertEqual(usage.engineTimings, ["stream_total": 1.25, "first_sdk_chunk": 0.3])
  }

  func testSuccessTimingsSurviveAbsentTokenUsageWithoutInventingCounts() throws {
    for counts: Any? in [nil, [String: Any]()] {
      let usage = try XCTUnwrap(ScreenshotQuestionUsage.decode(counts, timings: [
        "engine_total": 2.1, "stream_total": 2,
      ]))
      XCTAssertNil(usage.inputTokens)
      XCTAssertNil(usage.outputTokens)
      XCTAssertNil(usage.reasoningTokens)
      XCTAssertEqual(usage.engineTimings["engine_total"], 2.1)
      XCTAssertNil(ScreenshotQuestionPerformance(startedAt: 0, completedAt: 3, usage: usage).averageTokensPerSecond)
    }
    XCTAssertNil(ScreenshotQuestionUsage.decode(["output_tokens": false], timings: ["engine_total": 2]))
    XCTAssertNil(ScreenshotQuestionUsage.decode("invalid", timings: ["engine_total": 2]))
    XCTAssertNil(ScreenshotQuestionUsage.decode(nil, timings: ["engine_total": -1]))
  }

  func testFailureTelemetryRejectsUnknownPhasesAndProviderContent() throws {
    XCTAssertNil(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "untrusted-secret", "timings": ["engine_total": 1]]))
    XCTAssertNil(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "stream", "timings": ["engine_total": true, "secret": 1]]))
    let value = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "stream", "submission_issue": "untrusted-secret",
      "usage": ["output_tokens": 999], "timings": ["engine_total": 1.2, "secret": "private"]]))
    XCTAssertNil(value.outputTokens); XCTAssertNil(value.failureIssue)
    XCTAssertEqual(value.engineTimings, ["engine_total": 1.2])
  }

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
