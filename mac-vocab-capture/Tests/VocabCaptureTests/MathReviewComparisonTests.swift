import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathReviewComparisonTests: XCTestCase {
  private func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
  private func settle(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<200 { if try await condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTFail("Review comparison did not settle")
  }
  func testReviewShowsStoredOriginalAndActualDiagramWithoutMakingDecision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-comparison-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let bytes = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.area)
    let solution = MathQuestionSolution(question: "算术解题", answer: "原始模型回答", model: "fixture", diagrams: [MathDiagramFixtures.bar])
    let q = try await store.save(.init(captureID: "comparison", imageData: bytes, solutions: [solution]))
    let reference = try await store.addReferenceAnswer(questionID: q.id, text: "参考答案", source: "fixture", scope: "最终答案", imageData: bytes)
    let panel = MathQuestionReviewPanel(store: store, questionID: q.id, solutions: [solution], references: [reference], onSave: {})
    defer { panel.panel.close() }
    let views = descendants(try XCTUnwrap(panel.panel.contentView))
    let original = try XCTUnwrap(views.compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "待核验题目原图" })
    try await settle { original.image != nil }
    let answer = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "待核验回答及图解" })
    var attachmentCount = 0
    answer.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: answer.string.utf16.count)) { value, _, _ in
      if value is NSTextAttachment { attachmentCount += 1 }
    }
    XCTAssertEqual(attachmentCount, 1)
    XCTAssertTrue(answer.string.contains(solution.answer))
    XCTAssertFalse(answer.isEditable)
    panel.panel.setContentSize(NSSize(width: 900, height: 780))
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    let imageFrame = original.convert(original.bounds, to: panel.panel.contentView)
    let answerFrame = answer.enclosingScrollView!.convert(answer.enclosingScrollView!.bounds, to: panel.panel.contentView)
    XCTAssertLessThanOrEqual(imageFrame.maxX, answerFrame.minX)
    let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "核验参考答案" })
    picker.selectItem(at: 1); picker.sendAction(picker.action, to: picker.target)
    try await settle { views.compactMap { $0 as? NSImageView }.filter { $0.image != nil }.count == 2 }
    panel.panel.contentView?.layoutSubtreeIfNeeded()
    let content = try XCTUnwrap(panel.panel.contentView)
    for button in views.compactMap({ $0 as? NSButton }).filter({ ["保存", "取消"].contains($0.title) }) {
      let frame = button.convert(button.bounds, to: content)
      XCTAssertGreaterThanOrEqual(frame.minY, 0)
      XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height)
      XCTAssertGreaterThanOrEqual(frame.minX, 0)
      XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width)
    }
    let reviews = try await store.reviews(solutionID: solution.id)
    XCTAssertTrue(reviews.isEmpty)
    let stored = try await store.originalImage(questionID: q.id)
    XCTAssertEqual(stored, bytes)
    await panel.prepareForLibraryRestore(); await store.close()
  }
  func testSaveAndNextRequiresExplicitDecisionAndKeepsOriginalAnswer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-next-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let solution = MathQuestionSolution(question: "fixture", answer: "原回答保留", model: "test")
    let q = try await store.save(.init(captureID: "next", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.area), solutions: [solution]))
    var events: [String] = []
    let panel = MathQuestionReviewPanel(store: store, questionID: q.id, solutions: [solution], onNext: { events.append("next") }, onSave: { events.append("saved") })
    let views = descendants(try XCTUnwrap(panel.panel.contentView))
    let next = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存并下一题" })
    XCTAssertFalse(next.isEnabled)
    next.performClick(nil)
    XCTAssertTrue(events.isEmpty)
    let decision = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "用户核验决定" })
    decision.selectItem(withTitle: "用户确认"); decision.sendAction(decision.action, to: decision.target)
    XCTAssertTrue(next.isEnabled, "Final-answer feedback can advance without certifying process")
    let scope = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "核验范围" })
    XCTAssertEqual(scope.titleOfSelectedItem, "最终答案", "Never silently certify the whole process")
    next.performClick(nil)
    try await settle { events.count == 2 }
    XCTAssertEqual(events, ["saved", "next"])
    let saved = try await store.solutions(questionID: q.id)
    XCTAssertEqual(saved.first?.answer, solution.answer)
    let reviews = try await store.reviews(solutionID: solution.id)
    XCTAssertEqual(reviews.count, 1); XCTAssertEqual(reviews.first?.scope, "最终答案")
    await store.close()
  }

  func testFailedSaveDoesNotAdvanceOrInventReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-failed-next-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let existing = MathQuestionSolution(question: "fixture", answer: "有效回答", model: "test")
    let q = try await store.save(.init(captureID: "failed", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.area), solutions: [existing]))
    let stale = MathQuestionSolution(question: "fixture", answer: "不存在的旧回答", model: "test")
    var callbacks = 0
    let panel = MathQuestionReviewPanel(store: store, questionID: q.id, solutions: [stale], onNext: { callbacks += 1 }, onSave: { callbacks += 1 })
    let views = descendants(try XCTUnwrap(panel.panel.contentView))
    let next = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存并下一题" })
    let decision = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "用户核验决定" })
    decision.selectItem(withTitle: "标记有误"); decision.sendAction(decision.action, to: decision.target)
    next.performClick(nil)
    try await settle { next.isEnabled }
    XCTAssertEqual(callbacks, 0)
    XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("保存失败") })
    let reviews = try await store.reviews(solutionID: existing.id)
    XCTAssertTrue(reviews.isEmpty)
    await panel.prepareForLibraryRestore(); await store.close()
  }

}
