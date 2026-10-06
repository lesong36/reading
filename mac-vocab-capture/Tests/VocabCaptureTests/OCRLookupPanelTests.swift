import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class OCRLookupPanelTests: XCTestCase {
  func testReturnFromOriginalTextSavesWithoutClosingWindow() async throws {
    _ = NSApplication.shared
    var saved = false
    let panel = OCRLookupPanel(
      text: "A curious reader.", lookup: { selection, _ in self.dictionary(selection.word) },
      save: { _, _ in
        saved = true
        return "已保存"
      })
    let text = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    text.setSelectedRange(NSRange(location: 2, length: 7))
    try await Task.sleep(nanoseconds: 250_000_000)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    text.keyDown(with: event)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(saved)
    XCTAssertTrue(text.isSelectable)
    panel.close()
  }

  func testPendingReturnDoesNotRestartLookupAndStartsWithoutDebounce() async throws {
    _ = NSApplication.shared
    var requests = 0
    var finish: CheckedContinuation<DictionaryResult, Never>?
    let panel = OCRLookupPanel(
      text: "A curious reader.",
      lookup: { selection, _ in
        requests += 1
        return await withCheckedContinuation { finish = $0 }
      }, save: { _, _ in "已保存" })
    let text = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    text.setSelectedRange(NSRange(location: 2, length: 7))
    try await Task.sleep(nanoseconds: 70_000_000)
    XCTAssertEqual(requests, 1)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    text.keyDown(with: event)
    text.keyDown(with: event)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(requests, 1)
    finish?.resume(returning: dictionary("curious"))
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title.hasPrefix("加入生词本") }?.isEnabled == true)
    panel.close()
  }

  func testEarlyMeaningCannotBeSavedAndOldPreviewCannotReplaceNewSelection() async throws {
    _ = NSApplication.shared
    var callbacks: [String: @MainActor @Sendable (String) -> Void] = [:]
    var completions: [String: CheckedContinuation<DictionaryResult, Never>] = [:]
    let panel = OCRLookupPanel(
      text: "First second.",
      lookup: { selection, preview in
        callbacks[selection.word] = preview
        return await withCheckedContinuation { completions[selection.word] = $0 }
      }, save: { _, _ in "已保存" })
    let all = views(panel.contentView!)
    let text = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    let save = try XCTUnwrap(
      all.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("加入生词本") })
    text.setSelectedRange(NSRange(location: 0, length: 5))
    try await Task.sleep(nanoseconds: 30_000_000)
    callbacks["First"]?("早期释义")
    XCTAssertTrue(all.compactMap { ($0 as? NSTextField)?.stringValue }.contains("早期释义"))
    XCTAssertFalse(save.isEnabled)
    text.setSelectedRange(NSRange(location: 6, length: 6))
    try await Task.sleep(nanoseconds: 30_000_000)
    callbacks["First"]?("过期释义")
    callbacks["second"]?("最新释义")
    XCTAssertFalse(all.compactMap { ($0 as? NSTextField)?.stringValue }.contains("过期释义"))
    XCTAssertTrue(all.compactMap { ($0 as? NSTextField)?.stringValue }.contains("最新释义"))
    XCTAssertFalse(save.isEnabled)
    completions["First"]?.resume(returning: dictionary("First"))
    completions["second"]?.resume(returning: dictionary("second"))
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(save.isEnabled)
    panel.close()
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func dictionary(_ word: String) -> DictionaryResult {
    DictionaryResult(
      lemma: word, meaning: "释义：\(word)", partOfSpeech: "n.", pronunciation: "", note: "")
  }

  func testSelectionAutomaticallyLooksUpAndOldResponseCannotReplaceNewWord() async throws {
    _ = NSApplication.shared
    let panel = OCRLookupPanel(
      text: "First second.",
      lookup: { selection, _ in
        await withCheckedContinuation { continuation in
          DispatchQueue.main.asyncAfter(deadline: .now() + (selection.word == "First" ? 0.5 : 0.01))
          {
            continuation.resume(returning: self.dictionary(selection.word))
          }
        }
      }, save: { _, _ in "已保存" })
    let all = views(panel.contentView!)
    let text = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    text.setSelectedRange(NSRange(location: 0, length: 5))
    try await Task.sleep(nanoseconds: 230_000_000)
    text.setSelectedRange(NSRange(location: 6, length: 6))
    try await Task.sleep(nanoseconds: 700_000_000)
    let labels = all.compactMap { ($0 as? NSTextField)?.stringValue }
    XCTAssertTrue(labels.contains("释义：second"))
    XCTAssertFalse(labels.contains("释义：First"))
    panel.close()
  }

  func testCorrectionInvalidatesDefinitionAndSavingKeepsSelectionAvailable() async throws {
    _ = NSApplication.shared
    var savedWords: [String] = []
    let panel = OCRLookupPanel(
      text: "First second.", lookup: { selection, _ in self.dictionary(selection.word) },
      save: { selection, _ in
        savedWords.append(selection.word)
        return "已保存"
      })
    let all = views(panel.contentView!)
    let text = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    let save = try XCTUnwrap(
      all.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("加入生词本") })
    let target = try XCTUnwrap(
      all.compactMap { $0 as? NSTextField }.first { $0.placeholderString != nil })
    text.setSelectedRange(NSRange(location: 0, length: 5))
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertTrue(save.isEnabled)
    target.stringValue = "Corrected"
    panel.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: target))
    XCTAssertFalse(save.isEnabled)
    let retry = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "重新查询" })
    retry.performClick(nil)
    try await Task.sleep(nanoseconds: 250_000_000)
    save.performClick(nil)
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(savedWords, ["Corrected"])
    XCTAssertTrue(text.isSelectable)
    XCTAssertFalse(save.isEnabled)
    text.setSelectedRange(NSRange(location: 6, length: 6))
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertTrue(save.isEnabled)
    save.performClick(nil)
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(savedWords, ["Corrected", "second"])
    panel.close()
  }

  func testEditingOriginalInvalidatesOldDefinition() async throws {
    _ = NSApplication.shared
    let panel = OCRLookupPanel(
      text: "First second.", lookup: { selection, _ in self.dictionary(selection.word) },
      save: { _, _ in "已保存" })
    let all = views(panel.contentView!)
    let text = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    let save = try XCTUnwrap(
      all.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("加入生词本") })
    let edit = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "修正原文" })
    text.setSelectedRange(NSRange(location: 0, length: 5))
    try await Task.sleep(nanoseconds: 250_000_000)
    edit.performClick(nil)
    XCTAssertTrue(text.isEditable)
    XCTAssertFalse(save.isEnabled)
    text.string = "A corrected sentence."
    edit.performClick(nil)
    XCTAssertFalse(text.isEditable)
    XCTAssertFalse(save.isEnabled)
    text.setSelectedRange(NSRange(location: 2, length: 9))
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertTrue(save.isEnabled)
    panel.close()
  }

  func testQuestionsReceiveWholeScreenshotWithoutSavingVocabulary() async throws {
    _ = NSApplication.shared
    var saves = 0
    var received: [ScreenshotQuestionContext] = []
    let panel = OCRLookupPanel(
      text: "First second. Another sentence.",
      lookup: { selection, _ in self.dictionary(selection.word) },
      save: { _, _ in
        saves += 1
        return "已保存"
      },
      imageData: Data([1, 2, 3]),
      ask: { _, context, _, partial in
        received.append(context)
        partial("这是回答")
        return "这是回答"
      })
    defer { panel.close() }
    let open = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "问一问…" })
    open.performClick(nil)
    let questions = try XCTUnwrap(
      NSApp.windows.compactMap { $0 as? ScreenshotQuestionPanel }.first { $0.isVisible })
    let fields = views(questions.contentView!)
    let input = try XCTUnwrap(
      fields.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "提问内容" })
    let submit = try XCTUnwrap(fields.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    input.stringValue = "总结整段话"
    submit.performClick(nil)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(received.first?.text, "First second. Another sentence.")
    XCTAssertNil(received.first?.selectedWord)
    XCTAssertNil(received.first?.imageData, "Original image should be opt-in for text screenshots")
    XCTAssertEqual(saves, 0)
    let original = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    original.setSelectedRange(NSRange(location: 0, length: 5))
    input.stringValue = "这里是什么意思？"
    submit.performClick(nil)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(received.last?.selectedWord, "First")
    XCTAssertEqual(saves, 0)
    panel.close()
    XCTAssertFalse(questions.isVisible)
  }
}
