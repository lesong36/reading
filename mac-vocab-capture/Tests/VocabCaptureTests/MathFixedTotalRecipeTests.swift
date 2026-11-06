import XCTest
@testable import VocabCapture

final class MathFixedTotalRecipeTests: XCTestCase {
  func testRecordedProviderResponseWithPerItemCitationPassesFullDiagramAndExplanationPath() throws {
    let path = try XCTUnwrap(Bundle.module.url(forResource:"RealFixedTotalResponse20261014", withExtension:"txt", subdirectory:"Fixtures"))
    let source = try String(contentsOf:path,encoding:.utf8)
    let parsed = MathStructuredSolution.parse(source,candidates:[])
    XCTAssertNil(parsed.failure)
    let checked = MathDiagramAnswer.parse(parsed.answer)
    XCTAssertNil(checked.failure)
    let diagram = try XCTUnwrap(checked.diagrams.first)
    XCTAssertEqual(diagram.fact("improved_count")?.value,904)
    XCTAssertTrue(try MathCheckedDiagramExplanation.text(for:diagram).contains("904"))
  }
  private func recipe(per: Double = 3.2, count: Double = 791, changed: Double = 2.8,
    resource: String = "米", item: String = "套") -> [String: Any] {
    func source(_ value: Double, _ unit: String, _ evidence: String) -> [String: Any] {
      ["value": value, "unit": unit, "evidence": evidence]
    }
    return ["id":"cloth", "title":"同一批布的两种用量", "kind":"fixed_total",
      "resource_unit":resource, "count_unit":item,
      "original_per_item":source(per, resource + "/" + item, "原来每\(item)用\(per)\(resource)"),
      "original_count":source(count, item, "原来做\(count)\(item)"),
      "improved_per_item":source(changed, resource + "/" + item, "现在每\(item)用\(changed)\(resource)"),
      "conservation_evidence":"原来做791套的布，现在可做多少套？"]
  }

  func testOriginalClothConservesResourceAndRendersComparison() throws {
    let diagram = try MathFixedTotalRecipe.compile(recipe())
    XCTAssertEqual(diagram.kind, .table)
    XCTAssertEqual(try XCTUnwrap(diagram.fact("total_resource")?.value), 2531.2, accuracy: 1e-9)
    XCTAssertEqual(diagram.fact("improved_count")?.value, 904)
    XCTAssertEqual(diagram.fact("improved_count")?.unit, "套")
    XCTAssertEqual(diagram.fact("improved_count")?.origin, .derived)
    XCTAssertEqual(diagram.rows.count, 2)
    try diagram.validate()
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
  }

  func testObservedBareResourceUnitOnlyNormalizesWhenCitationExplicitlySaysPerItem() throws {
    var input = recipe()
    for key in ["original_per_item", "improved_per_item"] {
      var value = try XCTUnwrap(input[key] as? [String:Any])
      value["unit"] = "米"; input[key] = value
    }
    let diagram = try MathFixedTotalRecipe.compile(input)
    XCTAssertEqual(diagram.fact("original_per_item")?.unit,"米/套")
    XCTAssertEqual(diagram.fact("improved_count")?.value,904)
    var ambiguous = try XCTUnwrap(input["original_per_item"] as? [String:Any])
    ambiguous["evidence"] = "原来用布3.2米"
    input["original_per_item"] = ambiguous
    XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
  }

  func testMeaningfulResourceAlternativesAndIncreasedPerItem() throws {
    for (per, count, changed, resource, item, expected) in [
      (0.5, 40.0, 0.25, "升", "瓶", 80.0),
      (3.0, 20.0, 5.0, "千克", "袋", 12.0),
      (12.0, 10.0, 12.0, "平方米", "块", 10.0),
    ] {
      var input = recipe(per: per, count: count, changed: changed, resource: resource, item: item)
      input["conservation_evidence"] = "仍使用同一批资源，资源总量不变"
      let diagram = try MathFixedTotalRecipe.compile(input)
      XCTAssertEqual(diagram.fact("improved_count")?.value, expected)
      try diagram.validate()
    }
  }

  func testRejectsFractionalCountsWithoutRounding() {
    for input in [recipe(per: 3, count: 10, changed: 7), recipe(count: 791.5),
      recipe(per: 1.000000000001, count: 999_000_000, changed: 1)] {
      XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    }
  }

  func testRejectsNonOriginalOrInvalidQuantitySources() {
    for source: [String: Any] in [
      ["value":true, "unit":"米/套", "evidence":"原来每套3.2米"],
      ["value":0, "unit":"米/套", "evidence":"原题0米"],
      ["value":-2.8, "unit":"米/套", "evidence":"原题-2.8米"],
      ["value":Double.infinity, "unit":"米/套", "evidence":"无限"],
      ["value":2.8, "unit":"米/套", "evidence":"原来每套3.2米"],
      ["value":2.8, "unit":"米/套", "evidence":"3.2-0.4=2.8米"],
      ["value":2.8, "unit":"米/套", "evidence":""],
      ["value":2.8, "unit":"米/套", "evidence":"每套2.8米", "answer":904],
    ] {
      var input = recipe(); input["improved_per_item"] = source
      XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    }
  }

  func testRejectsMixedOrUnsupportedUnitsAndCalculatedFields() {
    var input = recipe(); input["improved_per_item"] = ["value":280, "unit":"厘米/套", "evidence":"每套280厘米"]
    XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    input = recipe(resource: "吨")
    XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    input = recipe(item: "人")
    XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    input = recipe(); input["answer"] = 904
    XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
  }

  func testRejectsAmbiguousChangedResourceAndArithmeticConservation() {
    for text in ["原来做791套，现在用另一批布", "另买了布，原来的总量增加", "同一批布总量不一定不变",
      "不是原来做791套的布，现在可做多少套？", "原来做791套的布，现在另买布可做多少套？",
      "同一批布仍用，剩余材料另算", "同一批布总量不变=2531.2米"] {
      var input = recipe(); input["conservation_evidence"] = text
      XCTAssertThrowsError(try MathFixedTotalRecipe.compile(input))
    }
  }

  func testStructuralArithmeticStillRejectsTampering() throws {
    let original = try MathFixedTotalRecipe.compile(recipe())
    let facts = original.facts.map { fact in
      fact.id == "improved_count" ? MathDiagram.Fact(id:fact.id, label:fact.label, value:905, unit:fact.unit, origin:.derived) : fact
    }
    let changed = MathDiagram(id:original.id, title:original.title, kind:original.kind,
      facts:facts, relations:original.relations, columns:original.columns, rows:original.rows)
    XCTAssertThrowsError(try changed.validate())
  }
}
