import Foundation
import XCTest

@testable import VocabCapture

final class MathOpponentIdentityRetrievalTests: XCTestCase {
  private func fixture() throws -> (MathSkillDefinition, [MathTeachingMethod]) {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "opponent-count-identity-graphs" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "opponent-identity", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    return (skill, methods)
  }

  func testOriginalPhotoOffersCompleteMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_OPPONENT_IDENTITY_IMAGE"] else {
      throw XCTSkip("Set original opponent identity crop")
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

  func testDistinctOpponentRecallAndPermissionBoundary() throws {
    let (skill, methods) = try fixture()
    let hint = "五名运动员分别来自湖北广东福建北京上海，李平只和两名运动员比赛过，上海选手与三名对手比赛过，陈兵与广东选手从未比赛，广东福建北京互相交手，求张强来自哪里。"
    let request = "四年级，允许拓展知识。"
    for text in [hint, hint.replacingOccurrences(of: "李平", with: "小明")] {
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
      "五名运动员来自不同省，只给总比赛场次，两名选手重复比赛过三次，求地区。",
      "五名运动员来自不同省，只给胜负，两名选手交手三次，求排名。",
      "两名运动员分别来自北京上海，每人比赛过三场，不区分对手，求总场次。",
      "五人分别来自不同地区，求所有身份排列的数量。",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods, requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
