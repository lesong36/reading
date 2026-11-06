import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class MathMethodApplicabilityTests: XCTestCase {
  private let methods = [
    MathTeachingMethod(id: "main", versionID: "v1", title: "和差", category: "数量关系", instructions: "同一组的和与差。", createdAt: Date()),
    MathTeachingMethod(id: "visual", versionID: "v2", title: "条形图", category: "数形结合", instructions: "对齐同单位数量。", createdAt: Date()),
  ]
  private func assessment(_ id: String, status: String = "applicable", state: String = "met") -> [String: Any] {
    ["method_id": id, "status": status, "conditions": [
      ["requirement": "同一组数量及单位", "evidence": "原图说明同组数量和72差18", "status": state],
    ]]
  }
  private func decision() -> [String: Any] {
    ["method_id": "main", "visual_method_ids": ["visual"], "reason": "原图条件符合两种方法。",
      "applicability": [assessment("main"), assessment("visual")]]
  }
  private func parse(_ value: [String: Any], strict: Bool = true) throws -> MathMethodMatch {
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    return try MathMethodMatcher.parse(raw, methods: methods, requireApplicability: strict)
  }
  func testCompletePrimaryAndVisualEvidenceKeepsExactSnapshots() throws {
    let result = try parse(decision())
    XCTAssertEqual(result.method, methods[0]); XCTAssertEqual(result.visualMethods, [methods[1]])
    var visualOnly = decision(); visualOnly["method_id"] = NSNull(); visualOnly["applicability"] = [assessment("visual")]
    XCTAssertNil(try parse(visualOnly).method)
  }
  func testNullNonmathAndDiagnosticRejectionAreValid() throws {
    var value: [String: Any] = ["method_id": NSNull(), "visual_method_ids": [], "reason": "无适用方法", "applicability": []]
    XCTAssertNil(try parse(value).method)
    for (status, state) in [("missing", "missing"), ("conflicting", "conflicting"), ("not_applicable", "not_met")] {
      value["applicability"] = [assessment("main", status: status, state: state)]
      XCTAssertNil(try parse(value).method)
    }
  }
  func testChosenMissingConflictingOrExcludedMethodIsRejected() {
    for (status, state) in [("missing", "missing"), ("conflicting", "conflicting"), ("not_applicable", "not_met")] {
      var value = decision(); value["applicability"] = [assessment("main", status: status, state: state), assessment("visual")]
      XCTAssertThrowsError(try parse(value))
    }
  }
  func testEvidenceCannotBeAbsentEmptyOrContradictChosenIdentity() {
    var variants: [[String: Any]] = []
    var value = decision(); value.removeValue(forKey: "applicability"); variants.append(value)
    value = decision(); value["applicability"] = []; variants.append(value)
    value = decision(); value["applicability"] = [assessment("main")]; variants.append(value)
    value = decision(); value["method_id"] = NSNull(); variants.append(value)
    for state in ["missing", "conflicting", "not_met"] {
      value = decision(); value["applicability"] = [assessment("main", state: state), assessment("visual")]; variants.append(value)
    }
    for item in variants { XCTAssertThrowsError(try parse(item)) }
  }
  func testUnknownIdentifiersEnumsFieldsDuplicatesAndBoundsAreRejected() {
    var invalid: [[String: Any]] = []
    for change: [String: Any] in [["method_id": "unknown"], ["status": "maybe"], ["answer": 45], ["conditions": []], ["conditions": "met"]] {
      var item = assessment("main"); item.merge(change) { _, new in new }; invalid.append(item)
    }
    for change: [String: Any] in [["status": "unknown"], ["requirement": " "], ["evidence": ""], ["evidence": true], ["evidence": String(repeating: "题", count: 121)], ["answer": 45]] {
      var item = assessment("main"), condition = (item["conditions"] as! [[String: Any]])[0]
      condition.merge(change) { _, new in new }; item["conditions"] = [condition]; invalid.append(item)
    }
    var tooMany = assessment("main"); tooMany["conditions"] = Array(repeating: (tooMany["conditions"] as! [[String: Any]])[0], count: 9); invalid.append(tooMany)
    for item in invalid {
      var value = decision(); value["applicability"] = [item, assessment("visual")]; XCTAssertThrowsError(try parse(value))
    }
    var value = decision(); value["applicability"] = [assessment("main"), assessment("main"), assessment("visual")]; XCTAssertThrowsError(try parse(value))
    value = decision(); value["applicability"] = Array(repeating: assessment("main"), count: 7); XCTAssertThrowsError(try parse(value))
    value = decision(); value["reason"] = String(repeating: "题", count: 3000); XCTAssertThrowsError(try parse(value))
    value = decision(); value["extra"] = true; XCTAssertThrowsError(try parse(value))
  }
  func testNewPayloadBudgetAndDiagnosticStatusAreStrict() throws {
    var value = decision(); value["reason"] = String(repeating: "a", count: 4100)
    XCTAssertEqual(try parse(value).reason, String(repeating: "a", count: 200))
    XCTAssertThrowsError(try parse(value, strict: false))
    for status in ["missing", "conflicting", "not_applicable"] {
      let rejected: [String: Any] = ["method_id": NSNull(), "visual_method_ids": [], "reason": "条件未满足",
        "applicability": [assessment("main", status: status)]]
      XCTAssertThrowsError(try parse(rejected))
    }
  }
  func testLegacyParsingIsExplicitlyExcludedFromAutomaticContract() throws {
    let legacy: [String: Any] = ["method_id": "main", "visual_method_ids": [], "reason": "旧记录"]
    XCTAssertEqual(try parse(legacy, strict: false).method, methods[0])
    XCTAssertThrowsError(try parse(legacy))
    for field in ["applicability", "requirement", "evidence", "not_applicable", "本题原图"] {
      XCTAssertTrue(MathMethodMatcher.instructions.contains(field))
    }
  }
  func testActualNativeAutomaticSelectorCannotUseLegacyOrConflictingDeclarations() async throws {
    let eligible = methods.map { source in
      MathTeachingMethod(id: source.id, versionID: source.versionID, title: source.title,
        category: source.category, instructions: source.instructions, createdAt: source.createdAt,
        teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ApplicabilityURLProtocol.self]
    let client = ScreenshotQuestionClient(session: URLSession(configuration: sessionConfiguration))
    let matcher = MathMethodMatcher(client: client)
    defer { ApplicabilityURLProtocol.responseData = nil }
    let configuration = AIConfiguration(baseURL: "https://applicability.test/v1", model: "fixture", apiKey: "test-only")
    var legacy = decision(); legacy.removeValue(forKey: "applicability")
    var conflicting = decision(); conflicting["applicability"] = [assessment("main", status: "conflicting", state: "conflicting"), assessment("visual")]
    for (value, allowed) in [(decision(), true), (legacy, false), (conflicting, false)] {
      let response = try JSONSerialization.data(withJSONObject: ["choices": [[
        "message": ["content": String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)],
        "finish_reason": "stop",
      ]]])
      ApplicabilityURLProtocol.responseData = response
      do {
        let result = try await matcher.select(question: "四年级，不用方程", context: .init(text: "同一组数量的和差：两量和72差18，条形图对齐同单位数量。", selectedWord: nil, imageData: nil),
          methods: eligible, configuration: configuration, mode: .reviewed)
        XCTAssertTrue(allowed, "Automatic production entry point accepted incompatible declarations")
        XCTAssertEqual(result.method?.id, "main")
      } catch {
        XCTAssertFalse(allowed)
        guard case MathMethodMatchError.invalidOutput = error else { XCTFail("Unexpected error: \(error)"); continue }
      }
    }
  }

}


private final class ApplicabilityURLProtocol: URLProtocol {
  static var responseData: Data?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(object?["max_tokens"] as? Int, 2048, "Only the explicit math selector uses the larger evidence budget")
    guard let url = request.url, let data = Self.responseData,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])
    else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
