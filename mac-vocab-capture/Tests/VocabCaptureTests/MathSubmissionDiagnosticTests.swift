import XCTest
@testable import VocabCapture

final class MathSubmissionDiagnosticTests: XCTestCase {
  func testSafeSchemaMetadataSurvivesUsageBoundary() throws {
    let diagnostic = ["tool": "submit_general_math_solution", "path": "$.diagram_outcome.primary_diagram.quantities[2].unit", "rule": "required"]
    let usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "submission_validation", "timings": ["engine_total": 4.52],
      "submission_issue": "submission_shape", "submission_diagnostic": diagnostic]))
    XCTAssertEqual(usage.submissionDiagnostic?.path, diagnostic["path"])
    let performance = ScreenshotQuestionPerformance(startedAt: 0, completedAt: 4.52, usage: usage)
    XCTAssertTrue(performance.breakdown(localDurations: [:]).contains("字段：$.diagram_outcome.primary_diagram.quantities[2].unit"))
  }
  func testDigitToolSchemaMetadataSurvivesUsageBoundary() throws {
    for field in ["larger_hundreds", "smaller_hundreds", "repeated_digits", "turn_order", "evidence"] {
      let diagnostic = ["tool": "solve_reported_digit_game", "path": "$." + field, "rule": "required"]
      let usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure([
        "failure_phase": "submission_validation", "timings": ["engine_total": 1.0],
        "submission_issue": "submission_shape", "submission_diagnostic": diagnostic]))
      XCTAssertEqual(usage.submissionDiagnostic?.tool, "solve_reported_digit_game")
      XCTAssertEqual(usage.submissionDiagnostic?.path, "$." + field)
    }
  }
  func testReflectedToolSchemaFailureSurvivesUsageBoundary() throws {
    let diagnostic = ["tool": "solve_reflected_meetings", "path": "$.starts", "rule": "enum"]
    let usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure([
      "failure_phase": "submission_validation", "timings": ["engine_total": 1.5],
      "submission_issue": "submission_shape", "submission_diagnostic": diagnostic]))
    XCTAssertEqual(usage.submissionDiagnostic?.path, "$.starts")
    XCTAssertEqual(usage.submissionDiagnostic?.tool, "solve_reflected_meetings")
    for field in ["a", "b", "evidence"] {
      XCTAssertNotNil(MathSubmissionDiagnostic(["tool": "solve_reflected_meetings", "path": "$." + field, "rule": "required"]))
    }
  }
  func testRejectsUntrustedNamesValuesAndIndexes() {
    let base = ["tool": "render_difference_ratio", "path": "$.diagram.difference.unit", "rule": "type"]
    XCTAssertNotNil(MathSubmissionDiagnostic(base))
    for (key, value) in [("tool", "private-secret"), ("path", "$.api_key"), ("path", "$.quantities[32].value"),
      ("path", "$.answer.secret"), ("path", "$\nprivate"), ("rule", "secret")] {
      var wrong = base; wrong[key] = value
      XCTAssertNil(MathSubmissionDiagnostic(wrong))
    }
    var wrong = base; wrong["value"] = "private"
    XCTAssertNil(MathSubmissionDiagnostic(wrong))
  }
  func testIncompleteStreamCategoryIsAllowlistedAndRequiresTruncatedIssue() throws {
    var event: [String: Any] = ["failure_phase": "submission_validation",
      "timings": ["engine_total": 35.0], "submission_issue": "submission_truncated"]
    for category in ["missing_terminal", "token_limit", "content_filter", "incomplete", "provider_failure", "other_terminal"] {
      event["stream_termination"] = category
      let usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure(event))
      XCTAssertEqual(usage.failureIssue, "submission_truncated")
      XCTAssertEqual(usage.streamTermination, category)
      XCTAssertTrue(ScreenshotQuestionPerformance(startedAt: 0, completedAt: 35, usage: usage)
        .breakdown(localDurations: [:]).contains("回答流结束状态："))
    }
    event["stream_termination"] = "private-secret"
    var usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure(event))
    XCTAssertNil(usage.streamTermination)
    XCTAssertFalse(ScreenshotQuestionPerformance(startedAt: 0, completedAt: 35, usage: usage)
      .breakdown(localDurations: [:]).contains("private-secret"))
    event["stream_termination"] = "token_limit"
    event["submission_issue"] = "submission_shape"
    usage = try XCTUnwrap(ScreenshotQuestionUsage.decodeFailure(event))
    XCTAssertNil(usage.streamTermination)
  }

}
