import XCTest
@testable import VocabCapture

/// Fixed arithmetic examples are deliberately independent of AI and renderer implementation.
enum MathDiagramFixtures {
  static func given(_ id: String, _ label: String, _ value: Double, _ unit: String = "人") -> MathDiagram.Fact {
    .init(id: id, label: label, value: value, unit: unit, origin: .given, evidence: "本题给定\(label)为\(value)\(unit)")
  }
  static func derived(_ id: String, _ label: String, _ value: Double, _ unit: String = "人") -> MathDiagram.Fact {
    .init(id: id, label: label, value: value, unit: unit, origin: .derived)
  }
  static let bar = MathDiagram(id: "sum-difference", title: "和差问题：先比较数量", kind: .barComparison,
    facts: [given("a", "甲班", 45), given("b", "乙班", 27), derived("difference", "相差人数", 18), derived("total", "总人数", 72)],
    relations: [.init(operation: .difference, inputIDs: ["a", "b"], outputID: "difference"), .init(operation: .sum, inputIDs: ["a", "b"], outputID: "total")], factIDs: ["a", "b"])
  static let unknown = MathDiagram(id: "unknown", title: "同一组两量的和与差", kind: .barComparison,
    facts: [.init(id: "a", label: "较多人数", unit: "人", origin: .unknown), .init(id: "b", label: "较少人数", unit: "人", origin: .unknown), given("total", "总人数", 72), given("difference", "人数差", 18)],
    relations: [.init(operation: .sum, inputIDs: ["a", "b"], outputID: "total"), .init(operation: .difference, inputIDs: ["a", "b"], outputID: "difference")], factIDs: ["a", "b"])
  static let parts = MathDiagram(id: "parts", title: "甲是乙的三倍", kind: .equalParts,
    facts: [given("a", "甲人数", 60), given("multiple", "倍数", 3, ""), derived("b", "乙人数", 20)],
    relations: [.init(operation: .quotient, inputIDs: ["a", "multiple"], outputID: "b")], factIDs: ["a", "b"], parts: [3, 1])
  static let state = MathDiagram(id: "state", title: "先减少，再增加", kind: .state,
    facts: [given("original", "原来", 100), given("departure", "离开", 30), given("arrival", "到来", 20), derived("middle", "离开之后", 70), derived("final", "最后", 90)],
    relations: [.init(operation: .difference, inputIDs: ["original", "departure"], outputID: "middle"), .init(operation: .sum, inputIDs: ["middle", "arrival"], outputID: "final")], factIDs: ["original", "middle", "final"])
  static let table = MathDiagram(id: "table", title: "分纸方案比较：总数相同", kind: .table,
    facts: [given("rate1", "方案一每人张数", 25, "张/人"), given("rate2", "方案二每人张数", 27, "张/人"), given("left", "余下张数", 50, "张"), derived("rateDifference", "每人相差张数", 2, "张/人"), derived("count", "人数", 25), derived("used1", "方案一发出", 625, "张"), derived("total", "总张数", 675, "张")],
    relations: [.init(operation: .difference, inputIDs: ["rate2", "rate1"], outputID: "rateDifference"), .init(operation: .quotient, inputIDs: ["left", "rateDifference"], outputID: "count"), .init(operation: .product, inputIDs: ["rate1", "count"], outputID: "used1"), .init(operation: .product, inputIDs: ["rate2", "count"], outputID: "total"), .init(operation: .sum, inputIDs: ["used1", "left"], outputID: "total")], columns: ["每人张数", "人数", "发出纸张"], rows: [.init(label: "方案一", factIDs: ["rate1", "count", "used1"]), .init(label: "方案二", factIDs: ["rate2", "count", "total"])])
  static let area = MathDiagram(id: "area", title: "14 × 13 的面积分块", kind: .area,
    facts: [given("length", "长", 14, "cm"), given("width", "宽", 13, "cm"), derived("area", "面积", 182, "cm²")],
    relations: [.init(operation: .product, inputIDs: ["length", "width"], outputID: "area")], factIDs: ["length", "width", "area"], parts: [10, 10])
  static let interval = MathDiagram(id: "stairs-native", title: "楼梯间隔：楼层是点，台阶在两层之间", kind: .interval,
    facts: [given("start", "起点楼层", 1, ""), given("end", "终点楼层", 14, ""),
      derived("count", "楼层间隔数", 13, ""), given("per", "每段台阶数", 21, "级"), derived("total", "台阶总数", 273, "级")],
    relations: [.init(operation: .difference, inputIDs: ["end", "start"], outputID: "count"),
      .init(operation: .product, inputIDs: ["count", "per"], outputID: "total")], factIDs: ["start", "end", "count", "per", "total"])
  static let all = [bar, unknown, parts, state, table, area, interval]
}

