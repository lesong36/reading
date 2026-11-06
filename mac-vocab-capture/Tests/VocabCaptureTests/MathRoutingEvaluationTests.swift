import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class MathRoutingEvaluationTests: XCTestCase {
  private func request(_ extras: [String: Any] = [:]) throws -> Data {
    var object: [String: Any] = ["output_directory": NSTemporaryDirectory() + "routing-evaluation-" + UUID().uuidString,
      "cases": ["known"]]
    object.merge(extras) { _, new in new }
    return try JSONSerialization.data(withJSONObject: object)
  }

  func testStrictRequestAndKnownCaseBoundary() throws {
    XCTAssertEqual(try MathRoutingEvaluationRequest.parse(request(), knownIDs: ["known"]).caseIDs, ["known"])
    for extra: [String: Any] in [["unknown": true], ["cases": []], ["cases": ["known", "known"]],
      ["cases": ["other"]], ["model": ""], ["model": 3], ["photo_path": false]] {
      XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(extra), knownIDs: ["known"]))
    }
    XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(Data(repeating: 32, count: 65_537), knownIDs: ["known"]))
  }

  func testOutputRejectsProductionLocationsAndSymlinkEscape() throws {
    for path in ["/", "/tmp", NSHomeDirectory() + "/Library/Application Support/VocabCapture/math-questions", Bundle.main.bundleURL.path] {
      XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(["output_directory": path]), knownIDs: ["known"]))
    }
    let link = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: NSHomeDirectory())
    defer { try? FileManager.default.removeItem(at: link) }
    XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(["output_directory": link.appendingPathComponent("evaluation").path]), knownIDs: ["known"]))
  }

  func testOutputCannotOverwritePreviousReportOrStore() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("existing".utf8).write(to: directory.appendingPathComponent("routing-report.json"))
    XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(["output_directory": directory.path]), knownIDs: ["known"]))
    try FileManager.default.removeItem(at: directory.appendingPathComponent("routing-report.json"))
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("isolated-methods"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(["output_directory": directory.path]), knownIDs: ["known"]))
  }

  func testPhotoCannotBeCombinedWithMultipleCaseStems() throws {
    XCTAssertThrowsError(try MathRoutingEvaluationRequest.parse(request(["cases": ["known", "two"], "photo_path": "/tmp/image.png"]), knownIDs: ["known", "two"]))
  }

  func testErrorCodesAreSafeAndDistinguishDeadlineFromProtocol() {
    XCTAssertEqual(MathRoutingEvaluationDelegate.errorCode(LangChainTransportError.requestTimeout), "timeout")
    XCTAssertEqual(MathRoutingEvaluationDelegate.errorCode(ScreenshotQuestionError.server(400)), "http_400")
    XCTAssertEqual(MathRoutingEvaluationDelegate.errorCode(MathMethodMatchError.invalidOutput), "invalid_output")
    XCTAssertEqual(MathRoutingEvaluationDelegate.errorCode(NSError(domain: "secret-token-endpoint", code: 9)), "selection_failed")
  }

  func testReportsContainNoConfigurationAndNoApprovalClaim() throws {
    let report = MathRoutingEvaluationReport(model: "configured-model", error: "credential_unavailable")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    XCTAssertEqual(object["human_approval"] as? Bool, false)
    XCTAssertEqual(object["production_data_modified"] as? Bool, false)
    XCTAssertEqual(object["answer_accuracy_evaluated"] as? Bool, false)
    XCTAssertNil(object["configuration"]); XCTAssertNil(object["api_key"]); XCTAssertNil(object["base_url"])
    XCTAssertEqual(Set(object.keys), ["schema_version", "model", "answer_accuracy_evaluated", "human_approval", "production_data_modified", "selection_protocol", "source_hashes", "cases", "error"])
  }
}
