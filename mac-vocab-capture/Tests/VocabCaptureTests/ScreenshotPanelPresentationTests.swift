import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotPanelPresentationTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!
  private var panels: [ScreenshotPanel] = []

  override func setUp() {
    _ = NSApplication.shared
    suite = "VocabCapture.ScreenshotPresentationTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() {
    panels.forEach { $0.close() }
    panels.removeAll()
    defaults.removePersistentDomain(forName: suite)
  }

  func testBothScreenshotResultsAppearAboveNormalSourceWindowsInCurrentSpace() throws {
    for panel in makePanels() {
      present(panel)
      XCTAssertTrue(panel.isVisible)
      XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
      XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
      XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
      XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces),
        "A result should follow the current desktop rather than appear on every desktop")
      XCTAssertNotNil(panel.firstResponder)
      panel.orderOut(nil)
    }
  }

  func testResigningKeyReleasesTemporaryElevationWithoutDiscardingResult() throws {
    for panel in makePanels() {
      present(panel)
      // XCTest has no application event loop to complete asynchronous activation.
      // Deliver AppKit's focus-loss callback; actual focus is checked in the installed app.
      panel.resignKey()
      XCTAssertEqual(panel.level, .normal)
      XCTAssertTrue(panel.isVisible, "Leaving the result must not discard it")
      panel.orderOut(nil)
    }
  }

  func testHidingAndReopeningBothPanelsRestoresForegroundAndKeepsText() throws {
    for panel in makePanels() {
      present(panel)
      let text = try XCTUnwrap(views(try XCTUnwrap(panel.contentView))
        .compactMap { $0 as? NSTextView }.first)
      let original = text.string
      panel.orderOut(nil)
      XCTAssertEqual(panel.level, .normal)
      XCTAssertFalse(panel.isVisible)
      present(panel)
      XCTAssertTrue(panel.isVisible)
      XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
      XCTAssertEqual(text.string, original)
      panel.orderOut(nil)
    }
  }

  func testSwitchingApplicationsReleasesElevationEvenBeforeKeyActivationFinishes() {
    for panel in makePanels() {
      present(panel)
      NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
      XCTAssertEqual(panel.level, .normal)
      XCTAssertTrue(panel.isVisible)
      present(panel)
      XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
      panel.orderOut(nil)
    }
  }

  func testCancellingRetakeRestoresWordPanelInFrontWithSelectedText() throws {
    let word = makeWordPanel()
    word.present()
    let original = try XCTUnwrap(views(try XCTUnwrap(word.contentView))
      .compactMap { $0 as? NSTextView }.first)
    original.setSelectedRange(NSRange(location: 2, length: 7))
    let restore = word.hideForScreenshot()
    XCTAssertFalse(word.isVisible)
    restore()
    XCTAssertTrue(word.isVisible)
    XCTAssertGreaterThan(word.level.rawValue, NSWindow.Level.normal.rawValue)
    XCTAssertEqual(original.selectedRange(), NSRange(location: 2, length: 7))
  }

  private func makeWordPanel() -> OCRLookupPanel {
    let panel = OCRLookupPanel(text: "A curious reader.",
      lookup: { _, _ in throw CancellationError() }, save: { _, _ in "unused" })
    panels.append(panel)
    return panel
  }

  private func makePanels() -> [ScreenshotPanel] {
    let word = makeWordPanel()
    let question = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(text: "A public screenshot.", selectedWord: nil,
        imageData: nil), answer: { _, _, _, _ in throw CancellationError() },
      quickPrompts: ScreenshotQuestionQuickPrompts(defaults: defaults),
      interfaceDefaults: defaults)
    panels.append(question)
    return [word, question]
  }

  private func present(_ panel: ScreenshotPanel) {
    if let word = panel as? OCRLookupPanel { word.present() }
    if let question = panel as? ScreenshotQuestionPanel { question.present() }
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
}
