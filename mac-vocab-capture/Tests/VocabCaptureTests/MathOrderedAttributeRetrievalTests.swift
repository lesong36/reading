import Foundation
import XCTest

@testable import VocabCapture

final class MathOrderedAttributeRetrievalTests: XCTestCase {
  private func fixture() throws -> (MathSkillDefinition, [MathTeachingMethod]) {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "ordered-multi-attribute-adjacency" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "ordered-attributes", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    return (skill, methods)
  }

  func testOriginalPhotoOffersCompleteMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_ORDERED_ATTRIBUTE_IMAGE"] else {
      throw XCTSkip("Set original ordered attribute crop")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let (skill, methods) = try fixture()
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(
      result.contains { $0.id == skill.sourceID }, "OCR: \(hint); \(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }

  func testOrderedAttributesRecallAndPermissionBoundary() throws {
    let (skill, methods) = try fixture()
    let hint =
      "甲乙丙丁戊五人来自不同城市，开不同品牌车，喝不同茶，穿不同颜色衬衫。车从左到右排一行，宝马紧挨奥迪左边，丁最左边，中间喝龙井，上海人挨乌龙茶主人，求黑衬衫的人来自哪里。"
    let request = "四年级，允许拓展知识。"
    for text in [hint, hint.replacingOccurrences(of: "宝马紧挨奥迪左边", with: "宝马紧挨奥迪右边")] {
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: request, textHint: text)
      XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
      XCTAssertTrue(
        MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
    }
    XCTAssertFalse(
      MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: "四年级，不允许拓展知识。",
        textHint: hint + "允许拓展知识。"
      ).contains { $0.id == skill.sourceID })
    for negative in [
      "甲乙丙丁戊五人穿不同衬衫，从左到右排队，求排列数量。",
      "五辆不同品牌车从左到右停车，宝马在奥迪左边，求有多少种次序。",
      "五人来自不同城市，喝不同茶，穿不同衬衫，围成一圈，允许同类重复，求相邻关系。",
      "五人来自不同城市开不同车喝不同茶穿不同衬衫，只给喜好，不给任何位置关系。",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods, requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
