import XCTest
@testable import VocabCapture

final class MathRectangleSumDifferenceRecipeTests: XCTestCase {
  private func source(_ value: Any, _ unit: String, _ evidence: String) -> [String: Any] {
    ["value": value, "unit": unit, "evidence": evidence]
  }
  private func recipe(_ total: Double = 18, _ difference: Double = 2, _ unit: String = "厘米") -> [String: Any] {
    ["id": "rectangle", "title": "长方形长宽与面积", "kind": "rectangle_sum_difference", "rectangle_evidence": "原题给出长方形",
      "total_sides": source(total, unit, "长方形长和宽之和是\(total)\(unit)"),
      "difference": source(difference, unit, "长比宽多\(difference)\(unit)")]
  }
  func testShapeCitationIsIndependentOfShortNumberCitationsAndCannotBeInferred() throws {
    var entry = recipe()
    entry["rectangle_evidence"] = "原题：长方形长和宽之和是18厘米"
    entry["total_sides"] = source(18, "厘米", "长和宽之和是18厘米")
    XCTAssertEqual(try MathRectangleSumDifferenceRecipe.compile(entry).fact("area")?.value, 80)
    for invalid in ["", "标题看起来是长方形", "如果是长方形", "不是长方形", "平行四边形"] {
      entry["rectangle_evidence"] = invalid
      XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(entry))
    }
  }

  func testOriginal18And2Derive10And8And80AndRenderPNG() throws {
    let diagram = try MathRectangleSumDifferenceRecipe.compile(recipe())
    XCTAssertEqual(diagram.kind, .area)
    XCTAssertEqual(diagram.factIDs, ["length", "width", "area"])
    XCTAssertEqual(diagram.fact("length")?.value, 10)
    XCTAssertEqual(diagram.fact("width")?.value, 8)
    XCTAssertEqual(diagram.fact("area")?.value, 80)
    XCTAssertEqual(diagram.fact("area")?.unit, "平方厘米")
    XCTAssertEqual(Set(diagram.facts.filter { $0.origin == .given }.map(\.id)), ["total_sides", "difference"])
    XCTAssertEqual(diagram.fact("two")?.origin, .constant)
    XCTAssertTrue(diagram.relations.contains { $0.operation == .product && $0.inputIDs == ["length", "width"] && $0.outputID == "area" })
    try MathDiagramAnswer.validateRendering(diagram)
    let explanation = try MathCheckedDiagramExplanation.text(for: diagram)
    for value in ["10", "8", "80", "平方厘米"] { XCTAssertTrue(explanation.contains(value)) }
    let png = try MathDiagramRenderer.renderPNG(diagram)
    XCTAssertFalse(png.isEmpty)
    if let path = ProcessInfo.processInfo.environment["MATH_RECTANGLE_RENDER_DIR"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try png.write(to: directory.appendingPathComponent("rectangle-18-2.png"))
    }
  }
  func testIndependent23And5AndDecimalLengths() throws {
    let diagram = try MathRectangleSumDifferenceRecipe.compile(recipe(23, 5, "米"))
    XCTAssertEqual(diagram.fact("length")?.value, 14)
    XCTAssertEqual(diagram.fact("width")?.value, 9)
    XCTAssertEqual(diagram.fact("area")?.value, 126)
    XCTAssertEqual(diagram.fact("area")?.unit, "平方米")
    let decimal = try MathRectangleSumDifferenceRecipe.compile(recipe(7.5, 2, "千米"))
    XCTAssertEqual(decimal.fact("length")?.value, 4.75)
    XCTAssertEqual(decimal.fact("width")?.value, 2.75)
    XCTAssertEqual(decimal.fact("area")?.value, 13.0625)
    XCTAssertEqual(decimal.fact("area")?.unit, "平方千米")
    try MathDiagramAnswer.validateRendering(decimal)
  }
  func testChineseNumeralsAndUnitAliases() throws {
    var item = recipe()
    item["total_sides"] = source(18, "cm", "长方形长与宽的和为十八厘米")
    item["difference"] = source(2, "厘米", "长比宽多二厘米")
    XCTAssertEqual(try MathRectangleSumDifferenceRecipe.compile(item).fact("area")?.value, 80)
    XCTAssertEqual(try MathRectangleSumDifferenceRecipe.compile(recipe(18, 0)).fact("area")?.value, 81)
  }
  func testRejectsPerimeterOtherSumsAreaAndFabricatedNumbers() {
    for citation in ["长方形周长是18厘米", "长方形长和宽之和由周长36厘米推得18厘米", "长方形两根绳子总和是18厘米", "正方形长和宽之和是18厘米", "长方形面积是18平方厘米", "长方形长和宽之和是19厘米，题号18", "长方形长和宽之和是36÷2=18厘米", "长方形长和宽之和是18米"] {
      var item = recipe(); item["total_sides"] = source(18, "厘米", citation)
      XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item), citation)
    }
    for citation in ["长是宽的2倍", "长方形面积是2平方厘米", "长比宽多3厘米，题号2", "宽比长多2厘米", "长比宽多2米", "长比宽多10-8=2厘米"] {
      var item = recipe(); item["difference"] = source(2, "厘米", citation)
      XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item), citation)
    }
    var item = recipe(); item["total_sides"] = source(18, "厘米", "长和宽之和是18厘米")
    item.removeValue(forKey: "rectangle_evidence")
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
  }
  func testRejectsNonfiniteBooleanNegativeInconsistentAndUnsupportedUnits() {
    for value: Any in [true, NSNull(), "18", Double.infinity, Double.nan, -1, 1e10] {
      var item = recipe(); item["total_sides"] = source(value, "厘米", "长方形长和宽之和是18厘米")
      XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
    }
    for difference in [-1.0, 18, 19] { XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(recipe(18, difference))) }
    for unit in ["平方厘米", "毫米", "岁", "", "cm²"] { XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(recipe(18, 2, unit))) }
    var item = recipe(); item["difference"] = source(2, "米", "长比宽多2米")
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(recipe(100_000, 2))) // area outside diagram range
  }
  func testRejectsExtraFieldsAndSubstitutedKind() {
    for field in ["area", "length", "width", "facts", "relations", "view"] {
      var item = recipe(); item[field] = 80
      XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
    }
    var item = recipe(); item["kind"] = "area"
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
    item = recipe(); item["difference"] = ["value": 2, "unit": "厘米", "evidence": "长比宽多2厘米", "origin": "given"]
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
    item = recipe(); item.removeValue(forKey: "difference")
    XCTAssertThrowsError(try MathRectangleSumDifferenceRecipe.compile(item))
  }
}
