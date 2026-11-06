import Foundation
import XCTest

@testable import VocabCapture

final class MathMixedDigitExtremaRetrievalTests: XCTestCase {
  private func fixtures() throws -> (MathSkillDefinition, [MathTeachingMethod]) {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "divisible-mixed-digit-extrema" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "mixed-digit-extrema", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    return (skill, methods)
  }

  func testMixedExpressionOffersWholeMethodAndRespectsTeachingPermission() throws {
    let (skill, methods) = try fixtures()
    for hint in [
      "将2～8这7个自然数填入算式□□×□□−□□÷□，计算结果为整数，最大最小是多少？",
      "1到7七个不同数字各用一次，两位数乘两位数减去两位数除以一位数，整数结果的极值。",
    ] {
      let request = "四年级，不用方程，允许拓展知识。"
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: request, textHint: hint)
      XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
      XCTAssertEqual(result.first { $0.id == skill.sourceID }?.instructions, skill.instructions)
      XCTAssertTrue(
        MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
      XCTAssertLessThanOrEqual(result.count, 7)
      let denied = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: "四年级，不允许拓展知识。",
        textHint: hint + "允许拓展知识。")
      XCTAssertFalse(denied.contains { $0.id == skill.sourceID })
    }
  }

  func testOtherOperatorsAndOrdinaryDigitProductsDoNotOfferMixedMethod() throws {
    let (skill, methods) = try fixtures()
    for hint in [
      "将2到8七个数字填入□□−□□−□□÷□，整数结果最大最小是多少？",
      "将2到8七个数字填入□□−□□−□□÷□，整数结果最大最小是多少？本题没有乘法。",
      "将2到8七个数字填入□□×□□＋□□÷□，整数结果最大最小是多少？",
      "七个数字组成两数，乘积最大是多少？",
      "两位数乘两位数减去一位数，求整数结果最小。",
    ] {
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertFalse(result.contains { $0.id == skill.sourceID }, hint)
    }
  }

  func testOriginalMixedExpressionOCRRecallAndCompletePrompt() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_MIXED_EXTREMA_IMAGE"] else {
      throw XCTSkip("Set original mixed-expression crop")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let (skill, methods) = try fixtures()
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(
      result.contains { $0.id == skill.sourceID }, "OCR: \(hint); \(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }
}
