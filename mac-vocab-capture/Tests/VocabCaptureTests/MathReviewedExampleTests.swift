import AppKit
import Security
import XCTest
@testable import VocabCapture

@MainActor
final class MathReviewedExampleTests: XCTestCase {
  private let sourceText = "一个数乘10，得到的数比原来的数大72。原来的数是多少？"
  private let query = "小兰计算乘法时在得数末尾少添了一个0，得到的结果比正确结果少40005。求正确结果。"

  private func image(_ seed: UInt8 = 1) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 30, height: 25, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: CGFloat(seed) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 30, height: 25))
    return try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
  }

  private func fixture(_ store: MathQuestionStore, method: MathTeachingMethod, scope: String = "最终答案", correction: String = "", text: String? = nil, seed: UInt8 = 1) async throws -> (MathQuestionRecord, MathQuestionSolution, MathSolutionReview) {
    let solution = MathQuestionSolution(question: "用小学算术解题", answer: "原AI回答：72÷9=8，过程仅为历史文字。", model: "fixture", method: method)
    let question = try await store.save(.init(captureID: UUID().uuidString, imageData: image(seed), ocrText: text ?? sourceText, solutions: [solution]))
    let review = try await store.reviewSolution(questionID: question.id, solutionID: solution.id,
      status: "confirmed", scope: scope, note: "隔离测试确认，不是实际人审", correction: correction)
    return (question, solution, review)
  }

  func testReviewedReferencePreservesExactScopeCorrectionAndOriginalWithoutWritingDecision() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
    let (question, solution, review) = try await fixture(store, method: method, correction: "用户更正：答案是8。")
    let before = try await store.learningSnapshot(questionID: question.id)
    let examples = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: image(2))
    XCTAssertEqual(examples.count, 1)
    let example = try XCTUnwrap(examples.first)
    XCTAssertEqual(example.reference.questionID, question.id)
    XCTAssertEqual(example.reference.solutionID, solution.id)
    XCTAssertEqual(example.reference.reviewID, review.id)
    XCTAssertEqual(example.reference.scope, "最终答案")
    XCTAssertTrue(example.reference.displayLabel.contains("提供"))
    XCTAssertTrue(example.reference.displayLabel.contains("过程未确认"))
    XCTAssertEqual(example.answer, "用户更正：答案是8。")
    XCTAssertEqual(example.imageData, try image())
    let after = try await store.learningSnapshot(questionID: question.id)
    XCTAssertEqual(before, after)
    XCTAssertEqual(MathSkillLearningValidation.backgroundEvidence(after)["verification"] as? String, "unverified")
    let candidates = try await store.listSkillCandidates()
    XCTAssertTrue(candidates.isEmpty)
    await store.close()
  }

  func testSameImageUnrelatedQuestionAndPartialReviewAreNotReferences() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
    let (question, solution, _) = try await fixture(store, method: method)
    let sameImage = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: image())
    XCTAssertTrue(sameImage.isEmpty)
    let unrelated = try await store.reviewedExamples(methods: [method], textHint: "用3、6、7、4组成两位数乘两位数，求最大的积。", excludingImageData: nil)
    XCTAssertTrue(unrelated.isEmpty)
    _ = try await store.reviewSolution(questionID: question.id, solutionID: solution.id,
      status: "confirmed", scope: "指定小问（在备注中说明）", note: "只检查第一问", correction: "")
    let partial = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
    XCTAssertTrue(partial.isEmpty)
    await store.close()
  }

  func testLatestRejectedUnverifiedDeletedRevokedAndChangedVersionsCannotBeReused() async throws {
    for invalidation in ["rejected", "unverified", "deleted", "revoked", "changed", "archived"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = MathQuestionStore(directory: directory)
      let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
      let (question, solution, _) = try await fixture(store, method: method)
      let valid = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
      XCTAssertEqual(valid.count, 1, invalidation)
      switch invalidation {
      case "rejected", "unverified":
        _ = try await store.reviewSolution(questionID: question.id, solutionID: solution.id,
          status: invalidation, scope: "最终答案", note: "撤销先前决定", correction: "")
      case "deleted": try await store.delete(questionID: question.id)
      case "revoked": try await store.revokeSkillMethod(versionID: method.versionID, note: "停用旧方法")
      case "changed": _ = try await store.saveMethod(id: method.id, title: method.title, category: method.category, instructions: "已修改，历史版本不得匹配当前候选")
      default: try await store.archiveMethod(id: method.id)
      }
      let invalid = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
      XCTAssertTrue(invalid.isEmpty, invalidation)
      await store.close()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func testNoncandidateAndNewerUnrelatedReviewedMultiplicationCannotDisplaceStructuralReference() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
    let other = try await store.saveMethod(title: "乘积极值", category: "整数乘法", instructions: "排列数字比较乘积。")
    let (question, _, _) = try await fixture(store, method: method)
    _ = try await fixture(store, method: method, text: "用3、6、7、4组成两位数乘两位数，求最大的积。", seed: 2)
    for _ in 0..<130 {
      _ = try await fixture(store, method: other, text: "无关的整数乘法数字组数题", seed: 3)
    }
    let reference = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
    XCTAssertEqual(reference.map { $0.reference.questionID }, [question.id])
    let excluded = try await store.reviewedExamples(methods: [other], textHint: query, excludingImageData: nil)
    XCTAssertTrue(excluded.isEmpty)
    let noHint = try await store.reviewedExamples(methods: [method], textHint: "", excludingImageData: nil)
    XCTAssertTrue(noHint.isEmpty)
    await store.close()
  }

  func testRetrievalRequiresJointStructureOrEnoughDistinctLexicalEvidence() {
    XCTAssertNotNil(MathReviewedExample.relevance(query: query, source: sourceText))
    XCTAssertNil(MathReviewedExample.relevance(query: query, source: "两个数相差72，求它们各是多少？"))
    XCTAssertNil(MathReviewedExample.relevance(query: query, source: "甲是乙的10倍，求总数？"))
    XCTAssertNil(MathReviewedExample.relevance(query: "计算整数乘法，求正确结果。", source: "整数乘法题，求原来的结果。"))
    XCTAssertNotNil(MathReviewedExample.relevance(query: "沿河栽树两端都栽求间隔距离", source: "沿河栽树两端都栽求树木间隔距离"))
  }

  func testReferencePayloadCapsAndFullScopeRemainExplicitAndOversizedPhotoIsExcluded() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
    let longText = sourceText + String(repeating: "补充资料", count: 400)
    let longAnswer = String(repeating: "用户更正文字", count: 400)
    let (question, _, _) = try await fixture(store, method: method, scope: "答案及解题过程", correction: longAnswer, text: longText)
    let bounded = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
    let example = try XCTUnwrap(bounded.first)
    XCTAssertEqual(example.text.count, 1_200)
    XCTAssertEqual(example.answer.count, 1_600)
    XCTAssertEqual(example.reference.scope, "答案及解题过程")
    XCTAssertFalse(example.reference.displayLabel.contains("过程未确认"))
    try await store.delete(questionID: question.id)
    let context = try XCTUnwrap(CGContext(data: nil, width: 1100, height: 1100, bitsPerComponent: 8,
      bytesPerRow: 4400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    XCTAssertEqual(SecRandomCopyBytes(kSecRandomDefault, context.bytesPerRow * context.height, context.data!), errSecSuccess)
    let large = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
    XCTAssertGreaterThan(large.count, 2 * 1024 * 1024)
    let solution = MathQuestionSolution(question: "解题", answer: "8", model: "fixture", method: method)
    let big = try await store.save(.init(captureID: "large", imageData: large, ocrText: sourceText, solutions: [solution]))
    _ = try await store.reviewSolution(questionID: big.id, solutionID: solution.id, status: "confirmed", scope: "最终答案", note: "隔离测试", correction: "")
    let rejected = try await store.reviewedExamples(methods: [method], textHint: query, excludingImageData: nil)
    XCTAssertTrue(rejected.isEmpty)
    await store.close()
  }

  func testEmptyReviewedReferencesPreserveExistingMultiMethodSnapshotKeys() throws {
    let method = MathTeachingMethod(id: "primary", versionID: "v1", title: "方法", category: "类别", instructions: "步骤", createdAt: Date(timeIntervalSinceReferenceDate: 0))
    let visual = MathTeachingMethod(id: "visual", versionID: "v2", title: "画图", category: "类别", instructions: "步骤", createdAt: Date(timeIntervalSinceReferenceDate: 0))
    let snapshot = MathSolutionMethodSnapshot(method: method, visualMethods: [visual])
    let json = try XCTUnwrap(snapshot.encoded())
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["method", "visualMethods"])
    XCTAssertTrue(try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: Data(json.utf8)).reviewedExamples.isEmpty)
  }

  func testSolutionAndMethodSnapshotMetadataRoundTripAndLegacyCompatibility() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let method = try await store.saveMethod(title: "差倍问题", category: "算术", instructions: "差除以份数差。")
    let reference = MathReviewedExampleReference(questionID: "historical", solutionID: "old-solution", reviewID: "old-review", scope: "最终答案", title: "历史题目")
    let solution = MathQuestionSolution(question: "新题", answer: "新回答", model: "fixture", reviewedExamples: [reference])
    let encoded = try JSONEncoder().encode(solution)
    XCTAssertEqual(try JSONDecoder().decode(MathQuestionSolution.self, from: encoded).reviewedExamples, [reference])
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "reviewedExamples")
    let oldSolution = try JSONDecoder().decode(MathQuestionSolution.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertTrue(oldSolution.reviewedExamples.isEmpty)
    let oldMethod = try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: JSONEncoder().encode(method))
    XCTAssertEqual(oldMethod.method, method)
    XCTAssertTrue(oldMethod.reviewedExamples.isEmpty)
    let snapshot = MathSolutionMethodSnapshot(method: nil, visualMethods: [], reviewedExamples: [reference])
    let metadata = try XCTUnwrap(snapshot.encoded())
    XCTAssertFalse(metadata.contains(solution.answer))
    XCTAssertEqual(try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: Data(metadata.utf8)).reviewedExamples, [reference])
    let question = try await store.save(.init(captureID: "metadata", imageData: image(), solutions: [solution]))
    let stored = try await store.solutions(questionID: question.id)
    XCTAssertEqual(stored.first?.reviewedExamples, [reference])
    XCTAssertEqual(stored.first?.verificationStatus, "unverified")
    XCTAssertThrowsError(try MathSolutionMethodSnapshot(method: nil, visualMethods: [], reviewedExamples: [reference, reference]).encoded())
    let bad = MathReviewedExampleReference(questionID: "q", solutionID: "s", reviewID: "r", scope: "指定小问", title: "题目")
    XCTAssertThrowsError(try MathSolutionMethodSnapshot(method: nil, visualMethods: [], reviewedExamples: [bad]).encoded())
    await store.close()
  }
}
