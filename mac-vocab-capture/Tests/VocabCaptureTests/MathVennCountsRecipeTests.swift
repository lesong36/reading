import XCTest
@testable import VocabCapture

final class MathVennCountsRecipeTests: XCTestCase {
  private func q(_ value: Any, _ evidence: String, _ unit: String = "人") -> [String: Any] {
    ["value": value, "unit": unit, "evidence": evidence]
  }
  private func recipe(_ total: Int = 40, _ left: Int = 25, _ right: Int = 22, _ both: Int = 12,
    unit: String = "人") -> [String: Any] {
    ["id": "clubs", "title": "两个兴趣小组", "kind": "venn_counts",
      "total": q(total, "全班共有\(total)\(unit)", unit),
      "left": q(left, "参加绘画的有\(left)\(unit)", unit),
      "right": q(right, "参加唱歌的有\(right)\(unit)", unit),
      "intersection": q(both, "两项都参加的有\(both)\(unit)", unit)]
  }
  func testIndependentOracleGroundingAndActualPNG() throws {
    let d = try MathVennCountsRecipe.compile(recipe())
    XCTAssertEqual(d.kind, .venn)
    XCTAssertEqual(d.factIDs, ["left_only", "intersection", "right_only", "union", "outside", "total"])
    XCTAssertEqual(d.factIDs.compactMap { d.fact($0)?.value }, [13, 12, 10, 35, 5, 40])
    for key in ["total", "left", "right", "intersection"] { XCTAssertEqual(d.fact(key)?.origin, .given) }
    for key in ["left_only", "right_only", "union", "outside"] { XCTAssertEqual(d.fact(key)?.origin, .derived) }
    XCTAssertEqual(d.relations[2].inputIDs, ["left_only", "intersection", "right_only"])
    XCTAssertEqual(d.relations[4].inputIDs, ["union", "outside"])
    try d.validate()
    try MathDiagramAnswer.validateRendering(d)
    let png = try MathDiagramRenderer.renderPNG(d)
    XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
  }
  func testDisjointFullOverlapAndZeroBoundaries() throws {
    for (input, values) in [(recipe(40, 25, 15, 0), [25.0, 0, 15, 40, 0, 40]),
      (recipe(40, 25, 25, 25), [0.0, 25, 0, 25, 15, 40]),
      (recipe(0, 0, 0, 0), [0.0, 0, 0, 0, 0, 0])] {
      let d = try MathVennCountsRecipe.compile(input)
      XCTAssertEqual(d.factIDs.compactMap { d.fact($0)?.value }, values)
      try MathDiagramAnswer.validateRendering(d)
      XCTAssertFalse(try MathDiagramRenderer.renderPNG(d).isEmpty)
    }
    for unit in ["人", "个", "本", "只", "棵", "辆", "张"] {
      XCTAssertEqual(try MathVennCountsRecipe.compile(recipe(unit: unit)).fact("union")?.unit, unit)
    }
  }
  func testInclusiveMembershipAndIntersectionSemanticVariants() throws {
    var input = recipe()
    input["intersection"] = q(12, "既参加绘画又参加唱歌的有12人")
    XCTAssertEqual(try MathVennCountsRecipe.compile(input).fact("outside")?.value, 5)
    input["intersection"] = q(12, "12 people attend both activities")
    XCTAssertEqual(try MathVennCountsRecipe.compile(input).fact("outside")?.value, 5)
  }
  func testRejectsIndependentContradictionsAndUnitMismatch() {
    for input in [recipe(30), recipe(40, 10, 22, 12), recipe(40, 25, 10, 12), recipe(40, 41, 0, 0)] {
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
    var input = recipe(); input["right"] = q(22, "参加唱歌有22个", "个")
    XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
  }
  func testRejectsAmbiguousComputedExclusiveAndMisclassifiedSources() {
    for (key, evidence) in [("total", "参加绘画40人"), ("total", "两项共有40人"), ("total", "参加绘画共有40人"),
      ("left", "只参加绘画25人"), ("right", "仅唱歌22人"), ("left", "原题25人"),
      ("left", "没有参加绘画25人"), ("intersection", "原题12人"),
      ("intersection", "两项都不参加12人"), ("intersection", "两项互斥，共同12人"),
      ("intersection", "两项都参加25−13=12人"), ("intersection", "所以两项都参加12人"),
      ("intersection", "两项都参加10人")] {
      var input = recipe(); let value = key == "total" ? 40 : key == "left" ? 25 : key == "right" ? 22 : 12
      input[key] = q(value, evidence)
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input), evidence)
    }
  }
  func testRejectsNonFiniteBooleansFractionsOversizedAndUnknownValues() {
    for value: Any in [true, -1, 12.5, Double.infinity, Double.nan, 1_000_000_001, NSNull()] {
      var input = recipe(); input["intersection"] = q(value, "两项都参加12人")
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
    for unit in ["", "名", "米", "千人", " 人"] {
      var input = recipe(); input["intersection"] = q(12, "两项都参加12人", unit)
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
  }
  func testRejectsMissingAndInjectedCallerFields() {
    for key in ["total", "left", "right", "intersection", "id", "title"] {
      var input = recipe(); input.removeValue(forKey: key)
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
    for key in ["answer", "facts", "relations", "left_only"] {
      var input = recipe(); input[key] = 13
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
    for key in ["origin", "source", "inputIDs"] {
      var input = recipe(); var source = q(12, "两项都参加12人"); source[key] = "derived"; input["intersection"] = source
      XCTAssertThrowsError(try MathVennCountsRecipe.compile(input))
    }
  }
  func testTamperedDerivedResultFailsArithmetic() throws {
    var d = try MathVennCountsRecipe.compile(recipe())
    let i = try XCTUnwrap(d.facts.firstIndex { $0.id == "outside" }); d.facts[i].value = 6
    XCTAssertThrowsError(try d.validate())
  }
}
