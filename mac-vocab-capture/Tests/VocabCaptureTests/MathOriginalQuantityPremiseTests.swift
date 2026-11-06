import XCTest
@testable import VocabCapture

final class MathOriginalQuantityPremiseTests: XCTestCase {
  private func result(_ difference: [String: Any], _ multiplier: [String: Any]) throws -> MathDiagramAnswer.Result {
    let data = try JSONSerialization.data(withJSONObject:["schemaVersion":1,"diagrams":[
      ["id":"d","title":"原题数量关系","kind":"difference_ratio","difference":difference,"multiplier":multiplier]]])
    return MathDiagramAnswer.parse("保留原解答，仍待核验。\n```math-diagrams\n" + String(decoding:data,as:UTF8.self) + "\n```")
  }
  func testActualSumAndRatioCannotBeCompiledAsDifferenceAndRatio() throws {
    let checked = try result(["value":248,"unit":"棵","evidence":"杏树和桃树共248棵"],
      ["value":3,"evidence":"桃树是杏树的3倍"])
    XCTAssertTrue(checked.diagrams.isEmpty); XCTAssertNotNil(checked.failure)
    XCTAssertTrue(checked.text.contains("保留原解答"))
  }
  func testActualComputedDifferenceAndEqualizingRuleCannotBeDeclaredAsGivens() throws {
    let checked = try result(["value":16,"unit":"本","evidence":"甲有38本，乙有22本，甲比乙多38-22=16本"],
      ["value":2,"evidence":"两人一样多，把差平均分成2份"])
    XCTAssertTrue(checked.diagrams.isEmpty); XCTAssertNotNil(checked.failure)
  }
  func testOriginalAgeAndMultiplicationConditionsRemainSupported() throws {
    for (value, multiplier, unit, differenceText, multiplierText) in [
      (30.0,3.0,"岁","去年爸爸比小明大30岁，两人年龄差不变","今年爸爸年龄是小明的三倍"),
      (72.0,10.0,"","一个数乘十，得到的数比原数大72","原题说一个数乘十")
    ] {
      let checked = try result(["value":value,"unit":unit,"evidence":differenceText],
        ["value":multiplier,"evidence":multiplierText])
      XCTAssertNil(checked.failure); XCTAssertEqual(checked.diagrams.count,1)
    }
  }
}
