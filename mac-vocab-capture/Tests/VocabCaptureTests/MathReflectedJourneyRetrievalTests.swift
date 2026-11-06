import Foundation
import XCTest

@testable import VocabCapture

final class MathReflectedJourneyRetrievalTests: XCTestCase {
  private func verify(_ hint: String) throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rebound-meeting-unknown-distance" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "reflected-journey-" + $0.version,
        title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程，请完整讨论可能情况。"
    let offered = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(offered.contains { $0.id == skill.sourceID }, "\(offered.map(\.title)); \(hint)")
    XCTAssertTrue(MathStructuredSolution.prompt(request, candidates: offered).contains(skill.instructions))
    XCTAssertTrue(skill.instructions.contains("端点例外"))
    XCTAssertTrue(skill.instructions.contains("尚未到右端"))
  }

  func testInverseReflectedJourneyRequestsOfferCompleteRevisedMethod() throws {
    for hint in [
      "A、B两辆汽车同时从甲地出发，在甲乙两地间不断往返行驶，第一次迎面相遇距甲地40千米，第二次迎面相遇距乙地10千米，求两地距离。",
      "A、B两辆汽车分别从甲乙两地同时出发，并在两地间不断往返行驶。两车距甲地40千米处第一次迎面相遇，距甲地10千米处第二次迎面相遇，求两地距离。",
      "甲乙两车从同一端同时出发，端点即折返，首次迎面在距起点24千米，第二次迎面在距另一端6千米，求全程，所有可能长度。",
      "两车分别从两端同时出发，来回行驶，到端立即折返。第一次迎面距左端36，第二次迎面距左端12，求路长。"
    ] { try verify(hint) }
  }

  func testActualWholePageOCRKeepsReflectedJourneyMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_REFLECTED_SOURCE_DIRECTORY"] else {
      throw XCTSkip("Opt-in actual reflected-journey source pages")
    }
    for page in ["page-05.png", "page-07.png"] {
      let image = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(page))
      try verify(await MathQuestionIndexer.recognize(image))
    }
  }
}
