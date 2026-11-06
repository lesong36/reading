import Foundation
import XCTest
@testable import VocabCapture

final class MathElongatedCrossRetrievalTests: XCTestCase {
  func testCrossConstructionMethodIsOfferedWhole() throws {
    try check("细长十字形上下突出段宽2高3，中段宽4高6，分成四块全等图形，再拼成正方形。")
  }
  func testOriginalCrossPhotoOffersWholeMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_CROSS_SOURCE_IMAGE"] else {
      throw XCTSkip("Set original cross question image")
    }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    try check(hint)
  }
  private func check(_ hint: String) throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "geometric-cut-and-rearrange" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "hexagon", title: $0.title,
                        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "只解拓展篇第10题细长十字形，不用方程，将四块全等图形拼成正方形并画出切线和接缝。"
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(candidates.contains { $0.id == skill.sourceID }, "OCR: \(hint); candidates: \(candidates.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt(request, candidates: candidates).contains(skill.instructions))
  }
}
