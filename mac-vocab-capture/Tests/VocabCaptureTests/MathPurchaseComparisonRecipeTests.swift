import XCTest
@testable import VocabCapture

final class MathPurchaseComparisonRecipeTests: XCTestCase {
  private func fact(_ value: Double) -> [String: Any] { ["value": value, "evidence": "原题明确给出\(value)"] }
  private func recipe(count: Double = 245, price: Double = 12, threshold: Double = 100, reduction: Double = 15, paid: Double = 8, free: Double = 1) -> [String: Any] {
    ["id": "offers", "title": "同一商品恰好数量的优惠比较", "kind": "purchase_comparison",
      "item_unit": "本", "currency_unit": "元", "quantity_policy": "exact_required_quantity",
      "required_count": fact(count), "unit_price": fact(price), "offers": [
        ["name": "A", "kind": "threshold_reduction", "threshold": fact(threshold), "reduction": fact(reduction)],
        ["name": "B", "kind": "buy_get", "paid": fact(paid), "free": fact(free)],
      ]]
  }
  func testOriginal245BooksUsesIndependentOfferArithmeticAndRenders() throws {
    let diagram = try MathPurchaseComparisonRecipe.compile(recipe())
    XCTAssertEqual(diagram.fact("offer_1_payment")?.value, 2505)
    XCTAssertEqual(diagram.fact("offer_2_payment")?.value, 2616)
    XCTAssertEqual(diagram.fact("offer_1_groups")?.value, 29)
    XCTAssertEqual(diagram.fact("offer_2_groups")?.value, 27)
    XCTAssertEqual(diagram.fact("offer_2_remainder")?.value, 2)
    XCTAssertEqual(diagram.fact("offer_2_paid_count")?.value, 218)
    XCTAssertEqual(diagram.fact("payment_difference")?.value, 111)
    XCTAssertTrue(diagram.facts.filter { $0.origin == .constant }.isEmpty)
    XCTAssertEqual(diagram.facts.filter { $0.origin == .given }.count, 6)
    try MathDiagramAnswer.validateRendering(diagram)
    if let directory = ProcessInfo.processInfo.environment["MATH_PURCHASE_ARTIFACTS"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try MathDiagramRenderer.renderPNG(diagram).write(to: URL(fileURLWithPath: directory).appendingPathComponent("purchase-comparison.png"))
    }
  }
  func testRecipeAcceptedByActualAnswerParserAsCheckedTable() throws {
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [recipe()]])
    let result = MathDiagramAnswer.parse("按两种优惠比较实付，主方法不强行归类。\n```math-diagrams\n" + String(decoding: data, as: UTF8.self) + "\n```")
    XCTAssertNil(result.failure)
    XCTAssertEqual(result.diagrams.count, 1)
    XCTAssertEqual(result.diagrams[0].kind, .table)
    XCTAssertEqual(result.diagrams[0].fact("offer_1_payment")?.value, 2505)
    XCTAssertEqual(result.diagrams[0].fact("offer_2_payment")?.origin, .derived)
  }
  func testCapturedModelLongStoreNamesRemainReadableWithoutWeakeningArithmetic() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "real-purchase-offers-20261013", withExtension: "json", subdirectory: "Fixtures"))
    let json = try String(contentsOf: url, encoding: .utf8)
    let result = MathDiagramAnswer.parse("比较实际支付\n```math-diagrams\n" + json + "\n```")
    XCTAssertNil(result.failure)
    let diagram = try XCTUnwrap(result.diagrams.first)
    XCTAssertEqual(diagram.rows.map(\.label), ["A书店", "B书店"])
    XCTAssertEqual(diagram.fact("offer_1_payment")?.value, 2505)
    XCTAssertEqual(diagram.fact("offer_2_payment")?.value, 2616)
    XCTAssertEqual(diagram.fact("payment_difference")?.value, 111)
    try MathDiagramAnswer.validateRendering(diagram)
    var corrupted = diagram
    let index = try XCTUnwrap(corrupted.facts.firstIndex { $0.id == "offer_2_bundle" })
    corrupted.facts[index].value = 10
    XCTAssertThrowsError(try MathDiagramRenderer.size(corrupted), "Undisplayed intermediate relations still require arithmetic validation")
    if let directory = ProcessInfo.processInfo.environment["MATH_PURCHASE_ARTIFACTS"] {
      try MathDiagramRenderer.renderPNG(diagram).write(to: URL(fileURLWithPath: directory).appendingPathComponent("captured-store-names.png"))
    }
  }
  func test25GiftRegimesAgainstEnumeratedExactQuantityOracle() throws {
    for paid in 1...5 {
      for free in 1...5 {
        for count in 1...40 {
          // Independent oracle: every purchased item contributes a gift after
          // each paid-sized block. No surplus gifts or gift rejection allowed.
          let feasiblePaid = (0...count).filter { $0 + ($0 / paid) * free == count }
          let remainder = count % (paid + free)
          if remainder >= paid {
            XCTAssertTrue(feasiblePaid.isEmpty)
            XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(recipe(count: Double(count), paid: Double(paid), free: Double(free))))
          } else {
            let diagram = try MathPurchaseComparisonRecipe.compile(recipe(count: Double(count), paid: Double(paid), free: Double(free)))
            XCTAssertEqual(diagram.fact("offer_2_paid_count")?.value, Double(try XCTUnwrap(feasiblePaid.min())))
            let baseline = count * 12
            XCTAssertEqual(diagram.fact("offer_1_payment")?.value, Double(baseline - (baseline / 100) * 15))
          }
        }
      }
    }
  }
  func testThresholdBoundaryDoesNotReapplyDiscountRecursively() throws {
    for (count, expectedGroups) in [(8.0, 0.0), (9, 1), (25, 3), (26, 3)] {
      let diagram = try MathPurchaseComparisonRecipe.compile(recipe(count: count, paid: 50, free: 1))
      XCTAssertEqual(diagram.fact("offer_1_groups")?.value, expectedGroups)
      XCTAssertEqual(diagram.fact("offer_1_payment")?.value, count * 12 - expectedGroups * 15)
    }
  }
  func testRejectsUnsupportedQuantityPolicyStackingInventedAnswersAndSourceFormats() {
    let base = recipe()
    for key in ["payment", "cheapest", "facts", "relations", "layout", "stacking"] {
      var item = base; item[key] = 1
      XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(item))
    }
    for policy in ["at_least", "overbuy_allowed", "decline_gifts", ""] {
      var item = base; item["quantity_policy"] = policy
      XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(item))
    }
    for key in ["required_count", "unit_price"] {
      for value: Any in [true, "12", NSNull(), 0, -1, 0.5] {
        var item = base; item[key] = ["value": value, "evidence": "原题"]
        XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(item))
      }
      for evidence: Any in ["", String(repeating: "原", count: 501), NSNull()] {
        var item = base; item[key] = ["value": 245, "evidence": evidence]
        XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(item))
      }
    }
    XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(recipe(reduction: 100)))
    XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(recipe(count: 8))) // r == paid: would get an extra book
    var offers = base["offers"] as! [[String: Any]]; offers[1]["name"] = "A"
    var duplicate = base; duplicate["offers"] = offers
    XCTAssertThrowsError(try MathPurchaseComparisonRecipe.compile(duplicate))
  }
}
