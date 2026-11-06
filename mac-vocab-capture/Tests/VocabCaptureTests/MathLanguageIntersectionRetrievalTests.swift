import Foundation
import XCTest

@testable import VocabCapture

final class MathLanguageIntersectionRetrievalTests: XCTestCase {
  func testOriginalLanguagePhotoOffersWholeMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_LANGUAGE_SETS_IMAGE"] else {
      throw XCTSkip("Set original language crop")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "multi-valued-language-intersections" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "language-sets-ocr", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(
      result.contains { $0.id == skill.sourceID }, "OCR: \(hint); \(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }

  func testLanguageSetsRecallWholeMethodAndKeepPermissions() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "multi-valued-language-intersections" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "language-sets", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint =
      "甲乙丙各会2种语言，丁只会1种。汉语英语法语日语中有一种3人都会。甲会日语丁不会日语乙不会英语；甲丙、丙丁不能直接交谈，乙甲、乙丙可以直接交谈；没有人既会日语又会法语。各会什么？"
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
    XCTAssertFalse(
      MathLocalSkillRetrieval.retrieve(
        methods: methods,
        requirements: "四年级，不允许拓展知识。", textHint: hint + "允许拓展知识。"
      )
      .contains { $0.id == skill.sourceID })
    for negative in [
      "四人各选一种不同职业，甲不是医生，乙不是教师，各是什么职业？",
      "甲乙丙丁各学习两种语言，请翻译汉语英语法语日语的名称。",
      "每人会两种语言，经乙翻译甲丙能直接交谈，各会什么？",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods,
          requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