final class MathDiagramTests: XCTestCase {
  func testRectangleRequiresDirectProductOrCorrectlyOrientedInverseNotCoincidentValues() {
    let facts = ["a", "b", "total", "other"].map { MathDiagramFixtures.given($0, $0, 1, "") }
    for relation in [
      MathDiagram.Relation(operation: .quotient, inputIDs: ["a", "total"], outputID: "b"),
      .init(operation: .product, inputIDs: ["a", "other"], outputID: "total"),
      .init(operation: .equal, inputIDs: ["a"], outputID: "b"),
    ] {
      let diagram = MathDiagram(id: "bad", title: "数值相同不证明布局关系", kind: .area,
        facts: facts, relations: [relation], factIDs: ["a", "b", "total"])
      XCTAssertThrowsError(try diagram.validate())
    }
  }
  func testIntervalRequiresActualEndpointDifferenceAndGroundedTotal() throws {
    try MathDiagramFixtures.interval.validate()
    var reversedProduct = MathDiagramFixtures.interval
    reversedProduct.relations[1].inputIDs = ["per", "count"]
    try reversedProduct.validate()
    var wrong = MathDiagramFixtures.interval
    wrong.facts[2].value = 14; wrong.facts[4].value = 294
    XCTAssertThrowsError(try wrong.validate())
    wrong = MathDiagramFixtures.interval
    wrong.facts.append(MathDiagramFixtures.given("unrelated", "其他数量", 13, ""))
    wrong.relations[0] = .init(operation: .equal, inputIDs: ["unrelated"], outputID: "count")
    XCTAssertThrowsError(try wrong.validate())
    wrong = MathDiagramFixtures.interval
    wrong.facts[0].origin = .constant
    XCTAssertThrowsError(try wrong.validate())
    wrong = MathDiagramFixtures.interval
    wrong.parts = [13]
    XCTAssertThrowsError(try wrong.validate())
  }
  func testIntervalRejectsFractionalPositionsCountsStepsAndExcessiveIntervals() {
    for (start, end, count, per, total) in [(1.5, 14.5, 13.0, 21.0, 273.0), (1, 14.5, 13.5, 21, 283.5), (1, 14, 13, 21.5, 279.5), (1, 1002, 1001, 21, 21021), (14, 14, 0, 21, 0)] {
      var wrong = MathDiagramFixtures.interval
      for (index, value) in [start, end, count, per, total].enumerated() { wrong.facts[index].value = value }
      XCTAssertThrowsError(try wrong.validate())
    }
    var dimensional = MathDiagramFixtures.interval
    for index in 0...2 { dimensional.facts[index].unit = "楼" }
    dimensional.facts[3].unit = "级/楼"
    XCTAssertThrowsError(try dimensional.validate())
  }
  func testMissingFactReferenceReportsIDsForTargetedRepair() {
    var wrong = MathDiagramFixtures.interval
    wrong.relations[0].inputIDs = ["end", "missing-start"]
    XCTAssertThrowsError(try wrong.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("missing-start"))
      XCTAssertTrue(error.localizedDescription.contains("可用事实编号：start、end、count、per、total"))
    }
    wrong = MathDiagramFixtures.interval
    wrong.relations[0].outputID = "missing-count"
    XCTAssertThrowsError(try wrong.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("missing-count"))
      XCTAssertTrue(error.localizedDescription.contains("可用事实编号"))
    }
  }
  func testCompositeArithmeticMismatchIdentifiesInputAndOutputForOneRepair() {
    var wrong = MathDiagramFixtures.table
    wrong.relations.removeLast()
    wrong.relations[3] = .init(operation: .product, inputIDs: ["rate1", "count"], outputID: "total")
    XCTAssertThrowsError(try wrong.validate()) { error in
      let message = error.localizedDescription
      XCTAssertTrue(message.contains("625.0"))
      XCTAssertTrue(message.contains("675.0"))
      XCTAssertTrue(message.contains("总张数"))
      XCTAssertTrue(message.contains("中间量"))
    }
  }
  func testInvalidConstantReportsFactAndSpecificCorrectionWithoutRelaxingValidation() {
    var diagram = MathDiagramFixtures.parts
    diagram.facts.append(.init(id: "extra_parts", label: "多出的份数", value: 9, origin: .constant, evidence: "10减1"))
    XCTAssertThrowsError(try diagram.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("extra_parts"))
      XCTAssertTrue(error.localizedDescription.contains("derived"))
    }
    diagram.facts[3].value = 1
    diagram.facts[3].unit = "份"
    XCTAssertThrowsError(try diagram.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("空单位"))
    }
    diagram.facts[3].unit = ""
    diagram.facts[3].evidence = nil
    XCTAssertThrowsError(try diagram.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("缺少规则说明"))
    }
  }
  func testDivisionRuleConstantIsDistinctFromQuestionFactsAndGroundsDerivedQuantities() throws {
    let diagram = MathDiagram(id: "sum-difference", title: "和差推导", kind: .barComparison,
      facts: [MathDiagramFixtures.given("sum", "总量", 72), MathDiagramFixtures.given("difference", "差", 18),
        .init(id: "two", label: "平分两份的除数", value: 2, origin: .constant, evidence: "两个数量相等时平分为两份"),
        MathDiagramFixtures.derived("combined", "补齐差后的总量", 90),
        MathDiagramFixtures.derived("a", "较多人数", 45), MathDiagramFixtures.derived("b", "较少人数", 27)],
      relations: [.init(operation: .sum, inputIDs: ["sum", "difference"], outputID: "combined"),
        .init(operation: .quotient, inputIDs: ["combined", "two"], outputID: "a"),
        .init(operation: .difference, inputIDs: ["sum", "a"], outputID: "b")], factIDs: ["a", "b"])
    XCTAssertNoThrow(try diagram.validate())
    var forged = diagram
    forged.facts[2].value = 45
    XCTAssertThrowsError(try forged.validate())
    forged = diagram
    forged.facts[2].unit = "人"
    XCTAssertThrowsError(try forged.validate())
  }

  func testFiveTemplatesAndUnknownFactsHaveValidFixedArithmetic() throws {
    for diagram in MathDiagramFixtures.all { try diagram.validate() }
    XCTAssertEqual(45 + 27, 72)
    XCTAssertEqual(45 - 27, 18)
    XCTAssertEqual((50 / (27 - 25)) * 27, 675)
    XCTAssertEqual(10 * 10 + 10 * 3 + 4 * 10 + 4 * 3, 182)
  }

  func testUnknownEqualPartsRequiresAnExplicitGivenRatio() throws {
    var diagram = MathDiagram(id: "ratio-unknown", title: "甲是乙的三倍", kind: .equalParts,
      facts: [.init(id: "a", label: "甲", unit: "人", origin: .unknown),
        .init(id: "b", label: "乙", unit: "人", origin: .unknown),
        MathDiagramFixtures.given("ratio", "已知倍数", 3, "倍")],
      relations: [.init(operation: .product, inputIDs: ["b", "ratio"], outputID: "a")],
      factIDs: ["a", "b"], parts: [3, 1])
    XCTAssertNoThrow(try diagram.validate())
    diagram.parts = [4, 1]
    XCTAssertThrowsError(try diagram.validate())
  }
  func testCodableRoundTripHasStableFactIdentities() throws {
    for diagram in MathDiagramFixtures.all {
      XCTAssertEqual(try JSONDecoder().decode(MathDiagram.self, from: JSONEncoder().encode(diagram)), diagram)
    }
  }
  func testRejectsWrongArithmeticUnitsAndMissingEvidence() {
    var diagram = MathDiagramFixtures.bar
    diagram.facts[2].value = 17
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.bar; diagram.facts[0].unit = "张"
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.bar; diagram.facts[0].evidence = nil
    XCTAssertThrowsError(try diagram.validate())
  }
  func testRejectsNonfiniteNegativeFractionalCountsAndUnknownNumerals() {
    for value in [Double.nan, Double.infinity, -2, 1.5] {
      var diagram = MathDiagramFixtures.bar; diagram.facts[0].value = value
      XCTAssertThrowsError(try diagram.validate())
    }
    var unknown = MathDiagramFixtures.unknown; unknown.facts[0].value = 45
    XCTAssertThrowsError(try unknown.validate())
    var table = MathDiagramFixtures.table; table.facts.firstIndex(where: { $0.id == "count" }).map { table.facts[$0].value = 25.5 }
    XCTAssertThrowsError(try table.validate())
  }
  func testRejectsBrokenReferencesDisconnectedStatesAndInventedDerivedFacts() {
    var diagram = MathDiagramFixtures.state; diagram.factIDs = ["original", "final"]
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.bar; diagram.relations[0].outputID = "missing"
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.bar; diagram.facts.append(MathDiagramFixtures.derived("invented", "假造推得量", 12))
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.bar; diagram.factIDs.append("total")
    diagram.facts.firstIndex(where: { $0.id == "total" }).map { diagram.facts[$0].id = "a" }
    XCTAssertThrowsError(try diagram.validate())
  }
  func testRejectsEqualPartContradictionsAreaUnitMismatchAndTableShape() {
    var diagram = MathDiagramFixtures.parts; diagram.parts = [2, 1]
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.area; diagram.facts[2].unit = "cm"
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.area; diagram.parts = [15, 10]
    XCTAssertThrowsError(try diagram.validate())
    diagram = MathDiagramFixtures.table; diagram.rows[0].factIDs.removeLast()
    XCTAssertThrowsError(try diagram.validate())
  }
  func testDecimalMeasurementsAndEquivalentChineseUnitsAreSupported() throws {
    var diagram = MathDiagramFixtures.area
    diagram.facts[0].value = 1.5; diagram.facts[1].value = 2.4; diagram.facts[2].value = 3.6
    diagram.facts[0].unit = "厘米"; diagram.facts[2].unit = "平方厘米"; diagram.parts = []
    try diagram.validate()
  }
  func testRejectsRoundedNonterminatingQuotientsAndFractionalPrecision() {
    let divided = MathDiagram(id: "division", title: "循环小数不能当作精确结果", kind: .table,
      facts: [MathDiagramFixtures.given("a", "总量", 1, ""), MathDiagramFixtures.given("b", "份数", 3, ""), MathDiagramFixtures.derived("c", "每份", 0.333333, "")],
      relations: [.init(operation: .quotient, inputIDs: ["a", "b"], outputID: "c")], columns: ["结果"], rows: [.init(label: "均分", factIDs: ["c"])])
    XCTAssertThrowsError(try divided.validate())
    var measured = MathDiagramFixtures.area; measured.facts[0].value = 1.2345678
    XCTAssertThrowsError(try measured.validate())
    var fractionalCount = MathDiagramFixtures.bar; fractionalCount.facts[0].unit = "人 "; fractionalCount.facts[0].value = 1.5
    XCTAssertThrowsError(try fractionalCount.validate())
  }
  func testRejectsDivisionByZeroAndCircularDerivedClaims() {
    var parts = MathDiagramFixtures.parts; parts.facts[1].value = 0
    XCTAssertThrowsError(try parts.validate())
    let circular = MathDiagram(id: "cycle", title: "无原题依据的循环", kind: .barComparison,
      facts: [MathDiagramFixtures.derived("a", "甲", 12), MathDiagramFixtures.derived("b", "乙", 12)],
      relations: [.init(operation: .equal, inputIDs: ["a"], outputID: "b"), .init(operation: .equal, inputIDs: ["b"], outputID: "a")], factIDs: ["a", "b"])
    XCTAssertThrowsError(try circular.validate())
  }
}
