import Foundation
import XCTest

@testable import VocabCapture

final class MathFacingSeatRetrievalTests: XCTestCase {
  private func fixture() throws -> (MathSkillDefinition, [MathTeachingMethod]) {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "facing-seat-perspective-identities" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "facing-seats", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    return (skill, methods)
  }

  func testOriginalPhotoOffersCompleteMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_FACING_SEAT_IMAGE"] else {
      throw XCTSkip("Set original facing seat crop")
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

  func testFacingSeatsRecallAndPermissionBoundary() throws {
    let (skill, methods) = try fixture()
    let hint =
      "列车上A、B、C、D四位不同国籍的旅客穿蓝黑灰褐大衣，桌子两侧每边坐2人，正好面对面。英国人在B左侧，A褐衣，黑衣在德国人右侧，D对面是美国人，俄国人灰衣。求各人国籍和衣色。"
    let request = "四年级，允许拓展知识。"
    for text in [hint, hint.replacingOccurrences(of: "英国人在B左侧", with: "英国人在B右侧")] {
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
      "四位不同国籍旅客穿不同颜色大衣，在一排同向座位依次就坐，求排列。",
      "四位旅客围成圆桌，英国人在B左侧，黑衣在德国人右侧，求国籍。",
      "列车桌子两侧各坐两位不同国籍旅客，面对面，只给衣色，没有左右或对面身份条件。",
      "桌子两侧每边坐3人，面对面，英国人在B左侧，黑衣在德国人右侧。",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods, requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
