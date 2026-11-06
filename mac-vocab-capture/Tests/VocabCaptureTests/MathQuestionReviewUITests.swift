import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionReviewUITests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  private func image() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    return try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
  }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("UI state did not settle")
  }

  func testRestoreInvalidatesQueuedReferenceWriteAndOldSaveCallbacks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let record = try await store.save(.init(captureID: "review-before-restore", imageData: image()))
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    var callbacks = 0
    let editor = MathQuestionReviewPanel(store: store, questionID: record.id, onSave: { callbacks += 1 })
    let views = descendants(editor.panel.contentView!)
    try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first).string = "旧窗口尚未提交的答案"
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
    // No yield between clicking and invalidation: the queued write must be guarded.
    save.performClick(nil)
    await editor.prepareForLibraryRestore()
    _ = try await store.restoreBackup(from: backup)
    save.performClick(nil)
    await editor.prepareForLibraryRestore()
    let references = try await store.referenceAnswers(questionID: record.id)
    XCTAssertTrue(references.isEmpty)
    XCTAssertEqual(callbacks, 0)
    await store.close()
  }

  func testReferenceAndReviewSheetsPersistUserDecisionWithoutReplacingAIAnswer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let solution = MathQuestionSolution(question: "解题", answer: "错误的 AI 原回答", model: "test")
    let record = try await store.save(
      .init(captureID: "review", imageData: image(), solutions: [solution]))
    let referencePanel = MathQuestionReviewPanel(store: store, questionID: record.id, onSave: {})
    let referenceViews = descendants(referencePanel.panel.contentView!)
    let text = try XCTUnwrap(referenceViews.compactMap { $0 as? NSTextView }.first)
    text.string = "653 × 74 = 48322"
    let source = try XCTUnwrap(
      referenceViews.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString?.hasPrefix("来源") == true
      })
    source.stringValue = "教师答案"
    let save = try XCTUnwrap(
      referenceViews.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
    save.performClick(nil)
    try await settle { try await store.referenceAnswers(questionID: record.id).count == 1 }
    let references = try await store.referenceAnswers(questionID: record.id)
    var solutions = try await store.solutions(questionID: record.id)
    XCTAssertEqual(solutions.first?.verificationStatus, "unverified")
    let reviewPanel = MathQuestionReviewPanel(
      store: store, questionID: record.id, solutions: solutions, references: references, onSave: {})
    let views = descendants(reviewPanel.panel.contentView!)
    let decision = try XCTUnwrap(
      views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("标记有误") })
    decision.selectItem(withTitle: "标记有误")
    let referencePicker = try XCTUnwrap(
      views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("不指定参考答案，直接核验") })
    referencePicker.selectItem(at: 1)
    referencePicker.sendAction(referencePicker.action, to: referencePicker.target)
    let correction = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.isEditable })
    correction.string = "最大积为 48322，原答案未比较所有组合。"
    let saveReview = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
    saveReview.performClick(nil)
    try await settle { try await store.reviews(solutionID: solution.id).count == 1 }
    let reviews = try await store.reviews(solutionID: solution.id)
    solutions = try await store.solutions(questionID: record.id)
    XCTAssertEqual(solutions.first?.answer, solution.answer)
    XCTAssertEqual(solutions.first?.verificationStatus, "rejected")
    XCTAssertEqual(reviews.first?.referenceID, references.first?.id)
    XCTAssertEqual(reviews.first?.correction, correction.string)
    referencePanel.panel.close()
    reviewPanel.panel.close()
    await store.close()
  }

  func testMethodSelectionSendsInstructionsAndSavesTheSelectedVersion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defer { try? FileManager.default.removeItem(at: directory) }
    let method = try await store.saveMethod(
      title: "盈亏问题", category: "四年级", instructions: "先求总差，再求每份差。仅适用于两种分配。")
    let bytes = try image()
    var submitted = ""
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "公开测试题", selectedWord: nil, imageData: bytes),
      answer: { question, _, _, _ in
        if submitted.isEmpty { submitted = question }
        return "测试回答"
      },
      interfaceDefaults: defaults, originalImageData: bytes,
      saveQuestion: { request in try await store.save(request) }, mathStore: store)
    defer { panel.close() }
    panel.present()
    let views = descendants(panel.contentView!)
    let picker = try XCTUnwrap(
      views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("不指定解题方法") })
    try await settle { picker.numberOfItems == 2 }
    XCTAssertEqual(picker.indexOfSelectedItem, 0)
    picker.selectItem(at: 1)
    picker.sendAction(picker.action, to: picker.target)
    let input = try XCTUnwrap(
      views.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString?.hasPrefix("例如") == true
      })
    input.stringValue = "用小学方法解题"
    let ask = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    ask.performClick(nil)
    try await settle { !panel.isAnswering && !panel.history.isEmpty }
    XCTAssertTrue(submitted.contains(method.instructions))
    XCTAssertTrue(submitted.contains("不补造题目条件"))
    XCTAssertEqual(panel.history.first?.question, "用小学方法解题")
    _ = try await store.saveMethod(
      id: method.id, title: "修改后的方法", category: "四年级", instructions: "新的步骤")
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" })
    save.performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(solutions.first?.method, method)
    XCTAssertEqual(solutions.first?.question, "用小学方法解题")
    XCTAssertEqual(
      ScreenshotQuestionPanel.question("Explain this sentence", using: nil), "Explain this sentence"
    )
    await store.close()
  }

  func testPhotoOnlyLibraryOffersReferencesWithoutRequiringAnAISolution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = try await store.save(.init(captureID: "photo", imageData: image()))
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.present(questionID: record.id)
    let buttons = descendants(library.contentView!).compactMap { $0 as? NSButton }
    let reference = try XCTUnwrap(buttons.first { $0.title == "参考答案…" })
    let review = try XCTUnwrap(buttons.first { $0.title == "核验答案…" })
    try await settle { reference.isEnabled }
    XCTAssertFalse(review.isEnabled)
    await store.close()
  }
}
