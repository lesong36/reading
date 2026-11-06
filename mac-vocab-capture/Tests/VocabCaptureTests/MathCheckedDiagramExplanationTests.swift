import XCTest
@testable import VocabCapture

final class MathCheckedDiagramExplanationTests: XCTestCase {
  private func compile(_ recipe: [String: Any]) throws -> MathDiagram {
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [recipe]])
    struct Envelope: Decodable { let diagrams: [MathDiagram] }
    return try JSONDecoder().decode(Envelope.self, from: MathDiagramRecipe.normalizedEnvelope(data)).diagrams[0]
  }
  private func ratio(_ difference: Double = 72, unit: String = "", multiplier: Double = 10) throws -> MathDiagram {
    try compile(["id": "ratio", "title": "数量比较", "kind": "difference_ratio",
      "difference": ["value": difference, "unit": unit, "evidence": "原题两数相差\(difference)\(unit)"],
      "multiplier": ["value": multiplier, "evidence": "原题较大量是较小量的\(multiplier)倍"]])
  }
  func testDifferenceRecipeExplainsGroundedArithmeticAndRuleSeparately() throws {
    let text = try MathCheckedDiagramExplanation.text(for: ratio())
    XCTAssertTrue(text.contains("表示规则：较小量占一份取1"))
    XCTAssertTrue(text.contains("10−1＝9"))
    XCTAssertTrue(text.contains("72÷9＝8"))
    XCTAssertTrue(text.contains("8×10＝80"))
    XCTAssertTrue(text.contains("回算检查相差数量：80−8＝72"))
    XCTAssertTrue(text.contains("仍需用户核验"))
    XCTAssertFalse(text.contains("答案正确"))
  }
  func testDecimalPlacesAndUnitsAreNotRoundedAway() throws {
    let text = try MathCheckedDiagramExplanation.text(for: ratio(0.000001, unit: "米", multiplier: 2))
    XCTAssertTrue(text.contains("0.000001（米）÷1＝0.000001（米）"))
    XCTAssertTrue(text.contains("0.000001（米）×2＝0.000002（米）"))
    let second = try MathCheckedDiagramExplanation.text(for: ratio(1, unit: "千克", multiplier: 6))
    XCTAssertTrue(second.contains("1（千克）÷5＝0.2（千克）"))
  }
  func testShuffledRelationsUseDependencyOrder() throws {
    var diagram = try ratio()
    diagram.relations.reverse()
    let text = try MathCheckedDiagramExplanation.text(for: diagram)
    let first = try XCTUnwrap(text.range(of: "10−1＝9"))
    let second = try XCTUnwrap(text.range(of: "72÷9＝8"))
    let third = try XCTUnwrap(text.range(of: "8×10＝80"))
    XCTAssertLessThan(first.lowerBound, second.lowerBound)
    XCTAssertLessThan(second.lowerBound, third.lowerBound)
  }
  func testIncorrectGraphRejectsBeforeExplaining() throws {
    var diagram = try ratio()
    diagram.facts[diagram.facts.firstIndex(where: { $0.id == "larger" })!].value = 81
    XCTAssertThrowsError(try MathCheckedDiagramExplanation.text(for: diagram))
  }
  func testDistributionRecipeShowsCountsAndBothAllocationChecks() throws {
    let diagram = try compile(["id": "distribution", "title": "两次分配", "kind": "two_allocations",
      "item_unit": "张", "recipient_unit": "人", "allocations": [
        ["per_recipient": ["value": 25, "evidence": "每人25张"], "balance": ["kind": "extra_recipients", "value": 2, "evidence": "还能给2人"]],
        ["per_recipient": ["value": 27, "evidence": "每人27张"], "balance": ["kind": "exact", "evidence": "正好发完"]]]])
    let text = try MathCheckedDiagramExplanation.text(for: diagram)
    XCTAssertTrue(text.contains("25（人）"))
    XCTAssertTrue(text.contains("675（张）"))
    XCTAssertTrue(text.contains("50（张）"))
    XCTAssertTrue(text.contains("27（张/人）"))
  }
  func testCapturedPurchaseRecipeComparesWithoutForcingMethod() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "real-purchase-offers-20261013", withExtension: "json", subdirectory: "Fixtures"))
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let recipe: [String: Any]
    if let diagrams = object["diagrams"] as? [[String: Any]] { recipe = diagrams[0] }
    else { recipe = object }
    let diagram = try compile(recipe)
    let text = try MathCheckedDiagramExplanation.text(for: diagram)
    XCTAssertTrue(text.contains("2505（元）"))
    XCTAssertTrue(text.contains("2616（元）"))
    XCTAssertTrue(text.contains("差额为111（元）"))
    XCTAssertTrue(text.contains("A书店支付较少"))
    XCTAssertFalse(text.contains("归一"))
    XCTAssertFalse(text.contains("主解法"))
  }
  func testUnknownsRemainSymbolicWithoutInventingAnAnswer() throws {
    let diagram = MathDiagram(id: "u", title: "待定数量", kind: .barComparison,
      facts: [.init(id: "a", label: "已知数量", value: 3, unit: "米", evidence: "原题3米"),
        .init(id: "b", label: "待求数量", unit: "米", origin: .unknown)],
      relations: [.init(operation: .equal, inputIDs: ["a"], outputID: "b")], factIDs: ["a", "b"])
    let text = try MathCheckedDiagramExplanation.text(for: diagram)
    XCTAssertTrue(text.contains("数量关系（含未知量）"))
    XCTAssertTrue(text.contains("＝？（米）"))
    XCTAssertTrue(text.contains("未确定其数值"))
    XCTAssertFalse(text.contains("计算待求数量"))
  }
}
