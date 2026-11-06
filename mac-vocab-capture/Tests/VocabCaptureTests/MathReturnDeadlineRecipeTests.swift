import XCTest
@testable import VocabCapture

final class MathReturnDeadlineRecipeTests: XCTestCase {
  private func recipe(outward: Double = 30, back: Double = 20, time: Double = 21, limit: Double = 45) -> [String: Any] {
    func source(_ value: Double) -> [String: Any] { ["value": value, "evidence": "原题给出\(value)"] }
    return ["id":"return", "title":"同路往返时间比较", "kind":"return_deadline", "distance_unit":"米", "time_unit":"分钟",
      "outward_speed":source(outward), "return_speed":source(back), "outward_time":source(time), "deadline":source(limit)]
  }
  func testOriginalBoatConditionDerivesJourneyAndDeadlineAndRenders() throws {
    let diagram = try MathReturnDeadlineRecipe.compile(recipe())
    for (id, value) in [("distance",630.0), ("return_time",31.5), ("total_time",52.5), ("deadline_difference",7.5)] {
      XCTAssertEqual(diagram.fact(id)?.value, value)
      XCTAssertEqual(diagram.fact(id)?.origin, .derived)
    }
    XCTAssertEqual(diagram.fact("return_time")?.unit, "分钟")
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertTrue(try MathCheckedDiagramExplanation.text(for: diagram).contains("不能在规定时间内返回"))
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion":1, "diagrams":[recipe()]])
    let result = MathDiagramAnswer.parse("同路比较\n```math-diagrams\n" + String(decoding:data, as:UTF8.self) + "\n```")
    XCTAssertNil(result.failure); XCTAssertEqual(result.diagrams.count,1)
  }
  func testEqualityAndFasterReturnDoNotClaimOvertime() throws {
    for limit in [42.0, 43.0] {
      let diagram = try MathReturnDeadlineRecipe.compile(recipe(back:30, limit:limit))
      XCTAssertTrue(try MathCheckedDiagramExplanation.text(for:diagram).contains("能在规定时间内返回"))
      XCTAssertEqual(diagram.fact("deadline_difference")?.value, limit - 42)
    }
  }
  func testUntrustedCalculatedOrMissingSourcesAndUnsupportedUnitsAreRejected() throws {
    var input = recipe()
    input["return_speed"] = ["value":true, "evidence":"每分钟20米"]
    XCTAssertThrowsError(try MathReturnDeadlineRecipe.compile(input))
    input = recipe(); input["total_time"] = 52.5
    XCTAssertThrowsError(try MathReturnDeadlineRecipe.compile(input))
    input = recipe(); input["time_unit"] = "秒"
    XCTAssertThrowsError(try MathReturnDeadlineRecipe.compile(input))
    input = recipe(); input["return_speed"] = ["value":20, "evidence":"原题给出30"]
    XCTAssertThrowsError(try MathReturnDeadlineRecipe.compile(input))
    for value in [0.0,-1.0,1_000_000_001.0] { XCTAssertThrowsError(try MathReturnDeadlineRecipe.compile(recipe(back:value))) }
  }
}
