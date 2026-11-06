import Foundation
import XCTest

@testable import VocabCapture

final class MathOptionalElevatorRetrievalTests: XCTestCase {
  func testOriginalElevatorPhotoRecallsCompleteMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_ELEVATOR_IMAGE"] else {
      throw XCTSkip("Set source elevator crop")
    }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "optional-ride-single-stop-elevator" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "elevator-ocr", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: text)
    XCTAssertTrue(
      result.contains { $0.id == skill.sourceID }, "OCR: \(text); \(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }

  func testOptionalElevatorOffersCompleteMethodAndPreservesPermissionBoundary() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(
      catalogue.skills.first { $0.name == "optional-ride-single-stop-elevator" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "elevator", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint = "33层楼32人分别去2至33层，电梯只能在某一层停，每个人可以选择走楼梯上楼或乘电梯到这一层再走楼梯，上楼3分下楼1分不满意，总分最小应停哪层？"
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
    let denied = MathLocalSkillRetrieval.retrieve(
      methods: methods,
      requirements: "四年级，不允许拓展知识。", textHint: hint + "允许拓展知识。")
    XCTAssertFalse(denied.contains { $0.id == skill.sourceID })
    for negative in [
      "电梯可以停两个楼层，楼梯费用不同，容量有限，总成本最小。",
      "电梯只能停一层，所有人必须乘电梯再走楼梯，不满意总分最小。",
      "33层楼电梯怎样运行等待时间最少？",
    ] {
      XCTAssertFalse(
        MathLocalSkillRetrieval.retrieve(
          methods: methods,
          requirements: request, textHint: negative
        ).contains { $0.id == skill.sourceID }, negative)
    }
  }
}
