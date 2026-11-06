import Foundation
import XCTest

@testable import VocabCapture

final class MathWeeklyReceptionRetrievalTests: XCTestCase {
  func testOriginalWeeklyReceptionPhotoOffersWholeMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_WEEKLY_RECEPTION_IMAGE"] else {
      throw XCTSkip("Set original reception crop")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "weekly-reception-time-windows" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "weekly-reception-ocr", title: $0.title,
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

  func testWeeklyReceptionRecallWholeMethodAndKeepPermissions() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "weekly-reception-time-windows" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "weekly-reception", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint =
      "A、B、C、D分别到甲乙丙丁四单位。甲星期一不接待乙星期三不接待丙星期四不接待丁星期二四六接待，星期日均不办公。A前天没办成B今天行明天不行C今天不行明天行D从今天起连着4天都行，今天星期几？"
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
    let changedWindow = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request,
      textHint: hint.replacingOccurrences(of: "从今天起", with: "从明天起"))
    XCTAssertTrue(changedWindow.contains { $0.id == skill.sourceID })
    XCTAssertTrue(skill.instructions.contains("其他条件不变会无解"))
    XCTAssertTrue(skill.instructions.contains("C | 乙、丁"))
    XCTAssertTrue(skill.instructions.contains("开放恰好满足明天可以去"))
    XCTAssertTrue(skill.instructions.contains("才得到C乙"))
    XCTAssertFalse(
      MathLocalSkillRetrieval.retrieve(
        methods: methods,
        requirements: "四年级，不允许拓展知识。", textHint: hint + "允许拓展知识。"
      )
      .contains { $0.id == skill.sourceID })
    for negative in [
      "四人分别去不同单位，甲不是医生乙不是教师，各是什么职业？",
      "周一至周五接待八个客户，如何排队使总等待最短？",
      "明天星期三，请把办公单位名称翻译成英语。",
      hint.replacingOccurrences(of: "连着4天", with: "连续4个工作日"),
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods,
          requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
