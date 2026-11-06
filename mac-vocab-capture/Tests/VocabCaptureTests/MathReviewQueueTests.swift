import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathReviewQueueTests: XCTestCase {
  func testConfirmationLeavesOptionalQueueWithoutCertifyingProcess() {
    let answers = ["unverified", "confirmed", "rejected", "unverified"].map {
      MathQuestionSolution(question: "题目", answer: "回答", model: "test", verificationStatus: $0)
    }
    func review(_ scope: String) -> MathSolutionReview {
      .init(id: UUID().uuidString, solutionID: answers[1].id, status: "confirmed", scope: scope,
        note: "", correction: "", referenceID: nil, createdAt: Date())
    }
    let finalOnly = review("最终答案")
    let full = review("答案及解题过程")
    XCTAssertEqual(MathReviewQueue.pendingCount(answers), 2, "Already confirmed answers do not demand another review")
    XCTAssertEqual(MathReviewQueue.pendingCount(answers, reviews: [answers[1].id: [finalOnly]]), 2)
    XCTAssertEqual(MathReviewQueue.pendingCount(answers, reviews: [answers[1].id: [finalOnly, full]]), 2)
    XCTAssertEqual(MathReviewQueue.pendingCount(answers, reviews: [answers[1].id: [full, finalOnly]]), 2,
      "Latest explicit review defines current scope")
    XCTAssertEqual(MathReviewQueue.pendingCount([]), 0)
    XCTAssertEqual(MathReviewQueue.pendingCount(Array(answers[1...2]), reviews: [answers[1].id: [full]]), 0)
    XCTAssertEqual(answers.map(\.verificationStatus), ["unverified", "confirmed", "rejected", "unverified"])
  }

  func testNextKeepsRemainingAnswerThenAdvancesWithoutWrappingOrIncludingNewRows() {
    let order = ["first", "current", "last"]
    XCTAssertEqual(MathReviewQueue.nextID(after: "current", order: order, pendingIDs: ["current", "last"]), "current")
    XCTAssertEqual(MathReviewQueue.nextID(after: "current", order: order, pendingIDs: ["first", "last"]), "last")
    XCTAssertNil(MathReviewQueue.nextID(after: "last", order: order, pendingIDs: ["first"]))
    XCTAssertNil(MathReviewQueue.nextID(after: "current", order: order, pendingIDs: ["new"]))
    XCTAssertNil(MathReviewQueue.nextID(after: "missing", order: order, pendingIDs: ["first"]))
  }

  func testSaveAndNextReopensRemainingAnswerWithoutSilentlyReviewingIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let bytes = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
    let first = MathQuestionSolution(question: "解题", answer: "第一份回答", model: "test")
    let second = MathQuestionSolution(question: "解题", answer: "第二份回答", model: "test")
    let record = try await store.save(.init(captureID: "two-answers", imageData: bytes, solutions: [first, second]))
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { for sheet in library.sheets { library.endSheet(sheet); sheet.close() }; library.close() }
    library.present(questionID: record.id)
    try await settle { library.selectedID == record.id }
    let start = try XCTUnwrap(views(try XCTUnwrap(library.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "抽查核验" })
    try await settle { start.isEnabled }
    start.performClick(nil)
    try await settle { library.sheets.count == 1 }
    let initialSheet = try XCTUnwrap(library.sheets.first)
    let children = views(try XCTUnwrap(initialSheet.contentView))
    let decision = try XCTUnwrap(children.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "用户核验决定" })
    let scope = try XCTUnwrap(children.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "核验范围" })
    let next = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "保存并下一题" })
    XCTAssertFalse(next.isEnabled, "Unresolved review cannot advance")
    next.performClick(nil)
    let beforeReviews = try await store.reviews(solutionID: first.id)
    XCTAssertTrue(beforeReviews.isEmpty)
    decision.selectItem(withTitle: "用户确认")
    decision.sendAction(decision.action, to: decision.target)
    XCTAssertEqual(scope.titleOfSelectedItem, "最终答案")
    XCTAssertTrue(next.isEnabled)
    next.performClick(nil)
    try await settle { library.sheets.count == 1 && library.sheets.first !== initialSheet }
    XCTAssertEqual(library.selectedID, record.id, "Remaining answer stays on same question")
    let remainingSheet = try XCTUnwrap(library.sheets.first)
    let picker = try XCTUnwrap(views(try XCTUnwrap(remainingSheet.contentView)).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择需要核验的回答" })
    XCTAssertEqual(picker.indexOfSelectedItem, 1)
    let firstReviews = try await store.reviews(solutionID: first.id)
    let secondReviews = try await store.reviews(solutionID: second.id)
    XCTAssertEqual(firstReviews.count, 1)
    XCTAssertEqual(firstReviews.first?.scope, "最终答案", "Advancing must not certify the process")
    XCTAssertTrue(secondReviews.isEmpty)
    let remainingViews = views(try XCTUnwrap(remainingSheet.contentView))
    let secondDecision = try XCTUnwrap(remainingViews.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "用户核验决定" })
    secondDecision.selectItem(withTitle: "标记有误")
    secondDecision.sendAction(secondDecision.action, to: secondDecision.target)
    let lastNext = try XCTUnwrap(remainingViews.compactMap { $0 as? NSButton }.first { $0.title == "保存并下一题" })
    lastNext.performClick(nil)
    let libraryContent = try XCTUnwrap(library.contentView)
    try await settle {
      library.sheets.isEmpty && self.views(libraryContent).compactMap { $0 as? NSTextField }
        .contains { $0.stringValue.hasPrefix("已到当前审核队列末尾") }
    }
    let status = try XCTUnwrap(views(try XCTUnwrap(library.contentView)).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("已到当前审核队列末尾") })
    XCTAssertTrue(status.stringValue.contains("末尾"))
    let finalReviews = try await store.reviews(solutionID: second.id)
    XCTAssertEqual(finalReviews.count, 1)
    await store.close()
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Queue did not settle")
  }

  func testPendingFilterPreservesSearchAndGradeAndNeverWritesReview() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let bytes = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
    let pending = MathQuestionSolution(question: "解题", answer: "待审回答", model: "test")
    let included = try await store.save(.init(captureID: "included", imageData: bytes, solutions: [pending]))
    let noAnswer = try await store.save(.init(captureID: "photo-only", imageData: bytes))
    let otherGrade = try await store.save(.init(captureID: "grade-five", imageData: bytes,
      solutions: [.init(question: "解题", answer: "回答", model: "test")]))
    try await store.updateQuestionGrade(questionID: included.id, grade: 4)
    try await store.updateQuestionGrade(questionID: noAnswer.id, grade: 4)
    try await store.updateQuestionGrade(questionID: otherGrade.id, grade: 5)
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.present()
    try await settle { library.records.count == 3 }
    let children = views(try XCTUnwrap(library.contentView))
    let grade = try XCTUnwrap(children.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "按年级筛选题库" })
    grade.selectItem(at: 4)
    grade.sendAction(grade.action, to: grade.target)
    try await settle { library.records.count == 2 }
    let search = try XCTUnwrap(children.compactMap { $0 as? NSSearchField }.first)
    search.stringValue = "未命名"
    library.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    try await settle { library.records.count == 2 }
    let only = try XCTUnwrap(children.compactMap { $0 as? NSButton }.first { $0.title == "仅未审核" })
    only.performClick(nil)
    try await settle { library.records.map(\.id) == [included.id] }
    XCTAssertEqual(grade.indexOfSelectedItem, 4)
    XCTAssertEqual(search.stringValue, "未命名")
    let count = try XCTUnwrap(children.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "待核验题目与回答数量" })
    XCTAssertEqual(count.stringValue, "可选抽查：1 道未审核 · 1 份回答")
    only.performClick(nil)
    try await settle { library.records.count == 2 }
    let stored = try await store.solutions(questionID: included.id)
    let reviews = try await store.reviews(solutionID: pending.id)
    XCTAssertEqual(stored.first?.verificationStatus, "unverified")
    XCTAssertTrue(reviews.isEmpty)
    // Final-answer feedback leaves the optional queue without certifying the process.
    _ = try await store.reviewSolution(questionID: included.id, solutionID: pending.id,
      status: "confirmed", scope: "最终结果", note: "只检查答案", correction: "")
    only.performClick(nil)
    try await settle { library.records.isEmpty && count.stringValue == "可选抽查：0 道未审核 · 0 份回答" }
    _ = try await store.reviewSolution(questionID: included.id, solutionID: pending.id,
      status: "confirmed", scope: "答案及解题过程", note: "明确确认全过程", correction: "")
    library.refresh()
    try await settle { library.records.isEmpty && count.stringValue == "可选抽查：0 道未审核 · 0 份回答" }
    XCTAssertEqual(grade.indexOfSelectedItem, 4)
    XCTAssertEqual(search.stringValue, "未命名")
    let completedReviews = try await store.reviews(solutionID: pending.id)
    XCTAssertEqual(completedReviews.count, 2, "Filtering and navigation never generate human decisions")
    await store.close()
  }
}
