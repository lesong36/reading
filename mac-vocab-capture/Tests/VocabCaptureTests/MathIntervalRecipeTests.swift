import XCTest
@testable import VocabCapture

final class MathIntervalRecipeTests: XCTestCase {
  private func source(_ value: Double, _ unit: String) -> [String: Any] {
    ["value": value, "unit": unit, "evidence": "原题明确给出\(value)\(unit)"]
  }
  private func stairs(_ start: Double = 1, _ end: Double = 14, _ steps: Double = 21) -> [String: Any] {
    ["id": "stairs", "title": "楼层是点，台阶对应楼层间隔", "kind": "interval_problem", "scenario": "stairs",
      "start_floor": source(start, "层"), "end_floor": source(end, "层"), "steps_per_interval": source(steps, "级")]
  }
  private func planting(_ endpoints: String, length: Double = 100, spacing: Double = 5) -> [String: Any] {
    ["id": "planting", "title": "直线等距位置及端点计数", "kind": "interval_problem", "scenario": "planting",
      "length": source(length, "米"), "spacing": source(spacing, "米"), "endpoints": endpoints, "endpoint_evidence": "原题端点条件为\(endpoints)"]
  }
  func testActualStepClassifierReplaysWithoutAcceptingOtherDimensions() throws {
    var entry = stairs()
    entry["start_floor"] = ["value": 1, "unit": "楼", "evidence": "从1楼到14楼"]
    entry["end_floor"] = ["value": 14, "unit": "楼", "evidence": "从1楼到14楼"]
    entry["steps_per_interval"] = ["value": 21, "unit": "级台阶", "evidence": "每层楼间21级台阶"]
    let diagram = try MathIntervalRecipe.compile(entry)
    XCTAssertEqual(diagram.fact("total")?.value, 273)
    XCTAssertEqual(diagram.fact("total")?.unit, "级")
    entry["steps_per_interval"] = ["value": 21, "unit": "层", "evidence": "每层楼间21级台阶"]
    XCTAssertThrowsError(try MathIntervalRecipe.compile(entry))
  }

  func testFloorUnitLouFromActualModelIsEquivalentOnlyForFloorPositions() throws {
    var entry = stairs()
    entry["start_floor"] = ["value": 1, "unit": "楼", "evidence": "从1楼到14楼"]
    entry["end_floor"] = ["value": 14, "unit": "楼", "evidence": "从1楼到14楼"]
    entry["steps_per_interval"] = ["value": 21, "unit": "级", "evidence": "每层楼间21级台阶"]
    XCTAssertEqual(try MathIntervalRecipe.compile(entry).fact("total")?.value, 273)
    entry["steps_per_interval"] = ["value": 21, "unit": "楼", "evidence": "每层楼间21级台阶"]
    XCTAssertThrowsError(try MathIntervalRecipe.compile(entry))
  }

  func testStairsComputesThirteenIntervalsAnd273StepsAndRenders() throws {
    let diagram = try MathIntervalRecipe.compile(stairs())
    XCTAssertEqual(diagram.kind, .interval)
    XCTAssertEqual(diagram.fact("intervals")?.value, 13)
    XCTAssertEqual(diagram.fact("total")?.value, 273)
    XCTAssertEqual(diagram.fact("total")?.origin, .derived)
    XCTAssertEqual(diagram.fact("total")?.unit, "级")
    XCTAssertTrue(diagram.facts.filter { $0.origin == .constant }.isEmpty)
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
  }
  func testNonFirstFloorUsesDifferenceRatherThanNumberOfFloors() throws {
    let diagram = try MathIntervalRecipe.compile(stairs(4, 7, 12))
    XCTAssertEqual(diagram.fact("intervals")?.value, 3)
    XCTAssertEqual(diagram.fact("total")?.value, 36)
  }
  func testPlantingEndpointCountsAreNotConfusedWithIntervals() throws {
    for (endpoints, trees) in [("both", 21.0), ("one", 20.0), ("neither", 19.0)] {
      let diagram = try MathIntervalRecipe.compile(planting(endpoints))
      XCTAssertEqual(diagram.fact("intervals")?.value, 20)
      XCTAssertEqual(diagram.fact("tree_count")?.value, trees)
      XCTAssertEqual(diagram.fact("total")?.value, 100)
      XCTAssertTrue(diagram.fact("endpoint_rule")?.evidence?.contains(endpoints) == true)
      try MathDiagramAnswer.validateRendering(diagram)
    }
  }
  func testExactDecimalLengthsAndSpacing() throws {
    let diagram = try MathIntervalRecipe.compile(planting("both", length: 2.5, spacing: 0.5))
    XCTAssertEqual(diagram.fact("intervals")?.value, 5)
    XCTAssertEqual(diagram.fact("tree_count")?.value, 6)
  }
  func testUnsupportedIndicesQuantitiesAndConditionsRejectRatherThanInvent() {
    for values in [(0.0, 14.0, 21.0), (1, 1, 21), (14, 1, 21), (1.5, 14, 21), (1, 1002, 21), (1, 14, 0), (1, 14, 1.5)] {
      XCTAssertThrowsError(try MathIntervalRecipe.compile(stairs(values.0, values.1, values.2)))
    }
    XCTAssertThrowsError(try MathIntervalRecipe.compile(planting("circle")))
    XCTAssertThrowsError(try MathIntervalRecipe.compile(planting("both", length: 101)))
    XCTAssertThrowsError(try MathIntervalRecipe.compile(planting("neither", length: 5)))
    var unknown = stairs(); unknown["scenario"] = "cycle"
    XCTAssertThrowsError(try MathIntervalRecipe.compile(unknown))
  }
  func testSourceUnitsEvidenceBooleanAndInjectedAnswerReject() {
    for value: Any in [true, "14", NSNull(), Double.infinity] {
      var item = stairs(); item["end_floor"] = ["value": value, "unit": "层", "evidence": "原题"]
      XCTAssertThrowsError(try MathIntervalRecipe.compile(item))
    }
    for unit in ["米", "", "级"] {
      var item = stairs(); item["start_floor"] = source(1, unit)
      XCTAssertThrowsError(try MathIntervalRecipe.compile(item))
    }
    var mismatched = stairs(); mismatched["end_floor"] = ["value": 14, "unit": "层", "evidence": "原题到十三层"]
    XCTAssertThrowsError(try MathIntervalRecipe.compile(mismatched))
    var chinese = stairs(); chinese["end_floor"] = ["value": 14, "unit": "层", "evidence": "从一楼到十四楼"]
    XCTAssertNoThrow(try MathIntervalRecipe.compile(chinese))
    var noSource = stairs(); noSource["start_floor"] = ["value": 1, "unit": "层", "evidence": " "]
    XCTAssertThrowsError(try MathIntervalRecipe.compile(noSource))
    var noEndpoints = planting("both"); noEndpoints["endpoint_evidence"] = ""
    XCTAssertThrowsError(try MathIntervalRecipe.compile(noEndpoints))
    for key in ["answer", "total", "relations", "facts", "layout"] {
      var item = stairs(); item[key] = 273
      XCTAssertThrowsError(try MathIntervalRecipe.compile(item))
    }
  }
}
