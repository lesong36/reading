import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathAnswerFaultIsolationTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ predicate: () -> Bool) async throws {
    // This bounds asynchronous UI completion, not provider performance.
    // Keep timing assertions on the injected clock separate from suite load.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    repeat {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    } while clock.now < deadline
    _ = try XCTUnwrap(predicate() ? true : nil, "Answer delivery did not settle")
  }
  private func deliver(_ response: String?, incomplete: Bool, expectText: String?) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in
        calls += 1
        guard let response else { throw MathSolutionSubmissionError(issue: "submission_shape")! }
        return response
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No extra routing request"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    defer { panel.close() }
    panel.present()
    let views = descendants(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "用小学知识解题并验算"
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { calls == 1 && !panel.isAnswering }
    XCTAssertEqual(calls, 1, "Fault isolation must not make another model call")
    let statuses = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
    if let expectText {
      XCTAssertEqual(panel.history.count, 1)
      let delivered = try XCTUnwrap(panel.history.first)
      XCTAssertTrue(delivered.answer.contains(expectText))
      XCTAssertEqual(delivered.answer.hasPrefix("解答尚未完成"), incomplete)
      XCTAssertTrue(statuses.contains { $0.contains(incomplete ? "解答尚未完成，已保留关系说明" : "回答已保留") })
    } else {
      XCTAssertTrue(panel.history.isEmpty, "An unusable reply must not become a completed answer")
      XCTAssertTrue(statuses.contains { $0.hasPrefix("回答失败") })
    }
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let savedPhoto = try await store.originalImage(questionID: id)
    XCTAssertEqual(savedPhoto, photo)
    let solutions = try await store.solutions(questionID: id)
    if let expectText {
      let solution = try XCTUnwrap(solutions.first)
      XCTAssertTrue(solution.answer.contains(expectText))
      XCTAssertEqual(solution.answer.hasPrefix("解答尚未完成"), incomplete)
      XCTAssertEqual(solution.verificationStatus, "unverified")
      XCTAssertTrue(solution.diagrams.isEmpty)
      XCTAssertNotNil(solution.diagramFailure)
    } else { XCTAssertTrue(solutions.isEmpty) }
    await store.close()
  }
  private func envelope(mode: String = "general", text: String, diagrams: [[String: Any]] = [], issue: String? = nil) throws -> String {
    var object: [String: Any] = ["schemaVersion": 1, "mode": mode, "method_id": NSNull(), "visual_method_ids": [], "answer": text, "diagrams": diagrams]
    if let issue { object["diagram_submission_failure"] = issue }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
  func testShapeFailureKeepsIndependentAnswerAndOriginalWithoutRetry() async throws {
    try await deliver(envelope(text: "115×2=230元；230×12=2760元。", issue: "submission_shape"), incomplete: false, expectText: "2760")
  }
  func testUnitFailureDoesNotEraseIndependentAnswerOrRenderBadDiagram() async throws {
    var diagram = MathDiagramFixtures.area
    diagram.facts[2].unit = "cm"
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as? [String: Any])
    try await deliver(envelope(text: "14×13=182平方厘米。", diagrams: [object]), incomplete: false, expectText: "182")
  }
  func testBadNativeRecipeKeepsExplanationButNeverClaimsCompleteAnswer() async throws {
    let bad: [String: Any] = ["id": "ratio", "title": "差倍", "kind": "difference_ratio",
      "difference": ["value": 72, "unit": ""], "multiplier": ["value": 10, "evidence": "原题乘10"]]
    try await deliver(envelope(mode: "native_recipe", text: "差数对应多出的九份。", diagrams: [bad]), incomplete: true, expectText: "九份")
  }
  func testTransportPartialRelationshipIsExplicitlyIncomplete() async throws {
    try await deliver(envelope(text: "差数对应多出的九份。", issue: "submission_relationship_only"), incomplete: true, expectText: "九份")
  }
  func testNoUsableTextKeepsOnlyOriginalAndReportsFailure() async throws {
    try await deliver(nil, incomplete: true, expectText: nil)
  }
}
