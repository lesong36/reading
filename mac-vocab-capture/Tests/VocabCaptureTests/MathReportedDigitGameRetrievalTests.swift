import Foundation
import XCTest

@testable import VocabCapture

final class MathReportedDigitGameRetrievalTests: XCTestCase {
  func testOriginalDigitGamePhotoOffersWholeMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_DIGIT_GAME_IMAGE"] else {
      throw XCTSkip("Set original game crop")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "reported-digit-adversarial-placement" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "digit-game-ocr", title: $0.title,
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

  func testSequentialDigitGameRecallsWholeMethodAndKeepsPermissions() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "reported-digit-adversarial-placement" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "digit-game", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint = "甲每次报一个数字，乙把它放入四个方框中的一个，三位数2□□减1□□，甲要差尽量大乙要差尽量小，最佳策略最后差多少？"
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
      "四个互异数字一次性填入方框使差最大，没有甲乙报数。",
      hint + "每次报数不能重复。",
      "甲乙各组成三位数，差最小是多少？",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods,
          requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
