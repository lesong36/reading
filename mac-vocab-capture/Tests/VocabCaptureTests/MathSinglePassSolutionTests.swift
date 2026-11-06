import XCTest
@testable import VocabCapture

final class MathSinglePassSolutionTests: XCTestCase {
  private var custom: MathTeachingMethod {
    .init(id: "custom", versionID: "v1", title: "自定义方法", category: "算术",
      instructions: "完整方法条件与排除规则。不得截断。", createdAt: Date(timeIntervalSince1970: 0))
  }
  func testNullPrimaryAndIndependentDiagramPayload() {
    let source = "正常回答\n```math-methods\n{\"method_id\":null,\"visual_method_ids\":[]}\n```\n```math-diagrams\n{\"schemaVersion\":1}\n```"
    let result = MathSinglePassSolution.parse(source, candidates: [custom])
    XCTAssertNil(result.method); XCTAssertNil(result.failure)
    XCTAssertFalse(result.answer.contains("math-methods"))
    XCTAssertTrue(result.answer.contains("math-diagrams"))
  }
  func testUseIsBoundToFullServedSnapshotAndUnknownIDsDoNotBecomeMethods() {
    let good = MathSinglePassSolution.parse("回答\n```math-methods\n{\"method_id\":\"custom\",\"visual_method_ids\":[]}\n```", candidates: [custom])
    XCTAssertEqual(good.method, custom); XCTAssertNil(good.failure)
    let bad = MathSinglePassSolution.parse("回答\n```math-methods\n{\"method_id\":\"invented\",\"visual_method_ids\":[]}\n```", candidates: [custom])
    XCTAssertNil(bad.method); XCTAssertNotNil(bad.failure); XCTAssertEqual(bad.answer, "回答")
    let prompt = MathSinglePassSolution.prompt("按小学知识解题", candidates: [custom])
    XCTAssertTrue(prompt.contains(custom.instructions)); XCTAssertTrue(prompt.contains("主方法允许null"))
  }
  func testCustomSolutionCannotBeDeclaredVisual() {
    let result = MathSinglePassSolution.parse("回答\n```math-methods\n{\"method_id\":null,\"visual_method_ids\":[\"custom\"]}\n```", candidates: [custom])
    XCTAssertNotNil(result.failure); XCTAssertTrue(result.visualMethods.isEmpty)
  }
  func testMalformedDuplicateAndMissingMetadataRetainReadableAnswer() {
    for block in ["", "```math-methods\n{}\n```", "```math-methods\n{\"method_id\":null,\"visual_method_ids\":[],\"verified\":true}\n```", "```math-methods\n{}\n```\n```math-methods\n{}\n```", "```math-methods\n{unfinished"] {
      let result = MathSinglePassSolution.parse("已返回的解答\n" + block, candidates: [])
      XCTAssertEqual(result.answer, "已返回的解答"); XCTAssertNil(result.method); XCTAssertNotNil(result.failure)
    }
  }
  func testStreamingDoesNotExposeMethodJSONOrDiagramJSON() {
    for suffix in ["```math-m", "```math-methods", "```math-methods\n{\"method_id\":"] {
      XCTAssertEqual(MathSinglePassSolution.displayText("回答\n" + suffix), "回答")
    }
    XCTAssertEqual(MathSinglePassSolution.displayText("回答\n```math-methods\n{\"method_id\":null,\"visual_method_ids\":[]}\n```\n```math-diagrams\n{}"), "回答")
  }
}
