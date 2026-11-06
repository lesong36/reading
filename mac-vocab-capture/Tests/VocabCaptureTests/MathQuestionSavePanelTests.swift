import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionSavePanelTests: XCTestCase {
  private let fullImage = Data([1, 2, 3, 4])
  private let modelImage = Data([7, 8])

  private var context: ScreenshotQuestionContext {
    ScreenshotQuestionContext(text: "公开数学题", selectedWord: nil, imageData: modelImage)
  }

  private func makePanel(
    _ save: QuestionSaveGate, answer: QuestionAnswerGate? = nil,
    model: (@MainActor () -> String)? = nil,
    original: Data? = Data([1, 2, 3, 4])
  ) -> ScreenshotQuestionPanel {
    _ = NSApplication.shared
    let answer = answer ?? QuestionAnswerGate()
    return ScreenshotQuestionPanel(
      context: context, answer: answer.answer, originalImageData: original,
      saveQuestion: { try await save.save($0) }, solutionModel: model)
  }

  func testOriginalCanBeSavedWithoutAnswerAndRepeatedClickIsIdempotent() async throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves)
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    XCTAssertTrue(panel.isSavingQuestion)
    XCTAssertEqual(saves.requests[0].request.imageData, fullImage)
    XCTAssertNotEqual(saves.requests[0].request.imageData, modelImage)
    XCTAssertTrue(saves.requests[0].request.solutions.isEmpty)
    try saveButton(panel).performClick(nil)
    XCTAssertEqual(saves.requests.count, 1)
    saves.succeed(0)
    try await wait { !panel.isSavingQuestion }
    XCTAssertEqual(panel.savedQuestionID, "question-1")
    XCTAssertTrue(status(panel).contains("暂无解题过程"))
    try saveButton(panel).performClick(nil)
    await Task.yield()
    XCTAssertEqual(saves.requests.count, 1)
  }

  func testNoOriginalNeverFallsBackToReducedModelImage() throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves, original: nil)
    defer { panel.close() }
    XCTAssertFalse(try saveButton(panel).isEnabled)
    XCTAssertTrue(status(panel).contains("缺少原始截图"))
    try saveButton(panel).performClick(nil)
    XCTAssertTrue(saves.requests.isEmpty)
  }

  func testGenerationDoesNotBlockImageSaveAndCompletedAnswerAppendsWithModelSnapshot() async throws
  {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    var model = "model-at-start"
    let panel = makePanel(saves, answer: answers, model: { model })
    defer { panel.close() }
    try submit("解题", panel)
    try await wait { answers.requests.count == 1 }
    answers.requests[0].partial("部分答案")
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    XCTAssertTrue(saves.requests[0].request.solutions.isEmpty)
    model = "changed-model"
    answers.succeed(0, "完整解答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(saves.requests.count, 1, "不应并发写同一捕获")
    saves.succeed(0)
    try await wait { saves.requests.count == 2 }
    let request = saves.requests[1].request
    XCTAssertEqual(request.captureID, saves.requests[0].request.captureID)
    XCTAssertEqual(request.solutions.count, 1)
    XCTAssertEqual(request.solutions[0].answer, "完整解答")
    XCTAssertEqual(request.solutions[0].model, "model-at-start")
    saves.succeed(1)
    try await wait { !panel.isSavingQuestion }
    XCTAssertTrue(status(panel).contains("尚未核实"))
  }

  func testSavedQuestionAutoAppendsAndClearingConversationDoesNotEraseSavedSolutions() async throws
  {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    saves.succeed(0)
    try await wait { !panel.isSavingQuestion }
    try submit("第一问", panel)
    try await wait { answers.requests.count == 1 }
    answers.succeed(0, "第一完整答案")
    try await wait { saves.requests.count == 2 }
    let firstID = saves.requests[1].request.solutions[0].id
    saves.succeed(1)
    try await wait { !panel.isSavingQuestion }
    try button("清空对话", panel).performClick(nil)
    try submit("第二问", panel)
    try await wait { answers.requests.count == 2 }
    answers.succeed(1, "第二完整答案")
    try await wait { saves.requests.count == 3 }
    let solutions = saves.requests[2].request.solutions
    XCTAssertEqual(solutions.map(\.answer), ["第一完整答案", "第二完整答案"])
    XCTAssertEqual(solutions[0].id, firstID)
    XCTAssertNotEqual(solutions[0].id, solutions[1].id)
    saves.succeed(2)
    try await wait { !panel.isSavingQuestion }
  }

  func testFailedAndStoppedAnswersAreNotSavedAsSolutions() async throws {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    defer { panel.close() }
    try submit("会失败", panel)
    try await wait { answers.requests.count == 1 }
    answers.requests[0].partial("失败片段")
    answers.fail(0)
    try await wait { !panel.isAnswering }
    try submit("会停止", panel)
    try await wait { answers.requests.count == 2 }
    answers.requests[1].partial("停止片段")
    try button("停止", panel).performClick(nil)
    answers.succeed(1, "迟到结果")
    await Task.yield()
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    XCTAssertTrue(saves.requests[0].request.solutions.isEmpty)
    saves.succeed(0)
    try await wait { !panel.isSavingQuestion }
  }

  func testSaveFailureCanRetryWithSameCaptureIdentity() async throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves)
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    saves.fail(0)
    try await wait { !panel.isSavingQuestion }
    XCTAssertTrue(status(panel).contains("保存失败"))
    XCTAssertTrue(try saveButton(panel).isEnabled)
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 2 }
    XCTAssertEqual(saves.requests[0].request.captureID, saves.requests[1].request.captureID)
    saves.succeed(1)
    try await wait { !panel.isSavingQuestion }
  }

  func testSameImageSelectionChangesKeepSavedRecord() async throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves)
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    saves.succeed(0)
    try await wait { !panel.isSavingQuestion }
    panel.updateContext(
      ScreenshotQuestionContext(text: "修正后的原文", selectedWord: "word", imageData: modelImage))
    XCTAssertEqual(panel.savedQuestionID, "question-1")
    try saveButton(panel).performClick(nil)
    await Task.yield()
    XCTAssertEqual(saves.requests.count, 1)
  }

  func testNewCaptureAndLateSaveCallbackDoNotPolluteNewCapture() async throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves)
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    let newOriginal = Data([9, 9, 9])
    panel.updateContext(
      ScreenshotQuestionContext(text: "新题", selectedWord: nil, imageData: Data([9])),
      originalImageData: newOriginal)
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 2 }
    XCTAssertNotEqual(saves.requests[0].request.captureID, saves.requests[1].request.captureID)
    XCTAssertEqual(saves.requests[1].request.imageData, newOriginal)
    saves.succeed(0, id: "old-question")
    await Task.yield()
    XCTAssertNil(panel.savedQuestionID)
    XCTAssertTrue(panel.isSavingQuestion)
    saves.succeed(1, id: "new-question")
    try await wait { !panel.isSavingQuestion }
    XCTAssertEqual(panel.savedQuestionID, "new-question")
  }

  func testClosingWindowAllowsPersistenceButRejectsLateUIUpdate() async throws {
    let saves = QuestionSaveGate()
    let panel = makePanel(saves)
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    panel.close()
    saves.succeed(0)
    await Task.yield()
    XCTAssertNil(panel.savedQuestionID)
    XCTAssertFalse(panel.isSavingQuestion)
  }

  func testCompletedAnswerPersistsAfterClosingDuringInitialImageSave() async throws {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    try submit("解题", panel)
    try await wait { answers.requests.count == 1 }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    answers.succeed(0, "关窗前完整解答")
    try await wait { !panel.isAnswering }
    panel.close()
    saves.succeed(0)
    try await wait { saves.requests.count == 2 }
    XCTAssertEqual(saves.requests[1].request.captureID, saves.requests[0].request.captureID)
    XCTAssertEqual(saves.requests[1].request.solutions.map(\.answer), ["关窗前完整解答"])
    saves.succeed(1)
    await Task.yield()
    XCTAssertNil(panel.savedQuestionID, "落库继续，但关闭窗口的状态不应被更新")
  }

  func testReopenedCapturePreservesCompletedAnswerOnSecondClose() async throws {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    for cycle in 0..<2 {
      panel.present()
      try submit("第\(cycle + 1)问", panel)
      try await wait { answers.requests.count == cycle + 1 }
      try saveButton(panel).performClick(nil)
      try await wait { saves.requests.count == cycle * 2 + 1 }
      answers.succeed(cycle, "第\(cycle + 1)次完整解答")
      try await wait { !panel.isAnswering }
      panel.close()
      saves.succeed(cycle * 2)
      try await wait { saves.requests.count == cycle * 2 + 2 }
      XCTAssertEqual(saves.requests[cycle * 2 + 1].request.solutions.count, cycle + 1)
      saves.succeed(cycle * 2 + 1)
      await Task.yield()
    }
    XCTAssertNil(panel.savedQuestionID)
  }

  func testCompletedOldCapturePersistsAfterImageChangesDuringInitialSave() async throws {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    defer { panel.close() }
    try submit("原题解题", panel)
    try await wait { answers.requests.count == 1 }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    answers.succeed(0, "原题完整解答")
    try await wait { !panel.isAnswering }
    panel.updateContext(
      ScreenshotQuestionContext(text: "下一题", selectedWord: nil, imageData: Data([9])),
      originalImageData: Data([9, 9]))
    saves.succeed(0)
    try await wait { saves.requests.count == 2 }
    XCTAssertEqual(saves.requests[1].request.captureID, saves.requests[0].request.captureID)
    XCTAssertEqual(saves.requests[1].request.imageData, fullImage)
    XCTAssertEqual(saves.requests[1].request.ocrText, "公开数学题")
    XCTAssertEqual(saves.requests[1].request.solutions.map(\.answer), ["原题完整解答"])
    saves.succeed(1)
    await Task.yield()
    XCTAssertNil(panel.savedQuestionID)
    XCTAssertFalse(panel.isSavingQuestion)
  }

  func testDefaultSolveQuickPromptUsesScreenshot() async throws {
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    let panel = makePanel(saves, answer: answers)
    defer { panel.close() }
    let image = try button("参考原截图", panel)
    XCTAssertEqual(image.state, .off)
    try button("解题", panel).performClick(nil)
    try await wait { answers.requests.count == 1 }
    XCTAssertEqual(answers.requests[0].context.imageData, modelImage)
    XCTAssertTrue(answers.requests[0].question.contains("解题"))
    answers.succeed(0, "答案")
    try await wait { !panel.isAnswering }
  }

  func testSavedRecordOpensByIDAndSavingUIIsOptional() async throws {
    _ = NSApplication.shared
    let saves = QuestionSaveGate()
    var opened: String?
    let panel = ScreenshotQuestionPanel(
      context: context, answer: { _, _, _, _ in "完整回答" }, originalImageData: fullImage,
      saveQuestion: { try await saves.save($0) }, onOpenQuestion: { opened = $0 })
    defer { panel.close() }
    try saveButton(panel).performClick(nil)
    try await wait { saves.requests.count == 1 }
    saves.succeed(0, id: "saved-record")
    try await wait { !panel.isSavingQuestion }
    try button("查看已保存题目", panel).performClick(nil)
    XCTAssertEqual(opened, "saved-record")
    let unchanged = ScreenshotQuestionPanel(context: context, answer: { _, _, _, _ in "回答" })
    defer { unchanged.close() }
    XCTAssertTrue(try saveButton(unchanged).isHidden)
    XCTAssertFalse(try button("解题", unchanged).isHidden)
  }

  func testCustomSolvePromptHasOneEntryAndKeepsItsConfiguredContent() async throws {
    let suite = "solve-prompt-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prompts = ScreenshotQuestionQuickPrompts(defaults: defaults)
    let custom = ScreenshotQuestionQuickPrompt(title: "解题", prompt: "请用四年级的方法解释解题步骤。")
    try prompts.save([custom])
    let answers = QuestionAnswerGate()
    let panel = ScreenshotQuestionPanel(
      context: context, answer: answers.answer, quickPrompts: prompts,
      originalImageData: fullImage, saveQuestion: { _ in throw NSError(domain: "Unused", code: 1) })
    defer { panel.close() }
    panel.refreshSuggestions()
    let buttons = views(panel.contentView!).compactMap { $0 as? NSButton }.filter {
      $0.title == "解题"
    }
    XCTAssertEqual(buttons.count, 1)
    XCTAssertEqual(prompts.prompts, [custom], "合并入口不应删除用户配置")
    try button("解题", panel).performClick(nil)
    try await wait { answers.requests.count == 1 }
    XCTAssertEqual(answers.requests[0].question, custom.prompt)
    XCTAssertEqual(answers.requests[0].context.imageData, modelImage)
    answers.succeed(0, "答案")
    try await wait { !panel.isAnswering }

    let generic = ScreenshotQuestionPanel(
      context: context, answer: answers.answer, quickPrompts: prompts)
    defer { generic.close() }
    let visible = views(generic.contentView!).compactMap { $0 as? NSButton }
      .filter { $0.title == "解题" && !$0.isHidden }
    XCTAssertEqual(visible.count, 1, "没有题库操作时仍显示用户的快捷问题")
  }

  func testSolveCanBeEditedRenamedAndDeletedThroughQuickPromptSettings() async throws {
    let suite = "editable-solve-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let prompts = ScreenshotQuestionQuickPrompts(defaults: defaults)
    try prompts.save([.init(id: "solve", title: "解题", prompt: "原提示词")])
    let answers = QuestionAnswerGate()
    let panel = ScreenshotQuestionPanel(
      context: context, answer: answers.answer, quickPrompts: prompts,
      originalImageData: fullImage, saveQuestion: { _ in throw NSError(domain: "Unused", code: 1) })
    defer { panel.close() }
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: prompts) {
      panel.refreshSuggestions()
    }
    settings.present()
    let title = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "快捷问题 1 标题" })
    let content = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSTextView }
        .first { $0.accessibilityLabel() == "快捷问题 1 内容" })
    title.stringValue = "四年级解题"
    content.string = "不用方程，先说明数量关系。"
    let save = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "保存" })
    save.performClick(nil)
    XCTAssertFalse(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .contains { $0.title == "解题" }, "改名后不应残留固定解题按钮")
    try button("四年级解题", panel).performClick(nil)
    try await wait { answers.requests.count == 1 }
    XCTAssertEqual(answers.requests[0].question, "不用方程，先说明数量关系。")
    XCTAssertEqual(answers.requests[0].context.imageData, modelImage)
    answers.succeed(0, "回答")
    try await wait { !panel.isAnswering }
    settings.present()
    let remove = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "删除" })
    remove.performClick(nil)
    save.performClick(nil)
    XCTAssertTrue(prompts.prompts.isEmpty)
    XCTAssertFalse(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .contains { $0.title == "解题" || $0.title == "四年级解题" })
    XCTAssertNotNil(try saveButton(panel), "删除解题快捷问题不影响存图")
  }

  func testOCRQuestionSubwindowReceivesFullOriginalAndSaveHooks() async throws {
    _ = NSApplication.shared
    let saves = QuestionSaveGate()
    let answers = QuestionAnswerGate()
    var opened: String?
    let panel = OCRLookupPanel(
      text: "公开数学题", lookup: { _, _ in throw NSError(domain: "Unused", code: 1) },
      save: { _, _ in "未使用" }, imageData: modelImage, ask: answers.answer,
      originalImageData: fullImage, saveQuestion: { try await saves.save($0) },
      onOpenQuestion: { opened = $0 }, solutionModel: { "子窗口模型" })
    defer { panel.close() }
    let open = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "问一问…" })
    open.performClick(nil)
    let questions = try XCTUnwrap(
      NSApp.windows.compactMap { $0 as? ScreenshotQuestionPanel }
        .first { $0.isVisible })
    try button("解题", questions).performClick(nil)
    try await wait { answers.requests.count == 1 }
    answers.succeed(0, "子窗口完整解答")
    try await wait { !questions.isAnswering }
    try saveButton(questions).performClick(nil)
    try await wait { saves.requests.count == 1 }
    XCTAssertEqual(saves.requests[0].request.imageData, fullImage)
    XCTAssertEqual(saves.requests[0].request.solutions.first?.model, "子窗口模型")
    saves.succeed(0)
    try await wait { !questions.isSavingQuestion }
    try button("查看已保存题目", questions).performClick(nil)
    XCTAssertEqual(opened, "question-1")
  }

  private func submit(_ text: String, _ panel: ScreenshotQuestionPanel) throws {
    let field = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "提问内容" })
    field.stringValue = text
    try button("提问", panel).performClick(nil)
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func button(_ title: String, _ panel: ScreenshotQuestionPanel) throws -> NSButton {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
  }
  private func saveButton(_ panel: ScreenshotQuestionPanel) throws -> NSButton {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.accessibilityLabel() == "保存题目原图" })
  }
  private func status(_ panel: ScreenshotQuestionPanel) -> String {
    views(panel.contentView!).compactMap { $0 as? NSTextField }
      .first { $0.accessibilityLabel() == "题目保存状态" }!.stringValue
  }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("等待状态超时")
  }
}

