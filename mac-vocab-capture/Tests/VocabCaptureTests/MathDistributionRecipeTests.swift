import XCTest
@testable import VocabCapture

final class MathDistributionRecipeTests: XCTestCase {
  private func allocation(_ rate: Double, _ kind: String, _ value: Double? = nil) -> [String: Any] {
    var balance: [String: Any] = ["kind": kind, "evidence": kind == "exact" ? "正好发完" : "原题给出的余缺条件\(value ?? 0)"]
    if let value { balance["value"] = value }
    return ["per_recipient": ["value": rate, "evidence": "原题每人分配\(rate)张"], "balance": balance]
  }
  private func recipe(_ first: [String: Any], _ second: [String: Any], view: String = "table") -> [String: Any] {
    ["id": "allocations", "title": "同一批物品的两次分配", "kind": "two_allocations", "item_unit": "张", "recipient_unit": "人", "allocations": [first, second], "view": view]
  }
  private func compile(_ value: [String: Any]) throws -> MathDiagram {
    let envelope = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [value]])
    let normalized = try MathDiagramRecipe.normalizedEnvelope(envelope)
    struct Envelope: Decodable { let diagrams: [MathDiagram] }
    return try JSONDecoder().decode(Envelope.self, from: normalized).diagrams[0]
  }
  func testActualModelRecipientNounClassifierReplaysTo675WithOriginalTwoPeople() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "distribution-recipients-live-20261015", withExtension: "json", subdirectory: "Fixtures"))
    let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let diagram = try compile(entry)
    XCTAssertEqual(diagram.fact("recipients")?.value, 25)
    XCTAssertEqual(diagram.fact("recipients")?.unit, "人")
    XCTAssertEqual(diagram.fact("total")?.value, 675)
    XCTAssertEqual(diagram.fact("allocation_1_remaining_recipients")?.value, 2)
    XCTAssertEqual(diagram.fact("allocation_1_balance")?.origin, .derived)
    try MathDiagramAnswer.validateRendering(diagram)
  }

  func testActualRecipientClassifierAndOriginalRemainingPeopleComputeWithoutInvented50() throws {
    var first = allocation(25, "extra_recipients", 2)
    first["per_recipient"] = ["value": 25, "evidence": "每名同学发25张"]
    first["balance"] = ["kind": "extra_recipients", "value": 2, "evidence": "剩下的还能发给2名同学"]
    var entry = recipe(first, allocation(27, "exact"))
    entry["recipient_unit"] = "名"
    let diagram = try compile(entry)
    XCTAssertEqual(diagram.fact("recipients")?.value, 25)
    XCTAssertEqual(diagram.fact("recipients")?.unit, "人")
    XCTAssertEqual(diagram.fact("total")?.value, 675)
    XCTAssertEqual(diagram.fact("allocation_1_balance")?.origin, .derived)
    first["balance"] = ["kind": "surplus", "value": 50, "evidence": "剩下还能给2名同学，剩余总数=2×25=50张"]
    entry["allocations"] = [first, allocation(27, "exact")]
    XCTAssertThrowsError(try compile(entry))
  }

  func testRatesAndLiteralBalancesRequireMatchingUncomputedSourceNumbers() {
    var first = allocation(25, "surplus", 50)
    first["per_recipient"] = ["value": 25, "evidence": "每名同学发27张"]
    XCTAssertThrowsError(try compile(recipe(first, allocation(27, "exact"))))
    first = allocation(25, "surplus", 50)
    first["balance"] = ["kind": "surplus", "value": 50, "evidence": "还能给2名同学"]
    XCTAssertThrowsError(try compile(recipe(first, allocation(27, "exact"))))
  }

  func testOriginalLeftoverRecipientsCompilesUsefulTableWithoutModelArithmetic() throws {
    let diagram = try compile(recipe(allocation(25, "extra_recipients", 2), allocation(27, "exact")))
    XCTAssertEqual(diagram.kind, .table)
    XCTAssertEqual(diagram.fact("recipients")?.value, 25)
    XCTAssertEqual(diagram.fact("total")?.value, 675)
    XCTAssertEqual(diagram.fact("allocation_1_balance")?.value, 50)
    XCTAssertEqual(diagram.fact("allocation_1_balance")?.origin, .derived)
    XCTAssertEqual(diagram.fact("allocation_2_balance")?.origin, .given)
    XCTAssertTrue(diagram.facts.filter { $0.origin == .constant }.isEmpty)
    XCTAssertEqual(diagram.rows.count, 2)
    XCTAssertEqual(diagram.columns.count, 5)
    try MathDiagramAnswer.validateRendering(diagram)
    if let directory = ProcessInfo.processInfo.environment["MATH_DISTRIBUTION_ARTIFACTS"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try MathDiagramRenderer.renderPNG(diagram).write(to: URL(fileURLWithPath: directory).appendingPathComponent("distribution-table.png"))
    }
  }
  func testRecipeParsesThroughActualAnswerEnvelopeAndRejectsDuplicateQuestionIDs() throws {
    let item = recipe(allocation(25, "extra_recipients", 2), allocation(27, "exact"))
    func parse(_ items: [[String: Any]]) throws -> MathDiagramAnswer.Result {
      let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": items])
      return MathDiagramAnswer.parse("解题正文\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
    }
    let result = try parse([item])
    XCTAssertNil(result.failure)
    XCTAssertEqual(result.diagrams.count, 1)
    XCTAssertEqual(result.diagrams.first?.id, "allocations")
    XCTAssertEqual(result.text, "解题正文")
    let duplicate = try parse([item, item])
    XCTAssertNotNil(duplicate.failure)
    XCTAssertTrue(duplicate.diagrams.isEmpty)
  }
  func testGroupingUsesUnitBoundLabelsAndDistinctTotalDerivations() throws {
    var grouped = recipe(allocation(25, "extra_recipients", 2), allocation(27, "exact"))
    grouped["recipient_unit"] = "组"
    let diagram = try compile(grouped)
    XCTAssertEqual(diagram.columns[0], "每组分配")
    XCTAssertEqual(diagram.fact("recipients")?.label, "接收者数量")
    XCTAssertEqual(diagram.fact("recipients")?.unit, "组")
    XCTAssertFalse(diagram.columns.contains { $0.contains("人") })
    XCTAssertFalse(diagram.facts.contains { $0.label.contains("每人") || $0.label.contains("人数") })
    let totals = diagram.relations.filter { $0.outputID == "total" }
    XCTAssertEqual(totals.count, 2)
    XCTAssertEqual(Set(totals.map { $0.inputIDs.joined(separator: ",") }).count, 2)
    try MathDiagramAnswer.validateRendering(diagram)
  }
  func testGeneralSurplusShortfallAndSameSignCasesWithReversedOrder() throws {
    let cases: [([String: Any], [String: Any], Double, Double)] = [
      (allocation(3, "surplus", 10), allocation(5, "shortfall", 10), 10, 40),
      (allocation(3, "surplus", 20), allocation(5, "surplus", 10), 5, 35),
      (allocation(3, "shortfall", 5), allocation(5, "shortfall", 15), 5, 10),
      (allocation(3, "exact"), allocation(5, "missing_recipients", 2), 5, 15),
    ]
    for (first, second, count, total) in cases {
      for pair in [[first, second], [second, first]] {
        for view in ["table", "bar_comparison"] {
          let diagram = try compile(recipe(pair[0], pair[1], view: view))
          XCTAssertEqual(diagram.fact("recipients")?.value, count)
          XCTAssertEqual(diagram.fact("total")?.value, total)
          try diagram.validate()
          try MathDiagramAnswer.validateRendering(diagram)
        }
      }
    }
  }
  func testNoHardcodedValuesAcrossIndependentDistributionOracle() throws {
    for count in [1, 3, 12, 37] {
      for firstRate in [1, 4, 9] {
        let secondRate = firstRate + 3
        let total = count * firstRate + 2
        let shortage = count * secondRate - total
        let diagram = try compile(recipe(allocation(Double(firstRate), "surplus", 2), allocation(Double(secondRate), "shortfall", Double(shortage))))
        XCTAssertEqual(diagram.fact("recipients")?.value, Double(count))
        XCTAssertEqual(diagram.fact("total")?.value, Double(total))
      }
    }
  }
  func testRejectsConflictsNonintegralRecipientsAndMissingOriginalConditions() {
    let bad = [
      recipe(allocation(25, "surplus", 3), allocation(27, "exact")),
      recipe(allocation(25, "exact"), allocation(25, "exact")),
      recipe(allocation(25, "shortfall", 2), allocation(27, "exact")),
      recipe(allocation(25, "extra_recipients", 2.5), allocation(27, "exact")),
      recipe(allocation(25, "surplus", 10), allocation(27, "surplus", 20)),
      recipe(allocation(3, "shortfall", 100), allocation(5, "shortfall", 110)),
      recipe(allocation(25.5, "surplus", 50), allocation(27.5, "exact")),
    ]
    for item in bad { XCTAssertThrowsError(try compile(item)) }
  }
  func testRejectsModelAnswersRolesLayoutsAndMissingEvidence() {
    let base = recipe(allocation(25, "extra_recipients", 2), allocation(27, "exact"))
    for key in ["recipients", "total", "facts", "relations", "layout"] {
      var item = base; item[key] = 25
      XCTAssertThrowsError(try compile(item))
    }
    for evidence in ["", String(repeating: "原", count: 501)] {
      var first = allocation(25, "extra_recipients", 2)
      var balance = first["balance"] as! [String: Any]; balance["evidence"] = evidence; first["balance"] = balance
      XCTAssertThrowsError(try compile(recipe(first, allocation(27, "exact"))))
    }
    for key in ["id", "title"] {
      for invalid in ["", String(repeating: "原", count: 121)] {
        var item = base; item[key] = invalid
        XCTAssertThrowsError(try compile(item))
      }
      var missing = base; missing.removeValue(forKey: key)
      XCTAssertThrowsError(try compile(missing))
    }
    var exact = allocation(27, "exact"); exact["balance"] = ["kind": "exact", "evidence": "剩余未知"]
    XCTAssertThrowsError(try compile(recipe(allocation(25, "extra_recipients", 2), exact)))
    var extra = allocation(25, "extra_recipients", 2); extra["balance"] = ["kind": "extra_recipients", "value": true, "evidence": "原题"]
    XCTAssertThrowsError(try compile(recipe(extra, allocation(27, "exact"))))
  }
}
