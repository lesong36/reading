import Foundation
import XCTest
@testable import VocabCapture

final class MathHexagonPartitionRetrievalTests: XCTestCase {
  func testHexagonConstructionMethodIsOfferedWhole() throws {
    try check("ABCDEF是正六边形，O是中心。画3条线段分成6个全等图形，再分成3个全等四边形和3个全等五边形。")
  }
  func testOriginalHexagonPhotoOffersWholeMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_HEXAGON_IMAGE"] else {
      throw XCTSkip("Set original hexagon question image")
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
    let request = "四年级，不用方程，允许拓展知识，画出全部三种分法。"
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(candidates.contains { $0.id == skill.sourceID }, "OCR: \(hint); candidates: \(candidates.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt(request, candidates: candidates).contains(skill.instructions))
  }
}
