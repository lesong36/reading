import CryptoKit
import Foundation
import XCTest
@testable import VocabCapture

final class MathSingleCallSelectionTests: XCTestCase {
  private let question = "四年级，不用方程"
  private let configuration = AIConfiguration(baseURL: "https://single-call.test/v1", model: "fixture", apiKey: "test-only")

  private func method(_ name: String) throws -> MathTeachingMethod {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == name })
    return .init(id: skill.sourceID, versionID: "immutable-fixture", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
  }

  private func custom() -> MathTeachingMethod {
    .init(id: "human-reviewed-custom", versionID: "reviewed-version", title: "自定义方法", category: "线段图",
      instructions: "同一组数量的和与差已知时求两量。完整方法正文与适用限制，不能因分类名称推断它是图法。", createdAt: Date(),
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
  }

  private func output(_ primary: String?, visual: [String] = []) throws -> String {
    let object: [String: Any] = ["method_id": primary as Any? ?? NSNull(),
      "visual_method_ids": visual, "reason": "本题关系符合方法，但仍需核验答案。"]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  func testCompactSelectionPreservesCompleteOriginalSnapshotAndIsExplicitlySuggestion() throws {
    let primary = try method("sum-and-difference")
    let visual = try method("comparison-line-diagram")
    let match = try MathMethodMatcher.parseSingleCall(output(primary.id, visual: [visual.id]),
      methods: [primary, visual], question: question)
    XCTAssertEqual(match.method, primary)
    XCTAssertEqual(match.visualMethods, [visual])
    XCTAssertEqual(match.method?.instructions, primary.instructions)
    XCTAssertEqual(match.method?.versionID, primary.versionID)
    XCTAssertTrue(match.reason.hasPrefix("匹配建议（未经独立核验）："))
  }

  func testCompactSelectionRejectsUnknownFieldsRolesIdentitiesAndIneligibleMethods() throws {
    let solution = try method("sum-and-difference")
    let visual = try method("comparison-line-diagram")
    let routing = try method("math-diagram-routing")
    let equation = try method("equations-and-elimination")
    let candidates = [solution, visual, routing, equation]
    for raw in [try output("forged"), try output(visual.id), try output(routing.id),
      try output(equation.id), try output(solution.id, visual: [solution.id]),
      try output(nil, visual: [solution.id]), try output(nil, visual: [routing.id])] {
      XCTAssertThrowsError(try MathMethodMatcher.parseSingleCall(raw, methods: candidates, question: question))
    }
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output(solution.id).utf8)) as? [String: Any])
    object["applicability"] = []
    XCTAssertThrowsError(try MathMethodMatcher.parseSingleCall(
      String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), methods: candidates, question: question))
    XCTAssertThrowsError(try MathMethodMatcher.parseSingleCall(output(solution.id), methods: [solution, solution], question: question))
  }

  func testCustomHumanPermissionCarriesBoundSolutionOnlyRoleAndFullBody() throws {
    let snapshot = custom()
    let data = try ScreenshotQuestionClient.payload(question: question, context: .init(text: "原题", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: .automatic, thinking: .high, teachingSkills: [snapshot], selectionProtocol: .singleCall)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["selection_protocol"] as? String, "single_call")
    let entries = try XCTUnwrap(object["teaching_skills"] as? [[String: String]])
    XCTAssertEqual(entries[0]["instructions"], snapshot.instructions)
    XCTAssertEqual(entries[0]["version_id"], snapshot.versionID)
    let role = try JSONDecoder().decode(MathMethodSelectionRolePolicy.self,
      from: Data(XCTUnwrap(entries[0]["selection_role_policy"]).utf8))
    XCTAssertEqual(role.roles, ["solution"])
    XCTAssertEqual(role.method_id, snapshot.id)
    XCTAssertEqual(role.version_id, snapshot.versionID)
    XCTAssertEqual(role.instructions_sha256, SHA256.hash(data: Data(snapshot.instructions.utf8)).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(try MathMethodMatcher.parseSingleCall(output(snapshot.id), methods: [snapshot], question: question).method, snapshot)
    XCTAssertThrowsError(try MathMethodMatcher.parseSingleCall(output(nil, visual: [snapshot.id]), methods: [snapshot], question: question))
  }

  func testProtocolIsOptInAndCannotLeakIntoOrdinaryEnglishTask() throws {
    // The Python engine accepts daily for the existing independently reviewed
    // path; the Swift case name must not accidentally become the wire value.
    XCTAssertEqual(MathMethodSelectionProtocol.reviewed.rawValue, "daily")
    let context = ScreenshotQuestionContext(text: "English text", selectedWord: nil, imageData: nil)
    for mode in [nil, MathMethodSelectionProtocol.singleCall, .reviewed] {
      let data = try ScreenshotQuestionClient.payload(question: "Explain the sentence", context: context,
        history: [], configuration: configuration, api: .automatic, selectionProtocol: mode)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertNil(object["selection_protocol"])
      XCTAssertNil(object["task"])
    }
    let ordinary = try ScreenshotQuestionClient.payload(question: question, context: context, history: [],
      configuration: configuration, api: .automatic, teachingSkills: [custom()])
    XCTAssertNil((try JSONSerialization.jsonObject(with: ordinary) as? [String: Any])?["selection_protocol"])
  }

  func testDefaultMatcherUsesCompactInstructionsAndDisablesThinking() async throws {
    let snapshot = custom()
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [SingleCallURLProtocol.self]
    SingleCallURLProtocol.response = try output(snapshot.id)
    defer { SingleCallURLProtocol.response = nil; SingleCallURLProtocol.requestBody = nil }
    let matcher = MathMethodMatcher(client: ScreenshotQuestionClient(session: URLSession(configuration: session)))
    let selected = try await matcher.select(question: question, context: .init(text: "同一组数量的和与差已知：和72，差18，求两量。", selectedWord: nil, imageData: nil),
      methods: [snapshot], configuration: configuration)
    XCTAssertEqual(selected.method, snapshot)
    let request = try XCTUnwrap(SingleCallURLProtocol.requestBody)
    let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.first?["content"] as? String, MathMethodMatcher.singleCallInstructions)
    XCTAssertFalse((messages.first?["content"] as? String ?? "").contains("applicability"))
    let payload = try ScreenshotQuestionClient.payload(question: question, context: .init(text: "原题", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: .automatic, thinking: .high, teachingSkills: [snapshot], selectionProtocol: .singleCall)
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual((envelope["configuration"] as? [String: Any])?["thinking"] as? String, ScreenshotQuestionThinking.off.rawValue)
  }
}

private final class SingleCallURLProtocol: URLProtocol {
  static var response: String?
  static var requestBody: [String: Any]?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    Self.requestBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    guard let url = request.url, let text = Self.response,
      let data = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": "stop"]]]),
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
    else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