@MainActor
private final class QuestionSaveGate {
  struct Request {
    let request: MathQuestionSaveRequest
    let continuation: CheckedContinuation<MathQuestionRecord, Error>
  }
  var requests: [Request] = []
  func save(_ request: MathQuestionSaveRequest) async throws -> MathQuestionRecord {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(Request(request: request, continuation: continuation))
    }
  }
  func succeed(_ index: Int, id: String = "question-1") {
    requests[index].continuation.resume(
      returning: MathQuestionRecord(
        id: id, title: "公开题目", createdAt: Date(), imageWidth: 100, imageHeight: 100,
        ocrText: requests[index].request.ocrText, ocrStatus: "indexed"))
  }
  func fail(_ index: Int) {
    requests[index].continuation.resume(throwing: NSError(domain: "SaveTest", code: 1))
  }
}

@MainActor
private final class QuestionAnswerGate {
  struct Request {
    let question: String
    let context: ScreenshotQuestionContext
    let partial: @MainActor @Sendable (String) -> Void
    let continuation: CheckedContinuation<String, Error>
  }
  var requests: [Request] = []
  func answer(
    _ question: String, _ context: ScreenshotQuestionContext, _ history: [ScreenshotQuestionTurn],
    _ partial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(
        Request(question: question, context: context, partial: partial, continuation: continuation))
    }
  }
  func succeed(_ index: Int, _ answer: String) {
    requests[index].continuation.resume(returning: answer)
  }
  func fail(_ index: Int) {
    requests[index].continuation.resume(throwing: NSError(domain: "AnswerTest", code: 1))
  }
}
