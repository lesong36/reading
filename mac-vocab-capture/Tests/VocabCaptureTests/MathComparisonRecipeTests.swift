import XCTest
@testable import VocabCapture

final class MathComparisonRecipeTests: XCTestCase {
  func testRecordedSubmissionUsesDimensionlessMultiplierNotation() throws {
    let file = try XCTUnwrap(Bundle.module.url(forResource: "RealSumRatioResponse20261014", withExtension: "txt", subdirectory: "Fixtures"))
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String:Any])
    let recipe = try XCTUnwrap((envelope["diagrams"] as? [[String:Any]])?.first)
    let diagram = try MathComparisonRecipe.compile(recipe)
    XCTAssertEqual(diagram.fact("smaller")?.value, 62)
    XCTAssertEqual(diagram.fact("larger")?.value, 186)
    XCTAssertEqual(diagram.fact("multiplier")?.unit, "")
    try MathDiagramAnswer.validateRendering(diagram)
  }
  private func source(_ value: Double, _ unit: String, _ evidence: String) -> [String: Any] {
    ["value": value, "unit": unit, "evidence": evidence]
  }
  private func sumDifference() -> [String: Any] {
    ["id": "sd", "title": "和差比较", "kind": "sum_difference",
      "total": source(98, "本", "两人一共有98本"), "difference": source(6, "本", "甲比乙多6本")]
  }
  private func sumRatio() -> [String: Any] {
    ["id": "sr", "title": "杏树和桃树", "kind": "sum_ratio",
      "total": source(248, "棵", "杏树和桃树共248棵"), "multiplier": source(3, "", "桃树是杏树3倍")]
  }
  private func transfer() -> [String: Any] {
    ["id": "et", "title": "甲移给乙后相等", "kind": "equalize_transfer",
      "larger": source(38, "本", "甲有38本"), "smaller": source(22, "本", "乙有22本"),
      "equality_evidence": "甲给乙多少本使两人一样多"]
  }
  func testSumDifferenceDerives52And46AndRenders() throws {
    let diagram = try MathComparisonRecipe.compile(sumDifference())
    XCTAssertEqual(diagram.kind, .barComparison)
    XCTAssertEqual(diagram.fact("larger")?.value, 52)
    XCTAssertEqual(diagram.fact("smaller")?.value, 46)
    XCTAssertEqual(diagram.fact("difference")?.origin, .given)
    XCTAssertEqual(diagram.fact("two")?.origin, .constant)
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
  }
  func testSumRatioDoesNotTreatTotal248AsDifference() throws {
    let diagram = try MathComparisonRecipe.compile(sumRatio())
    XCTAssertEqual(diagram.kind, .equalParts)
    XCTAssertEqual(diagram.fact("smaller")?.value, 62)
    XCTAssertEqual(diagram.fact("larger")?.value, 186)
    XCTAssertEqual(diagram.parts, [1, 3])
    XCTAssertNil(diagram.fact("difference"))
    XCTAssertEqual(diagram.fact("total_parts")?.origin, .derived)
    try MathDiagramAnswer.validateRendering(diagram)
    let png = try MathDiagramRenderer.renderPNG(diagram)
    XCTAssertFalse(png.isEmpty)
    if let directory = ProcessInfo.processInfo.environment["MATH_COMPARISON_RENDER_DIR"] {
      let output = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try png.write(to: output.appendingPathComponent("sum-ratio-248.png"))
    }
  }
  func testTransferUsesOriginalHoldingsAndNativeDifferenceAndHalf() throws {
    let diagram = try MathComparisonRecipe.compile(transfer())
    XCTAssertEqual(diagram.kind, .balance)
    XCTAssertEqual(diagram.fact("mean")?.value, 30)
    XCTAssertEqual(diagram.fact("transfer")?.value, 8)
    XCTAssertEqual(diagram.fact("difference")?.value, 16)
    XCTAssertEqual(diagram.fact("difference")?.origin, .derived)
    XCTAssertEqual(Set(diagram.facts.filter { $0.origin == .given }.map(\.id)), ["larger", "smaller"])
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
  }
  func testChineseNumeralsAcceptedAndMismatchedCitationsRejected() throws {
    var ratio = sumRatio()
    ratio["total"] = source(248, "棵", "两类树共二百四十八棵")
    ratio["multiplier"] = source(3, "", "桃树是杏树三倍")
    XCTAssertEqual(try MathComparisonRecipe.compile(ratio).fact("smaller")?.value, 62)
    ratio["multiplier"] = source(3, "", "桃树是杏树四倍")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(ratio))
    var item = transfer(); item["larger"] = source(38, "本", "甲有三十七本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
  }
  func testPremiseRolesAndCalculatedSourcesCannotMasqueradeAsOriginals() {
    var item = sumRatio(); item["total"] = source(248, "棵", "桃树比杏树多248棵")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumRatio(); item["multiplier"] = source(3, "", "剩下3棵")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumDifference(); item["difference"] = source(6, "本", "两人共有6本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = transfer(); item["larger"] = source(16, "本", "38-22=16本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    for premise in ["甲和乙一样多", "甲给乙一本", "甲给乙使相等但有损耗", "甲半数给乙使相等"] {
      item = transfer(); item["equality_evidence"] = premise
      XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    }
  }
  func testInvalidAndContradictoryNumbersUnitsAndFractionalCountsReject() {
    for value: Any in [true, NSNull(), "98", -1, Double.infinity] {
      var item = sumDifference(); item["total"] = ["value": value, "unit": "本", "evidence": "共98本"]
      XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    }
    var item = sumDifference(); item["difference"] = source(100, "本", "甲比乙多100本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumDifference(); item["difference"] = source(5, "本", "甲比乙多5本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item)) // 46.5 books is impossible.
    item = transfer(); item["smaller"] = source(40, "本", "乙有40本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = transfer(); item["smaller"] = source(23, "本", "乙有23本")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item)) // 7.5 books cannot be transferred.
    item = sumRatio(); item["multiplier"] = source(21, "", "桃树是杏树21倍")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumRatio(); item["multiplier"] = source(3, "岁", "桃树是杏树3倍")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumDifference(); item["difference"] = source(6, "元", "甲比乙多6元")
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
  }
  func testContinuousQuantitiesAndEqualInitialHoldings() throws {
    var item = sumDifference()
    item["total"] = source(7.5, "米", "两段总长7.5米")
    item["difference"] = source(2, "米", "长段比短段多2米")
    let diagram = try MathComparisonRecipe.compile(item)
    XCTAssertEqual(diagram.fact("larger")?.value, 4.75)
    XCTAssertEqual(diagram.fact("smaller")?.value, 2.75)
    item = transfer(); item["smaller"] = source(38, "本", "乙有38本")
    XCTAssertEqual(try MathComparisonRecipe.compile(item).fact("transfer")?.value, 0)
  }
  func testUnsupportedFieldsAndKindsReject() {
    for key in ["answer", "facts", "relations", "view"] {
      var item = sumRatio(); item[key] = 62
      XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    }
    var item = sumRatio(); item["kind"] = "difference_ratio"
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
    item = sumRatio(); item["total"] = ["value": 248, "unit": "棵", "evidence": "共248棵", "origin": "given"]
    XCTAssertThrowsError(try MathComparisonRecipe.compile(item))
  }
}
