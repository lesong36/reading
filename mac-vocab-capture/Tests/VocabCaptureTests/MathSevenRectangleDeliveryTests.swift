import Foundation
import XCTest

@testable import VocabCapture

final class MathSevenRectangleDeliveryTests: XCTestCase {
  private func fixture() throws -> (MathSkillDefinition, [MathTeachingMethod]) {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "seven-distinct-rectangles-grid" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "seven-delivery", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    return (skill, methods)
  }

  func testSourceRecallIncludesFullDrawingMethodWithoutExtraPermission() throws {
    let (skill, methods) = try fixture()
    let request = "四年级，不用方程，不允许拓展知识。"
    let hint = "将5×5方格沿格线分割成7个形状不同的长方形，包含正方形，请画出分割线。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }

  func testOrdinaryAreaAndNonRectanglePartitionDoNotRecallMethod() throws {
    let (skill, methods) = try fixture()
    for hint in [
      "一个长方形长7厘米宽5厘米，求面积。",
      "将正方形分割成7个三角形，画出分割线。",
      "计算7个长方形的面积总和。",
    ] {
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: "四年级解题。", textHint: hint)
      XCTAssertFalse(result.contains { $0.id == skill.sourceID }, hint)
    }
  }
}
