import XCTest
@testable import VocabCapture

final class MathCycleRecipeTests: XCTestCase {
  private func entry(_ count: Double = 14, labels: [String] = ["红", "蓝", "绿"], evidence: String = "按红、蓝、绿依次重复排列") -> [String: Any] {
    ["id": "cycle", "title": "重复排列", "kind": "cyclic_pattern",
      "count": ["value": count, "evidence": "原题一共排列\(count)个"],
      "labels": labels, "pattern_evidence": evidence]
  }
  func testPeriodComesFromListedPositionsNotInventedGivenNumber() throws {
    let graph = try MathCycleRecipe.compile(entry())
    XCTAssertEqual(graph.kind, .cycle)
    XCTAssertEqual(graph.fact("period")?.value, 3)
    XCTAssertEqual(graph.fact("period")?.origin, .derived)
    XCTAssertEqual(graph.fact("cycles")?.value, 4)
    XCTAssertEqual(graph.fact("remainder")?.value, 2)
    XCTAssertEqual(graph.facts.filter { $0.origin == .given }.map(\.id), ["total"])
    XCTAssertTrue(graph.facts.filter { $0.origin == .constant }.allSatisfy { $0.value == 1 })
    XCTAssertEqual(graph.relations.first?.operation, .sum)
    try MathDiagramAnswer.validateRendering(graph)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(graph).isEmpty)
  }
  func testDuplicateLabelsAreDistinctPositionsAndSingleItemPeriodWorks() throws {
    let repeated = try MathCycleRecipe.compile(entry(labels: ["红", "红", "蓝"], evidence: "红、红、蓝"))
    XCTAssertEqual(repeated.columns, ["红", "红", "蓝"])
    XCTAssertEqual(repeated.fact("period")?.value, 3)
    let single = try MathCycleRecipe.compile(entry(labels: ["红"], evidence: "红"))
    XCTAssertEqual(single.fact("period")?.value, 1)
    XCTAssertEqual(single.fact("cycles")?.value, 14)
    XCTAssertEqual(single.fact("remainder")?.value, 0)
    try MathDiagramAnswer.validateRendering(single)
  }
  func testCitationCannotOmitReorderOrInventPositions() {
    for labels in [["蓝", "红", "绿"], ["红", "蓝"], ["蓝", "绿"], ["红", "黄", "绿"], ["红", "绿"]] {
      XCTAssertThrowsError(try MathCycleRecipe.compile(entry(labels: labels)))
    }
    XCTAssertThrowsError(try MathCycleRecipe.compile(entry(evidence: "红、黄、蓝、绿")))
    XCTAssertThrowsError(try MathCycleRecipe.compile(entry(evidence: "红、蓝、绿、黄")))
    XCTAssertThrowsError(try MathCycleRecipe.compile(entry(labels: ["蓝", "绿"], evidence: "红、 蓝、绿")))
    XCTAssertThrowsError(try MathCycleRecipe.compile(entry(evidence: "红、蓝、绿色")))
    XCTAssertThrowsError(try MathCycleRecipe.compile(entry(evidence: "粉红、蓝、绿")))
    XCTAssertNoThrow(try MathCycleRecipe.compile(entry(evidence: "依次红，蓝，绿")))
  }
  func testInvalidCountAndCalculatedEvidenceReject() {
    for count in [0.0, -1, 14.5, 1001, Double.infinity, Double.nan] {
      XCTAssertThrowsError(try MathCycleRecipe.compile(entry(count)))
    }
    for value: Any in [true, "14", NSNull()] {
      var item = entry(); item["count"] = ["value": value, "evidence": "14个"]
      XCTAssertThrowsError(try MathCycleRecipe.compile(item))
    }
    for evidence in ["共13个", "7+7=14", "共有7×2个，结果14", ""] {
      var item = entry(); item["count"] = ["value": 14, "evidence": evidence]
      XCTAssertThrowsError(try MathCycleRecipe.compile(item))
    }
  }
  func testExactSchemaAndBounds() throws {
    for key in ["period", "cycles", "remainder", "facts", "relations", "answer"] {
      var item = entry(); item[key] = 3
      XCTAssertThrowsError(try MathCycleRecipe.compile(item))
    }
    var nested = entry(); nested["count"] = ["value": 14, "evidence": "14个", "unit": "个"]
    XCTAssertThrowsError(try MathCycleRecipe.compile(nested))
    for labels in [[], Array(repeating: "红", count: 13), [""], [" 红"], [String(repeating: "红", count: 31)]] {
      XCTAssertThrowsError(try MathCycleRecipe.compile(entry(labels: labels)))
    }
    let labels = (1...12).map { "颜色\($0)" }
    let graph = try MathCycleRecipe.compile(entry(1000, labels: labels, evidence: labels.joined(separator: "、")))
    XCTAssertEqual(graph.fact("cycles")?.value, 83)
    XCTAssertEqual(graph.fact("remainder")?.value, 4)
    try MathDiagramAnswer.validateRendering(graph)
  }
}
