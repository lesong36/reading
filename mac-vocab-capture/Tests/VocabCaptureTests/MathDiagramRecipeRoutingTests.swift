import XCTest
@testable import VocabCapture

@MainActor
final class MathDiagramRecipeRoutingTests: XCTestCase {
  private func method(_ name: String) throws -> MathTeachingMethod {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == name })
    return .init(id: skill.sourceID, versionID: "test-version", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
  }

  func testProjectDistributionUsesSmallRecipeAndHelpfulTableDefault() throws {
    let primary = try method("surplus-and-shortfall")
    XCTAssertEqual(ScreenshotQuestionPanel.diagramViews("请解题", method: primary, visualMethods: []), [.table])
    let prompt = ScreenshotQuestionPanel.question("请解题", using: primary)
    XCTAssertTrue(prompt.contains("two_allocations"))
    XCTAssertTrue(prompt.contains("extra_recipients"))
    XCTAssertTrue(prompt.contains("同一组接收者"))
    XCTAssertTrue(prompt.contains(primary.instructions))
    XCTAssertFalse(prompt.contains("最多32个数量"))
  }

  func testExplicitDrawingWinsOverRecipeDefault() throws {
    let primary = try method("surplus-and-shortfall")
    XCTAssertTrue(ScreenshotQuestionPanel.question("请用表格解题", using: primary).contains("two_allocations"))
    let line = ScreenshotQuestionPanel.question("请画线段图解题", using: primary)
    XCTAssertTrue(line.contains("two_allocations"))
    XCTAssertTrue(line.contains("view固定\"bar_comparison\""))
    XCTAssertFalse(ScreenshotQuestionPanel.question("请用面积图解题", using: primary).contains("two_allocations"))
    XCTAssertEqual(ScreenshotQuestionPanel.diagramViews("请用面积图解题", method: primary, visualMethods: []), [.area])
    XCTAssertFalse(ScreenshotQuestionPanel.question("只要文字解题", using: primary).contains("two_allocations"))
  }

  func testCustomTitleOrModifiedBodyCannotClaimProjectRecipe() throws {
    let project = try method("surplus-and-shortfall")
    for custom in [
      MathTeachingMethod(id: "custom", versionID: "v", title: project.title,
        category: project.category, instructions: project.instructions, createdAt: Date()),
      MathTeachingMethod(id: project.id, versionID: "v", title: project.title,
        category: project.category, instructions: project.instructions + "\n用户改写", createdAt: Date()),
    ] {
      XCTAssertNil(ScreenshotQuestionPanel.boundDiagramRecipe(custom))
      XCTAssertFalse(ScreenshotQuestionPanel.question("请解题", using: custom).contains("two_allocations"))
    }
  }

  func testBoundDifferenceRatioNoLongerRequestsFreeFormGraph() throws {
    let primary = try method("difference-and-ratio")
    let prompt = ScreenshotQuestionPanel.question("请解题并画线段图", using: primary)
    XCTAssertTrue(prompt.contains("difference_ratio"))
    XCTAssertFalse(prompt.contains("最多32个数量"))
    XCTAssertTrue(prompt.contains(primary.instructions))
  }

  func testSuggestionCanBeRejectedAndDoesNotRequireNamedMethod() throws {
    let primary = try method("unitary-and-total")
    let prompt = ScreenshotQuestionPanel.question("比较两家书店的优惠，解题", using: primary)
    XCTAssertTrue(prompt.contains("不代表已采用"))
    XCTAssertTrue(prompt.contains("不要求100%套用"))
    XCTAssertTrue(prompt.contains("不适用时拒绝该建议"))
    XCTAssertTrue(prompt.contains("优惠比较应按各优惠规则"))
  }

  func testNoPrimaryStillAllowsIndependentUsefulVisual() throws {
    let visual = try method("hypothesis-table-diagram")
    let data = try JSONSerialization.data(withJSONObject: ["method_id": NSNull(),
      "visual_method_ids": [visual.id], "reason": "没有直接适用的现有主方法，表格可比较各方案实际付款。"])
    let match = try MathMethodMatcher.parseSingleCall(String(decoding: data, as: UTF8.self),
      methods: [try method("unitary-and-total"), visual], question: "四年级，不用方程，比较优惠")
    XCTAssertNil(match.method)
    XCTAssertEqual(match.visualMethods, [visual])
    let prompt = ScreenshotQuestionPanel.question("比较优惠，解题", using: match.method, visualMethods: match.visualMethods)
    XCTAssertFalse(prompt.contains("名称：归一与归总"))
    XCTAssertTrue(prompt.contains(visual.instructions))
    XCTAssertTrue(ScreenshotQuestionPanel.requestsDiagram("解题", using: match.method, visualMethods: match.visualMethods))
  }
  func testAbstentionDoesNotSuppressHelpfulMathDiagramProtocol() {
    let prompt = ScreenshotQuestionPanel.question("不用方程，用小学知识解题", using: nil,
      automaticSelectionAttempted: true)
    XCTAssertTrue(prompt.contains("不强行命名解法"))
    XCTAssertTrue(prompt.contains("purchase_comparison"))
    XCTAssertTrue(prompt.contains("没有帮助则保留正常文字解答"))
    XCTAssertFalse(ScreenshotQuestionPanel.question("Explain this English sentence", using: nil,
      automaticSelectionAttempted: true).contains("math-diagrams"))
    XCTAssertFalse(ScreenshotQuestionPanel.question("不用方程，只要文字解题", using: nil,
      automaticSelectionAttempted: true).contains("math-diagrams"))
  }

}
