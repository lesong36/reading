import XCTest
@testable import VocabCapture

final class MathMethodMatcherReasonTests: XCTestCase {
  private let primary = MathTeachingMethod(
    id: "primary", versionID: "primary-v1", title: "差倍问题", category: "数量关系",
    instructions: "比较同一两量的差与倍数。", createdAt: Date(timeIntervalSince1970: 0))
  private let visual = MathTeachingMethod(
    id: "visual", versionID: "visual-v1", title: "线段图", category: "数形结合",
    instructions: "用等份线段展示差与倍数。", createdAt: Date(timeIntervalSince1970: 0))

  private func output(primary: Any = "primary", visuals: Any = ["visual"], reason: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: [
      "method_id": primary, "visual_method_ids": visuals, "reason": reason,
    ]), as: UTF8.self)
  }

  func testVerboseExplanationDoesNotDiscardValidPrimaryAndVisualSelections() throws {
    let reason = String(repeating: "原题数量关系明确，应比较差数和倍数。", count: 18)
    XCTAssertGreaterThan(reason.count, 200)
    let payload = try output(reason: reason)
    XCTAssertLessThan(payload.utf8.count, 4000)
    let match = try MathMethodMatcher.parse(payload, methods: [primary, visual])
    XCTAssertEqual(match.method, primary)
    XCTAssertEqual(match.visualMethods, [visual])
    XCTAssertEqual(match.reason, String(reason.prefix(200)))
  }

  func testExplanationWhitespaceIsTrimmedBeforeBoundingAndNoMatchRemainsNoMatch() throws {
    let reason = " \n" + String(repeating: "非数学请求，没有适用的方法。", count: 18) + "\t "
    let match = try MathMethodMatcher.parse(
      output(primary: NSNull(), visuals: [], reason: reason), methods: [primary, visual])
    XCTAssertNil(match.method)
    XCTAssertTrue(match.visualMethods.isEmpty)
    XCTAssertEqual(match.reason, String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
    XCTAssertEqual(match.reason.count, 200)
  }

  func testTruncationDoesNotRelaxIdentityTypeCombinationOrPayloadValidation() throws {
    let longReason = String(repeating: "条件明确。", count: 50)
    let malformed = try [
      output(primary: "invented", reason: longReason),
      output(primary: true, reason: longReason),
      output(visuals: ["invented"], reason: longReason),
      output(visuals: ["visual", "visual"], reason: longReason),
      output(visuals: ["primary"], reason: longReason),
      output(visuals: ["visual", "primary", "invented"], reason: longReason),
      output(visuals: "visual", reason: longReason),
      output(reason: 200), output(reason: NSNull()), output(reason: " \n\t"),
      output(reason: String(repeating: "大", count: 2000)),
    ]
    for payload in malformed {
      XCTAssertThrowsError(try MathMethodMatcher.parse(payload, methods: [primary, visual]))
    }
    var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output(reason: longReason).utf8)) as? [String: Any])
    extra["answer"] = 8
    let data = try JSONSerialization.data(withJSONObject: extra)
    XCTAssertThrowsError(try MathMethodMatcher.parse(String(decoding: data, as: UTF8.self), methods: [primary, visual]))
  }
}
