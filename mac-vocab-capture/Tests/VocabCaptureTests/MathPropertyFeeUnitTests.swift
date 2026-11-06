import XCTest
@testable import VocabCapture

final class MathPropertyFeeUnitTests: XCTestCase {
  func testAreaTimesMonthlyRateProducesMonthlyFee() throws {
    XCTAssertEqual(try MathDiagram.inferredUnit(.product, inputs: ["平方米", "元/平方米/月"]), "元/月")
    XCTAssertEqual(try MathDiagram.inferredUnit(.product, inputs: ["元/月", "月"]), "元")
  }

  func testIncorrectUnitReportsTheActualRelationWithoutAcceptingIt() {
    let diagram = MathDiagram(id: "fee", title: "物业费", kind: .table,
      facts: [MathDiagramFixtures.given("area", "面积", 115, "平方米"),
        MathDiagramFixtures.given("rate", "每月每平方米费用", 2, "元/平方米/月"),
        MathDiagramFixtures.derived("monthly", "每月费用", 230, "元")],
      relations: [.init(operation: .product, inputIDs: ["area", "rate"], outputID: "monthly")],
      columns: ["费用"], rows: [.init(label: "每月", factIDs: ["monthly"])])
    XCTAssertThrowsError(try diagram.validate()) { error in
      XCTAssertTrue(error.localizedDescription.contains("面积〔平方米〕 × 每月每平方米费用〔元/平方米/月〕"))
      XCTAssertTrue(error.localizedDescription.contains("每月费用〔元〕"))
    }
  }
}
