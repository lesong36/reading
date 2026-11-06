import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathReviewedExampleDeliveryTests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func settle(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<300 {
      if try await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Reviewed example delivery did not settle")
  }
  private func blank(_ size: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
  }

  func testOneCallSuppliesReviewedOriginalWithScopeThenRevocationRemovesFutureReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let methods = try await store.automaticMethods()
    let method = try XCTUnwrap(methods.first { $0.title == "差倍问题" })
    let sourceImage = try blank(32), currentImage = try blank(20)
    let old = MathQuestionSolution(question: "小学解题", answer: "旧题最终答案8，过程未核验", model: "fixture", method: method)
    let record = try await store.save(.init(captureID: "reference", imageData: sourceImage,
      ocrText: "一个数乘10，得到的数比原来的数大72。原来的数是多少？", solutions: [old]))
    let review = try await store.reviewSolution(questionID: record.id, solutionID: old.id,
      status: "confirmed", scope: "最终答案", note: "ISOLATED TEST ONLY", correction: "")
    var calls = 0, selectors = 0, permitsReferences = true
    var received: [[MathReviewedExample]] = []
    let panel = ScreenshotQuestionPanel(context: .init(
      text: "一个数乘10，得到的数比原来的数大81。原来的数是多少？", selectedWord: nil, imageData: currentImage),
      answer: { _, context, _, _ in
        calls += 1; received.append(context.mathReferences)
        XCTAssertEqual(context.imageData, currentImage)
        return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"本题独立计算：81÷9=9，9×10−9=81。旧题8不是本题答案。","diagrams":[],"diagram_omission":{"status":"no_helpful_diagram","reason":"本隔离测试仅检查参考材料的传递与历史保存。"}}"#
      }, originalImageData: currentImage, saveQuestion: { try await store.save($0) },
      mathStore: store, selectMethodAutomatically: { _, _, _ in
        selectors += 1; XCTFail("Must not add a separate model selector"); return .init(method: nil, reason: "")
      }, singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true,
      canUseReviewedMathExamples: { permitsReferences })
    defer { panel.close() }
    panel.present()
    let children = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    let input = try XCTUnwrap(children.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    let ask = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    input.stringValue = "请用小学知识解题，不用方程"; ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1); XCTAssertEqual(selectors, 0)
    let example = try XCTUnwrap(received.first?.first)
    XCTAssertEqual(received[0].count, 1)
    XCTAssertEqual(example.imageData, sourceImage)
    XCTAssertEqual(example.reference.reviewID, review.id)
    XCTAssertEqual(example.reference.scope, "最终答案")
    XCTAssertNotNil(panel.singlePassPreparationDurations["reviewedExampleRetrieval"])
    XCTAssertTrue(children.compactMap { $0 as? NSTextView }.contains { $0.string.contains("本次提供的历史参考") && $0.string.contains("过程未确认") })
    let save = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" })
    save.performClick(nil)
    try await settle { panel.savedQuestionID != nil && !panel.isSavingQuestion }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let saved = try await store.solutions(questionID: id)
    XCTAssertEqual(saved.first?.reviewedExamples, [example.reference])
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    let newReviews = try await store.reviews(solutionID: try XCTUnwrap(saved.first?.id))
    XCTAssertTrue(newReviews.isEmpty)
    _ = try await store.reviewSolution(questionID: record.id, solutionID: old.id,
      status: "rejected", scope: "最终答案", note: "ISOLATED TEST REVOCATION", correction: "")
    input.stringValue = "请用小学知识解题，不用方程"; ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 2 }
    XCTAssertEqual(calls, 2); XCTAssertTrue(received[1].isEmpty)
    let historical = try await store.solutions(questionID: id)
    XCTAssertEqual(historical.first?.reviewedExamples, [example.reference], "Prior supplied references stay historical metadata")
    _ = try await store.reviewSolution(questionID: record.id, solutionID: old.id,
      status: "confirmed", scope: "最终答案", note: "ISOLATED TEST RECONFIRMATION", correction: "")
    permitsReferences = false
    input.stringValue = "请用小学知识解题，不用方程"; ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 3 }
    XCTAssertEqual(calls, 3); XCTAssertTrue(received[2].isEmpty)
    XCTAssertNil(panel.singlePassPreparationDurations["reviewedExampleRetrieval"])
    await store.close()
  }
}
