import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotQuestionPanelTests: XCTestCase {
  func testPinSurvivesAppDeactivationAndCaptureRestoreAndCanBeDisabled() throws {
    let suite = "VocabCapture.PinTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(context: context, answer: gate.answer, interfaceDefaults: defaults)
    panel.present()
    defer { panel.close() }
    let pin = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }
      .first { $0.accessibilityLabel() == "置顶问答窗口" })
    XCTAssertFalse(panel.keepsOnTop)
    pin.performClick(nil)
    XCTAssertTrue(panel.keepsOnTop)
    panel.resignKey()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    XCTAssertEqual(panel.level, .floating)
    panel.orderOut(nil)
    XCTAssertFalse(panel.isVisible)
    panel.present()
    XCTAssertEqual(panel.level, .floating)
    let reopened = ScreenshotQuestionPanel(context: context, answer: gate.answer, interfaceDefaults: defaults)
    defer { reopened.close() }
    XCTAssertTrue(reopened.keepsOnTop)
    pin.performClick(nil)
    XCTAssertFalse(panel.keepsOnTop)
    XCTAssertEqual(panel.level, .normal)
    XCTAssertFalse(defaults.bool(forKey: "VocabCapture.questionWindowPinned"))
  }

  func testArithmeticContradictionIsVisibleWithoutChangingOriginalAnswer() async throws {
    let suite = "VocabCapture.ArithmeticNotice.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(context: context, answer: gate.answer, interfaceDefaults: defaults)
    defer { panel.close() }
    panel.present()
    try questionField(panel).stringValue = "核对面积"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    let original = "面积核对：1+2+3+4+5+4+4+6=25，正好25格。"
    gate.succeed(0, original)
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.last?.answer, original)
    XCTAssertTrue(transcript(panel).contains("算式核对提示"))
    XCTAssertTrue(transcript(panel).contains("29、25"))
    XCTAssertTrue(transcript(panel).contains(original))
  }

  func testModelPickerPersistsSelectionCancelsOldAnswerAndPreservesDraft() async throws {
    let suite = "VocabCapture.ModelPickerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenshotQuestionPreferences(
      defaults: defaults,
      readProfileAPIKey: { _ in "test-key" }, saveProfileAPIKey: { _, _ in })
    let first = try preferences.saveProfile(
      name: "快速问答",
      configuration:
        AIConfiguration(baseURL: "https://first.test/v1", model: "fast", apiKey: ""))
    let second = try preferences.saveProfile(
      name: "语法分析",
      configuration:
        AIConfiguration(baseURL: "https://second.test/v1", model: "strong", apiKey: ""))
    preferences.selectProfile(first)
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(
      context: context,
      answer: { question, context, history, partial in
        try await gate.answer(question, context, history, partial)
      }, modelPreferences: preferences)
    panel.present()
    let picker = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSPopUpButton }.first)
    XCTAssertEqual(picker.selectedItem?.representedObject as? String, first)
    try questionField(panel).stringValue = "第一问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    try questionField(panel).stringValue = "待提问草稿"
    picker.selectItem(at: 2)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    XCTAssertEqual(preferences.selectedProfileID, second)
    XCTAssertFalse(panel.isAnswering)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertEqual(try questionField(panel).stringValue, "待提问草稿")
    gate.requests[0].partial("迟到旧回答")
    gate.succeed(0, "迟到旧结果")
    await Task.yield()
    XCTAssertEqual(transcript(panel), "")
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertTrue(gate.requests[1].history.isEmpty)
    gate.succeed(1, "新模型回答")
    try await wait { !panel.isAnswering }
    picker.selectItem(at: 0)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    XCTAssertNil(preferences.selectedProfileID)
    XCTAssertTrue(panel.history.isEmpty)
    panel.close()
  }

  func testSubmittingSynchronizesVisibleModelBeforeDelayedMenuAction() async throws {
    let suite = "VocabCapture.DelayedModelActionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenshotQuestionPreferences(
      defaults: defaults,
      readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let id = try preferences.saveProfile(
      name: "新模型",
      configuration:
        AIConfiguration(baseURL: "https://model.test/v1", model: "new-model", apiKey: ""))
    let gate = AnswerGate()
    var submittedModel: String?
    let panel = ScreenshotQuestionPanel(
      context: context,
      answer: { question, context, history, partial in
        submittedModel =
          preferences.configuration(
            fallingBackTo:
              AIConfiguration(baseURL: "https://old.test/v1", model: "old-model", apiKey: "")
          ).model
        return try await gate.answer(question, context, history, partial)
      }, modelPreferences: preferences)
    let picker = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSPopUpButton }.first)
    picker.selectItem(at: 1)
    // Deliberately omit the popup action to reproduce delayed native menu delivery.
    try questionField(panel).stringValue = "使用新模型回答"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertEqual(preferences.selectedProfileID, id)
    XCTAssertEqual(submittedModel, "new-model")
    gate.succeed(0, "新回答")
    try await wait { !panel.isAnswering }
    panel.close()
  }

  func testStreamingAndFollowupKeepOnlyCompletedHistoryAndTypedQuestion() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    let field = try questionField(panel)
    let ask = try button("提问", panel)
    field.stringValue = "解释原文"
    ask.performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertTrue(panel.isAnswering)
    XCTAssertTrue(panel.history.isEmpty)
    gate.requests[0].partial("早期回答")
    XCTAssertTrue(transcript(panel).contains("早期回答"))
    field.stringValue = "为什么？"
    gate.succeed(0, "完整回答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(field.stringValue, "为什么？")
    XCTAssertEqual(panel.history.map(\.answer), ["完整回答"])
    ask.performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertEqual(gate.requests[1].history.map(\.question), ["解释原文"])
    XCTAssertEqual(gate.requests[1].history.map(\.answer), ["完整回答"])
    gate.succeed(1, "追问回答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.count, 2)
    panel.close()
  }

  func testBurstUpdatesCoalesceAfterImmediateFirstTextAndCompletionFlushes() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    try questionField(panel).stringValue = "测试流式刷新"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("第一段")
    XCTAssertTrue(transcript(panel).contains("第一段"))
    for index in 1...100 { gate.requests[0].partial("第一段，更新 \(index)") }
    XCTAssertFalse(transcript(panel).contains("更新 100"))
    try await wait { self.transcript(panel).contains("更新 100") }
    gate.requests[0].partial("完成前最后一个片段")
    gate.succeed(0, "完整结果")
    try await wait { !panel.isAnswering }
    XCTAssertTrue(transcript(panel).contains("完整结果"))
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(transcript(panel).contains("完成前最后一个片段"))
    panel.close()
  }

  func testStoppingFlushesBufferedTextAndDelayedRenderCannotRestoreClearedConversation()
    async throws
  {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    try questionField(panel).stringValue = "第一问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("第一段")
    gate.requests[0].partial("尚未刷新到界面的最新片段")
    try button("停止", panel).performClick(nil)
    XCTAssertTrue(transcript(panel).contains("尚未刷新到界面的最新片段"))
    try button("清空对话", panel).performClick(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(transcript(panel), "")
    gate.succeed(0, "迟到的旧回答")
    panel.close()
  }

  func testStopRejectsLateStreamAndCompletionWhileNextQuestionWorks() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    let field = try questionField(panel)
    field.stringValue = "第一问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("半段回答")
    try button("停止", panel).performClick(nil)
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(field.stringValue, "第一问")
    XCTAssertTrue(transcript(panel).contains("已停止，以上内容尚未完成"))
    field.stringValue = "第二问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    gate.requests[0].partial("旧回调不能显示")
    gate.succeed(0, "旧结果不能入历史")
    await Task.yield()
    XCTAssertFalse(transcript(panel).contains("旧回调不能显示"))
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertTrue(gate.requests[1].history.isEmpty)
    gate.succeed(1, "第二问的回答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.map(\.question), ["第二问"])
    panel.close()
  }

  func testSourceChangeClearsConversationAndIdenticalContextPreservesIt() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    try questionField(panel).stringValue = "问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.succeed(0, "原回答")
    try await wait { !panel.isAnswering }
    panel.updateContext(context)
    XCTAssertEqual(panel.history.count, 1)
    try questionField(panel).stringValue = "正在进行的追问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    panel.updateContext(
      ScreenshotQuestionContext(text: "New source.", selectedWord: nil, imageData: nil))
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(transcript(panel), "")
    gate.requests[1].partial("旧截图回答")
    gate.succeed(1, "旧截图结果")
    await Task.yield()
    XCTAssertEqual(transcript(panel), "")
    XCTAssertTrue(panel.history.isEmpty)
    panel.close()
  }

  func testFailureDoesNotEnterHistoryAndRetryReceivesCompletedTurnsOnly() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    try questionField(panel).stringValue = "失败的问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("未完成的内容")
    gate.fail(0)
    try await wait { !panel.isAnswering }
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertEqual(try questionField(panel).stringValue, "失败的问题")
    XCTAssertTrue(transcript(panel).contains("回答失败，以上内容尚未完成"))
    XCTAssertTrue(
      views(panel.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
        .contains { $0.contains("回答失败") })
    try questionField(panel).stringValue = "重试"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertTrue(gate.requests[1].history.isEmpty)
    gate.succeed(1, "成功")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.map(\.answer), ["成功"])
    panel.close()
  }

  func testClosingCancelsAndIgnoresLateCallbacks() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    panel.present()
    try questionField(panel).stringValue = "问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    panel.close()
    XCTAssertFalse(panel.isAnswering)
    let before = transcript(panel)
    gate.requests[0].partial("窗口关闭后不能写入")
    gate.succeed(0, "迟到结果")
    await Task.yield()
    XCTAssertEqual(transcript(panel), before)
    XCTAssertTrue(panel.history.isEmpty)
  }

  func testReturnUsesQuestionFieldActionAndNoVocabularySaveButton() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    let field = try questionField(panel)
    field.stringValue = "通过回车提问"
    let action = try XCTUnwrap(field.action)
    XCTAssertTrue(NSApp.sendAction(action, to: field.target, from: field))
    try await wait { gate.requests.count == 1 }
    XCTAssertEqual(gate.requests[0].question, "通过回车提问")
    let buttons = views(panel.contentView!).compactMap { $0 as? NSButton }
    XCTAssertFalse(buttons.contains { $0.title.contains("生词本") || $0.keyEquivalent == "\r" })
    gate.succeed(0, "答案")
    try await wait { !panel.isAnswering }
    panel.close()
  }

  func testStopAndFailurePreserveAlreadyTypedNextQuestion() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    let field = try questionField(panel)
    field.stringValue = "第一问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    field.stringValue = "我正在输入追问"
    try button("停止", panel).performClick(nil)
    XCTAssertEqual(field.stringValue, "我正在输入追问")
    gate.succeed(0, "忽略")
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    field.stringValue = "再下一问"
    gate.fail(1)
    try await wait { !panel.isAnswering }
    XCTAssertEqual(field.stringValue, "再下一问")
    XCTAssertTrue(panel.history.isEmpty)
    panel.close()
  }

  func testImageIsOptInWithTextAndRequiredWhenOnlyImageExists() async throws {
    let gate = AnswerGate()
    let image = Data([1, 2, 3])
    let panel = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(
        text: "Original sentence.", selectedWord: "Original", imageData: image),
      answer: gate.answer)
    let checkbox = try button("参考原截图", panel)
    XCTAssertEqual(checkbox.state, .off)
    try questionField(panel).stringValue = "先看文字"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertNil(gate.requests[0].context.imageData)
    gate.succeed(0, "文字回答")
    try await wait { !panel.isAnswering }
    checkbox.performClick(nil)
    XCTAssertTrue(panel.history.isEmpty)
    try questionField(panel).stringValue = "再看图片"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertEqual(gate.requests[1].context.imageData, image)
    gate.succeed(1, "图片回答")
    try await wait { !panel.isAnswering }
    panel.updateContext(ScreenshotQuestionContext(text: "", selectedWord: nil, imageData: image))
    XCTAssertEqual(checkbox.state, .on)
    XCTAssertFalse(checkbox.isEnabled)
    panel.close()
  }

  private var context: ScreenshotQuestionContext {
    ScreenshotQuestionContext(text: "Original sentence.", selectedWord: "Original", imageData: nil)
  }

  func testLongAnswersWrapToVisibleWidthAndReflowAfterResize() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    defer { panel.close() }
    panel.present()
    try questionField(panel).stringValue = "检查长回答"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    let longAnswer = String(
      repeating: "标准英语中，介词后使用宾格。 There's a new car in front of my sister and me. ",
      count: 20)
    gate.requests[0].partial(longAnswer)
    let text = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    let scroll = try XCTUnwrap(text.enclosingScrollView)
    let container = try XCTUnwrap(text.textContainer)
    let layout = try XCTUnwrap(text.layoutManager)
    panel.contentView?.layoutSubtreeIfNeeded()
    layout.ensureLayout(for: container)
    XCTAssertLessThanOrEqual(
      layout.usedRect(for: container).maxX + 2 * text.textContainerInset.width,
      scroll.contentSize.width + 1, "首次流式回答也必须换行")
    func lineCount(at width: CGFloat) -> Int {
      panel.setContentSize(NSSize(width: width, height: 580))
      panel.contentView?.layoutSubtreeIfNeeded()
      scroll.layoutSubtreeIfNeeded()
      layout.ensureLayout(for: container)
      XCTAssertLessThanOrEqual(
        layout.usedRect(for: container).maxX + 2 * text.textContainerInset.width,
        scroll.contentSize.width + 1, "回答不应超出可见区域")
      var lines = 0
      layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) {
        _, _, _, _, _ in lines += 1
      }
      return lines
    }
    let narrowLines = lineCount(at: 600)
    let wideLines = lineCount(at: 940)
    XCTAssertGreaterThan(narrowLines, wideLines, "窗口变宽后应重新排版")
    XCTAssertEqual(lineCount(at: 600), narrowLines, "缩窄窗口后应恢复换行")
    gate.succeed(0, longAnswer)
    try await wait { !panel.isAnswering }
    XCTAssertGreaterThan(lineCount(at: 600), 10)
    XCTAssertEqual(text.string, "你：检查长回答\n\n回答：" + longAnswer)
  }

  func testStreamedAnswerDoesNotInheritClippedParagraphLayout() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    defer { panel.close() }
    panel.present()
    try questionField(panel).stringValue = "继续解释"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("首段回答")
    let text = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    let clipped = NSMutableParagraphStyle()
    clipped.lineBreakMode = .byClipping
    text.textStorage?.addAttribute(
      .paragraphStyle, value: clipped, range: NSRange(location: 0, length: text.string.utf16.count))
    let answer = String(repeating: "长回答应在窗口内自动换行，不能沿用裁切段落的布局。", count: 30)
    gate.requests[0].partial(answer)
    try await wait { text.string.contains(answer) }
    let container = try XCTUnwrap(text.textContainer)
    let layout = try XCTUnwrap(text.layoutManager)
    layout.ensureLayout(for: container)
    XCTAssertLessThanOrEqual(
      layout.usedRect(for: container).maxX + 2 * text.textContainerInset.width,
      try XCTUnwrap(text.enclosingScrollView).contentSize.width + 1)
    XCTAssertGreaterThan(layout.usedRect(for: container).height, 100)
    gate.succeed(0, answer)
    try await wait { !panel.isAnswering }
  }

  func testModelSettingsOpensAndModelChangeRejectsOldResponse() async throws {
    let gate = AnswerGate()
    var opens = 0
    let panel = ScreenshotQuestionPanel(
      context: context, answer: gate.answer,
      onModelSettings: { opens += 1 })
    defer { panel.close() }
    let settings = try button("模型设置…", panel)
    XCTAssertFalse(settings.isHidden)
    settings.performClick(nil)
    XCTAssertEqual(opens, 1)
    try questionField(panel).stringValue = "切换前的问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.requests[0].partial("旧模型的部分回答")
    panel.modelConfigurationChanged()
    XCTAssertFalse(panel.isAnswering)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertEqual(transcript(panel), "")
    XCTAssertEqual(try questionField(panel).stringValue, "切换前的问题")
    gate.requests[0].partial("旧模型的迟到回答")
    gate.succeed(0, "旧模型结果")
    await Task.yield()
    XCTAssertEqual(transcript(panel), "")
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertTrue(gate.requests[1].history.isEmpty)
    gate.succeed(1, "新模型回答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.map(\.answer), ["新模型回答"])
  }

  func testZoomShortcutsPreserveDraftAndReflowWithoutResending() async throws {
    let suite = "VocabCapture.QuestionZoom.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(
      context: context, answer: gate.answer, interfaceDefaults: defaults)
    defer { panel.close() }
    panel.present()
    let field = try questionField(panel)
    field.stringValue = "缩放中的草稿"
    func shortcut(_ key: String, flags: NSEvent.ModifierFlags = .command) throws -> Bool {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
          characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
      return panel.performKeyEquivalent(with: event)
    }
    XCTAssertTrue(try shortcut("="))
    XCTAssertEqual(panel.zoomScale, 1.1, accuracy: 0.001)
    XCTAssertEqual(field.stringValue, "缩放中的草稿")
    XCTAssertTrue(gate.requests.isEmpty)
    XCTAssertTrue(try shortcut("-"))
    XCTAssertEqual(panel.zoomScale, 1, accuracy: 0.001)
    for _ in 0..<20 { panel.zoomIn(nil) }
    XCTAssertEqual(panel.zoomScale, 1.5)
    let restored = ScreenshotQuestionPanel(
      context: context, answer: gate.answer, interfaceDefaults: defaults)
    XCTAssertEqual(restored.zoomScale, 1.5)
    restored.close()
    for _ in 0..<20 { panel.zoomOut(nil) }
    XCTAssertEqual(panel.zoomScale, 0.75)
    XCTAssertTrue(try shortcut("0"))
    XCTAssertEqual(panel.zoomScale, 1)
    XCTAssertFalse(try shortcut("-", flags: []))
    XCTAssertFalse(try shortcut("=", flags: [.command, .option]))
    field.stringValue = "检验缩放换行"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    let answer = String(
      repeating: "Long answers should wrap inside the window. 长回答缩放后继续换行。", count: 30)
    gate.requests[0].partial(answer)
    panel.zoomIn(nil)
    let text = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    let container = try XCTUnwrap(text.textContainer)
    let layout = try XCTUnwrap(text.layoutManager)
    layout.ensureLayout(for: container)
    XCTAssertLessThanOrEqual(
      layout.usedRect(for: container).maxX + 2 * text.textContainerInset.width,
      try XCTUnwrap(text.enclosingScrollView).contentSize.width + 1)
    XCTAssertEqual(gate.requests.count, 1)
    gate.succeed(0, answer)
    try await wait { !panel.isAnswering }
  }

  func testCustomQuickPromptSendsFullQuestionAndWrapsFiveButtons() async throws {
    let suite = "VocabCapture.QuickPromptPanel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prompts = ScreenshotQuestionQuickPrompts(defaults: defaults)
    try prompts.save(
      (0..<5).map {
        ScreenshotQuestionQuickPrompt(
          id: "custom-\($0)", title: String(repeating: "长", count: 19) + "\($0)",
          prompt: "请完整分析原文第\($0)个问题并提供例子")
      })
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(
      context: context, answer: gate.answer, quickPrompts: prompts, interfaceDefaults: defaults)
    defer { panel.close() }
    panel.present()
    panel.setContentSize(NSSize(width: 600, height: 620))
    for _ in 0..<5 { panel.zoomIn(nil) }
    panel.contentView?.layoutSubtreeIfNeeded()
    try button(String(repeating: "长", count: 19) + "0", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertEqual(gate.requests[0].question, "请完整分析原文第0个问题并提供例子")
    for button in views(panel.contentView!).compactMap({ $0 as? NSButton })
    where button.identifier?.rawValue.hasPrefix("custom-") == true {
      let frame = button.convert(button.bounds, to: panel.contentView)
      XCTAssertGreaterThanOrEqual(frame.minX, 20)
      XCTAssertLessThanOrEqual(frame.maxX, 580)
      XCTAssertGreaterThanOrEqual(frame.minY, 20)
      XCTAssertLessThanOrEqual(frame.maxY, panel.contentView!.bounds.height - 20)
    }
    gate.succeed(0, "答案")
    try await wait { !panel.isAnswering }
  }

  func testPerformanceUsesVisibleTextAndProviderTokensAndIgnoresStaleCallbacks() async throws {
    let gate = AnswerGate()
    var clock: TimeInterval = 10
    var callbacks: [@MainActor @Sendable (ScreenshotQuestionUsage) -> Void] = []
    let panel = ScreenshotQuestionPanel(
      context: context, answer: gate.answer,
      measuredAnswer: { question, context, history, usage, partial in
        callbacks.append(usage)
        return try await gate.answer(question, context, history, partial)
      }, now: { clock })
    defer { panel.close() }
    try questionField(panel).stringValue = "测量请求"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    clock = 11
    gate.requests[0].partial("")
    gate.requests[0].partial(" \n\t")
    XCTAssertNil(panel.performance?.firstTextAt)
    clock = 12
    gate.requests[0].partial("可见回答")
    XCTAssertEqual(panel.performance?.firstTokenLatency, 2)
    callbacks[0](ScreenshotQuestionUsage(inputTokens: 20, outputTokens: 60))
    clock = 16
    gate.succeed(0, "完整回答")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.performance?.elapsed, 6)
    XCTAssertEqual(panel.performance?.averageTokensPerSecond, 10)
    XCTAssertEqual(panel.singlePassPreparationDurations["modelRequest"], 6)
    let label = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == "回答性能"
      })
    XCTAssertTrue(label.stringValue.contains("平均 TPS 10.0"))
    clock = 20
    try questionField(panel).stringValue = "第二问无用量"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    callbacks[0](ScreenshotQuestionUsage(outputTokens: 999))
    gate.requests[0].partial("迟到的旧回答")
    XCTAssertNil(panel.performance?.usage)
    XCTAssertNil(panel.performance?.firstTextAt)
    XCTAssertTrue(panel.singlePassPreparationDurations.isEmpty)
    clock = 22
    gate.requests[1].partial("只有文字")
    clock = 24
    gate.succeed(1, "回答")
    try await wait { !panel.isAnswering }
    XCTAssertNil(panel.performance?.averageTokensPerSecond)
    XCTAssertTrue(label.stringValue.contains("平均 TPS —"))
    try button("清空对话", panel).performClick(nil)
    callbacks[1](ScreenshotQuestionUsage(outputTokens: 111))
    XCTAssertNil(panel.performance)
  }

  func testNonStreamingCompletionRecordsActualVisibleOutputAndDetailsAvailability() async throws {
    let gate = AnswerGate()
    var clock: TimeInterval = 10
    let panel = ScreenshotQuestionPanel(context: context, answer: gate.answer, now: { clock })
    defer { panel.close() }
    panel.present()
    let details = try button("耗时明细…", panel)
    XCTAssertFalse(details.isEnabled)
    try questionField(panel).stringValue = "只在完成时返回回答"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    clock = 13
    gate.succeed(0, "完整回答")
    try await wait { !panel.isAnswering }
    XCTAssertTrue(details.isEnabled)
    XCTAssertEqual(panel.performance?.firstTokenLatency, 3)
    XCTAssertEqual(panel.singlePassPreparationDurations["modelRequest"], 3)
    details.performClick(nil)
    try await wait { panel.attachedSheet != nil }
    let sheet = try XCTUnwrap(panel.attachedSheet)
    let report = try XCTUnwrap(views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextView }
      .first { $0.accessibilityLabel() == "本次回答耗时明细" })
    XCTAssertFalse(report.isEditable)
    XCTAssertTrue(report.isSelectable)
    XCTAssertTrue(report.string.contains("3.000 秒"))
    XCTAssertNotNil(report.enclosingScrollView)
    let close = try XCTUnwrap(views(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "关闭" })
    close.performClick(nil)
    try await wait { panel.attachedSheet == nil }
    try button("清空对话", panel).performClick(nil)
    XCTAssertFalse(details.isEnabled)
  }

  func testRichAnswerWindowRendersMarkdownAndClearsConversation() async throws {
    let gate = AnswerGate()
    let panel = makePanel(gate)
    panel.present()
    defer { panel.close() }
    let markup = "## 解答\n\n**结论**：$2+3=5$\n\n| 项目 | 数量 |\n|---|---|\n| 苹果 | 5 |"
    try questionField(panel).stringValue = "请用 Markdown 回答"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.succeed(0, markup)
    try await wait { !panel.isAnswering }
    let rich = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? ScreenshotAnswerWebView }.first)
    var rendered = false
    for _ in 0..<100 {
      if let value = try? await rich.evaluateJavaScript("document.querySelectorAll('h2').length === 1 && document.querySelectorAll('table').length === 1 && document.querySelectorAll('.katex').length === 1"), value as? Bool == true {
        rendered = true; break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(rendered, "Must exercise the real window renderer, not only the plain-text fallback")
    XCTAssertFalse(rich.isHidden)
    XCTAssertTrue(transcript(panel).contains(markup), "Original answer remains available for fallback and copying")
    try button("清空对话", panel).performClick(nil)
    var cleared = false
    for _ in 0..<40 {
      if let count = try? await rich.evaluateJavaScript("document.querySelectorAll('.turn').length"), count as? Int == 0 {
        cleared = true; break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(cleared)
  }

  func testCopyGeneratedAnswersIncludesStreamingAndClearsWithConversation() async throws {
    let pasteboard = NSPasteboard.general
    let previous = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
      return copy
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(previous) }
    let gate = AnswerGate()
    let panel = makePanel(gate)
    panel.present()
    defer { panel.close() }
    let copy = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }
      .first { $0.accessibilityLabel() == "复制回答" })
    XCTAssertFalse(copy.isEnabled)
    try questionField(panel).stringValue = "不能复制提问或OCR"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertFalse(copy.isEnabled)
    gate.requests[0].partial("已生成的部分")
    try await wait { copy.isEnabled }
    copy.performClick(nil)
    XCTAssertEqual(pasteboard.string(forType: .string), "已生成的部分")
    XCTAssertEqual(copy.title, "已复制")
    gate.succeed(0, "第一份完整回答")
    try await wait { !panel.isAnswering }
    copy.performClick(nil)
    XCTAssertEqual(pasteboard.string(forType: .string), "第一份完整回答")
    try questionField(panel).stringValue = "第二问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    gate.succeed(1, "第二份回答")
    try await wait { !panel.isAnswering }
    copy.performClick(nil)
    XCTAssertEqual(pasteboard.string(forType: .string), "第一份完整回答\n\n──────────\n\n第二份回答")
    if let path = ProcessInfo.processInfo.environment["COPY_BUTTON_PREVIEW"] {
      let view = try XCTUnwrap(panel.contentView)
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    try button("清空对话", panel).performClick(nil)
    XCTAssertFalse(copy.isEnabled)
    XCTAssertEqual(copy.title, "")
  }

  func testSessionRestoreAndNewSessionSynchronizeRichAnswerAndCopyState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ScreenshotQuestionSessionStore(directory: directory)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12,
      pixelsHigh: 9, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let saved = try await store.create(title: "已保存的题")
    let attachment = try await store.appendAttachment(id: saved.id, imageData: image, ocrText: "原题")
    _ = try await store.appendTurn(id: saved.id, question: "原问题", answer: "## 已恢复答案",
      model: "test", attachmentIDs: attachment.attachments.map(\.id))
    let gate = AnswerGate()
    let panel = ScreenshotQuestionPanel(context: context, answer: gate.answer, sessionStore: store)
    panel.present()
    defer { panel.close() }
    let item = NSMenuItem()
    item.representedObject = saved.id
    panel.perform(NSSelectorFromString("restoreSession:"), with: item)
    try await wait { panel.history.count == 1 }
    XCTAssertEqual(panel.history.first?.answer, "## 已恢复答案")
    let copy = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }
      .first { $0.accessibilityLabel() == "复制回答" })
    XCTAssertTrue(copy.isEnabled)
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextField }
      .contains { $0.stringValue.contains("已恢复“已保存的题”") })
    panel.perform(NSSelectorFromString("newSession"))
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertTrue(transcript(panel).isEmpty)
    XCTAssertFalse(copy.isEnabled)
    let rich = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? ScreenshotAnswerWebView }.first)
    var empty = false
    for _ in 0..<100 {
      if let count = try? await rich.evaluateJavaScript("document.querySelectorAll('.turn').length"),
        count as? Int == 0 { empty = true; break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(empty)
    var newCaptureSaved = false
    for _ in 0..<100 {
      if try await store.list().count == 2 { newCaptureSaved = true; break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(newCaptureSaved, "New session must retain the current capture for subsequent answers")
    try questionField(panel).stringValue = "新会话问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    gate.succeed(0, "新会话回答")
    try await wait { !panel.isAnswering }
    let sessions = try await store.list()
    let newID = try XCTUnwrap(sessions.first { $0.id != saved.id }?.id)
    let newSaved = try await store.session(id: newID)
    XCTAssertEqual(newSaved.turns.map(\.answer), ["新会话回答"])
    XCTAssertEqual(newSaved.attachments.count, 1)
    let originalSaved = try await store.session(id: saved.id)
    XCTAssertEqual(originalSaved.turns.map(\.answer), ["## 已恢复答案"])
  }

  private func makePanel(_ gate: AnswerGate) -> ScreenshotQuestionPanel {
    _ = NSApplication.shared
    return ScreenshotQuestionPanel(context: context, answer: gate.answer)
  }

  private func questionField(_ panel: ScreenshotQuestionPanel) throws -> NSTextField {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "提问内容" })
  }

  private func button(_ title: String, _ panel: ScreenshotQuestionPanel) throws -> NSButton {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
  }

  private func transcript(_ panel: ScreenshotQuestionPanel) -> String {
    views(panel.contentView!).compactMap { $0 as? NSTextView }.first!.string
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("等待问答状态超时")
  }
}

@MainActor
private final class AnswerGate {
  struct Request {
    let question: String
    let context: ScreenshotQuestionContext
    let history: [ScreenshotQuestionTurn]
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
        Request(
          question: question, context: context, history: history, partial: partial,
          continuation: continuation))
    }
  }

  func succeed(_ index: Int, _ answer: String) {
    requests[index].continuation.resume(returning: answer)
  }
  func fail(_ index: Int) {
    requests[index].continuation.resume(throwing: NSError(domain: "Test", code: 1))
  }
}
