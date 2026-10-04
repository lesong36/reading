import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class DefinitionPreviewPanelTests: XCTestCase {
  func testEarlyMeaningIsVisibleButCannotConfirmUntilValidatedResult() async throws {
    _ = NSApplication.shared
    let panel = makePanel()
    let buttons = views(panel.contentView!).compactMap { $0 as? NSButton }
    let add = try XCTUnwrap(buttons.first { $0.title == "加入生词本" })
    XCTAssertFalse(add.isEnabled)
    panel.showMeaning("好奇的")
    XCTAssertTrue(
      views(panel.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains("好奇的"))
    add.performClick(nil)
    XCTAssertFalse(panel.isFinished)
    panel.showResult(result)
    XCTAssertTrue(add.isEnabled)
    var decisions: [Bool] = []
    panel.onDecision = { decisions.append($0) }
    let confirmation = Task { await panel.waitForConfirmation() }
    await Task.yield()
    add.performClick(nil)
    let accepted = await confirmation.value
    XCTAssertTrue(accepted)
    panel.dismiss()
    add.performClick(nil)
    XCTAssertEqual(decisions, [true])
  }

  func testWindowCancellationResumesExactlyOnceAndIgnoresLateUpdates() async {
    _ = NSApplication.shared
    let panel = makePanel()
    var decisions: [Bool] = []
    panel.onDecision = { decisions.append($0) }
    let confirmation = Task { await panel.waitForConfirmation() }
    await Task.yield()
    XCTAssertFalse(panel.windowShouldClose(panel))
    panel.dismiss()
    let accepted = await confirmation.value
    XCTAssertFalse(accepted)
    panel.showMeaning("过期释义")
    panel.showResult(result)
    XCTAssertFalse(
      views(panel.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }.contains("过期释义"))
    XCTAssertEqual(decisions, [false])
  }

  func testTaskCancellationClosesPromptlyAndCompletesConfirmation() async {
    _ = NSApplication.shared
    let panel = makePanel()
    panel.present()
    let confirmation = Task { await panel.waitForConfirmation() }
    await Task.yield()
    confirmation.cancel()
    let accepted = await confirmation.value
    XCTAssertFalse(accepted)
    XCTAssertFalse(panel.isVisible)
    XCTAssertTrue(panel.isFinished)
  }

  func testEscapeCancelsEvenWhileWaitingForResult() async {
    _ = NSApplication.shared
    let panel = makePanel()
    var cancelled = false
    panel.onDecision = { cancelled = !$0 }
    panel.present()
    panel.cancelOperation(nil)
    XCTAssertTrue(cancelled)
    XCTAssertFalse(panel.isVisible)
    let accepted = await panel.waitForConfirmation()
    XCTAssertFalse(accepted)
  }

  func testCancellationBeforeWaitingAndConfirmationBeforeWaitingArePreserved() async throws {
    _ = NSApplication.shared
    let cancelled = makePanel()
    cancelled.dismiss()
    let cancelledResult = await cancelled.waitForConfirmation()
    XCTAssertFalse(cancelledResult)
    let confirmed = makePanel()
    confirmed.showResult(result)
    let add = try XCTUnwrap(
      views(confirmed.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "加入生词本" })
    add.performClick(nil)
    let accepted = await confirmed.waitForConfirmation()
    XCTAssertTrue(accepted)
  }

  func testSourceSentenceHasVisibleDocumentSize() throws {
    _ = NSApplication.shared
    let panel = makePanel()
    panel.contentView!.layoutSubtreeIfNeeded()
    let source = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
    XCTAssertEqual(source.string, "A curious reader explores.")
    XCTAssertGreaterThan(source.frame.width, 0)
    XCTAssertGreaterThan(source.frame.height, 0)
    panel.dismiss()
  }

  private var result: DictionaryResult {
    DictionaryResult(
      lemma: "curious", meaning: "好奇的", partOfSpeech: "adj.", pronunciation: "", note: "")
  }

  private func makePanel() -> DefinitionPreviewPanel {
    DefinitionPreviewPanel(
      selection: SelectedText(word: "curious", context: "A curious reader explores."))
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
}
