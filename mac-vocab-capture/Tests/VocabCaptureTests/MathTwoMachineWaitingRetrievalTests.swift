import Foundation
import XCTest

@testable import VocabCapture

final class MathTwoMachineWaitingRetrievalTests: XCTestCase {
  func testOriginalTwoMachineWaitingOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_TWO_MACHINE_WAITING_IMAGE"] else {
      throw XCTSkip("Set original two-machine waiting crop")
    }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "two-machine-total-waiting" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "waiting-ocr", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程，允许拓展知识。"
    let result = MathLocalSkillRetrieval.retrieve(
      methods: methods, requirements: request, textHint: text)
    XCTAssertTrue(
      result.contains { $0.id == skill.sourceID },
      "OCR: \(text); candidates: \(result.map(\.title))")
    XCTAssertTrue(
      MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
  }

  func testTwoMachineWaitingRecallsCompleteMethodAndRespectsObjectiveAndPermissions() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "two-machine-total-waiting" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(
        id: $0.sourceID, versionID: "two-machine-waiting", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程，允许拓展知识。"
    for hint in [
      "车间里有两台一样的机器，6个人每人做一个零件需7、10、12、13、14、15分钟，等候的总时间最短是多少分钟？",
      "两台同样设备，所有人同时到达，每项加工不能中断，求等待时间之和最少。",
    ] {
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: request, textHint: hint)
      XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
      XCTAssertEqual(result.first { $0.id == skill.sourceID }?.instructions, skill.instructions)
      XCTAssertTrue(
        MathStructuredSolution.prompt(request, candidates: result).contains(skill.instructions))
      XCTAssertLessThanOrEqual(result.count, 7)
      let denied = MathLocalSkillRetrieval.retrieve(
        methods: methods,
        requirements: "四年级，不允许拓展知识。", textHint: hint + "允许拓展知识。")
      XCTAssertFalse(denied.contains { $0.id == skill.sourceID })
    }
    for hint in [
      "两台一样的机器加工六个零件，全部完成的最短工期是多少？",
      "一台机器六人排队，总等候时间最少是多少？",
    ] {
      let result = MathLocalSkillRetrieval.retrieve(
        methods: methods, requirements: request, textHint: hint)
      XCTAssertFalse(result.contains { $0.id == skill.sourceID }, "\(hint)")
    }
  }

}
