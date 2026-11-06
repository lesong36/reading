import Foundation
import XCTest

@testable import VocabCapture

final class MathExplicitAdditionAuditTests: XCTestCase {
  func testRecordedGridAnswerContradictionAndCorrectAreaSum() {
    let text = """
      前7种面积和：1+2+3+4+4+5+6=25，正好25格。
      面积核对：1+2+3+4+5+4+4+6=25，正好等于25格。
      """
    let issues = MathExplicitAdditionAudit.issues(in: text)
    XCTAssertEqual(issues.count, 1)
    XCTAssertEqual(issues.first?.values, [29, 25])
    XCTAssertTrue(MathExplicitAdditionAudit.notice(in: text)?.contains("29、25") == true)
  }

  func testCompleteAdditionChainsAndUnicodeOperators() {
    XCTAssertTrue(MathExplicitAdditionAudit.issues(in: "1+2=3=2+1").isEmpty)
    XCTAssertEqual(MathExplicitAdditionAudit.issues(in: "面积：1＋2＝4格").first?.values, [3, 4])
    XCTAssertEqual(MathExplicitAdditionAudit.issues(in: "1+2=3=4").first?.values, [3, 3, 4])
  }

  func testUnsupportedExpressionsAreNotPartiallyEvaluated() {
    for text in [
      "1+2=4-1", "1+2=4–1", "1+2=6/2", "1+2=6:2", "1+2=1·3",
      "1+2=1.5×2", "1+2=300%", "√4+2=4",
      "x1+2=4", "1e2+1=101", "α1+2=4", "1+2=4x", "2²+2=6",
      "1+2=4_0", "18446744073709551615+1=0", "18446744073709551616+1=0",
    ] {
      XCTAssertNil(MathExplicitAdditionAudit.notice(in: text), text)
    }
  }

  func testFencedPayloadsAreExcludedAndOriginalReviewStatusSurvivesRoundTrip() throws {
    let answer = """
      ```math-grid
      {"title":"1+2=4"}
      ```
      ~~~
      1+2=4
      ~~~
      错误示例：1+2=4，请解释错误。
      """
    let original = MathQuestionSolution(question: "检查", answer: answer, model: "fixture")
    XCTAssertEqual(MathExplicitAdditionAudit.issues(in: answer).count, 1)
    XCTAssertTrue(original.arithmeticNotice?.contains("若此处是在举错误示例") == true)
    let decoded = try JSONDecoder().decode(
      MathQuestionSolution.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.answer, answer)
    XCTAssertEqual(decoded.verificationStatus, "unverified")
    XCTAssertEqual(decoded.arithmeticNotice, original.arithmeticNotice)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains(
        "arithmeticNotice"))
  }

  func testShortFenceInsideLongerFenceDoesNotExposeCodeAsProse() {
    let answer = """
      ````markdown
      ```
      1+2=4
      ```
      1+2=5
      ````
      1+2=6
      """
    XCTAssertEqual(MathExplicitAdditionAudit.issues(in: answer).map(\.values), [[3, 6]])
  }
}
