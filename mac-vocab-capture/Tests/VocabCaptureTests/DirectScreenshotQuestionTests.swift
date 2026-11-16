import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class DirectScreenshotQuestionTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!
  private var appDelegate: AppDelegate!

  override func setUp() {
    _ = NSApplication.shared
    suite = "VocabCapture.DirectQuestionTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    appDelegate = makeIsolatedAppDelegate(defaults: defaults)
  }

  override func tearDown() {
    appDelegate.directQuestionPanel?.close()
    appDelegate.ocrPanel?.close()
    defaults.removePersistentDomain(forName: suite)
    appDelegate = nil
  }

  private func image() throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func draft(_ panel: NSPanel) throws -> NSTextField {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable })
  }

  func testMenuShowsDedicatedConfigurableShortcutAndExplicitAction() throws {
    let preferences = ShortcutPreferences(defaults: defaults)
    let custom = try XCTUnwrap(CaptureShortcut.recorded(keyCode: 12, flags: [.control, .option]))
    preferences.save(
      screenshot: .defaultScreenshot, questionScreenshot: custom)
    let item = appDelegate.makeScreenshotQuestionItem()
    XCTAssertEqual(item.title, "截图问一问    \(custom.title)")
    XCTAssertTrue(item.target === appDelegate)
    XCTAssertEqual(item.action, NSSelectorFromString("captureScreenQuestionAction"))
    XCTAssertTrue(appDelegate.responds(to: try XCTUnwrap(item.action)))
  }

  func testQuestionDestinationSkipsWordPickerAndDoesNotAskAutomatically() throws {
    appDelegate.showScreenshot(
      text: "A public screenshot for a question.", image: try image(), destination: .question)
    let panel = try XCTUnwrap(appDelegate.directQuestionPanel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertNil(appDelegate.ocrPanel)
    XCTAssertFalse(panel.isAnswering)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue == "A public screenshot for a question."
      })
    XCTAssertTrue(panel.firstResponder is NSTextView)
  }

  func testNoTextScreenshotEnablesImageReference() throws {
    appDelegate.showScreenshot(text: "", image: try image(), destination: .question)
    let panel = try XCTUnwrap(appDelegate.directQuestionPanel)
    let imageToggle = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first {
        $0.title == "参考原截图"
      })
    XCTAssertFalse(imageToggle.isHidden)
    XCTAssertEqual(imageToggle.state, .on)
    XCTAssertFalse(panel.isAnswering)
  }

  func testCancelRestoresOnlyVisibleWindowAndPreservesDraft() throws {
    appDelegate.showScreenshot(text: "Original context", image: try image(), destination: .question)
    let panel = try XCTUnwrap(appDelegate.directQuestionPanel)
    try draft(panel).stringValue = "还未提交的问题"
    let restore = appDelegate.hideScreenshotPanels()
    XCTAssertFalse(panel.isVisible)
    restore()
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(try draft(panel).stringValue, "还未提交的问题")
    XCTAssertNil(appDelegate.ocrPanel)
    panel.orderOut(nil)
    appDelegate.hideScreenshotPanels()()
    XCTAssertFalse(panel.isVisible)
  }

  func testConsecutiveWordCapturesHideOldBlueBoxesAndKeepNewOverlay() throws {
    let region = ScreenCaptureRegion(screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
      selectionRect: CGRect(x: 100, y: 100, width: 200, height: 100))
    let token = OCROverlayToken(text: "word", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), confidence: 1)
    appDelegate.showScreenshot(text: "word", image: try image(), destination: .word, observations: [token], region: region)
    let first = try XCTUnwrap(appDelegate.screenOCROverlay)
    let firstLookup = try XCTUnwrap(appDelegate.ocrPanel)
    let restore = appDelegate.hideScreenshotPanels()
    XCTAssertFalse(first.isVisible, "Old blue boxes must not contaminate the next screenshot")
    XCTAssertNotNil(appDelegate.ocrPanel)
    restore()
    XCTAssertTrue(first.isVisible, "Cancelling a retake restores word selection")
    _ = appDelegate.hideScreenshotPanels()
    appDelegate.showScreenshot(text: "word", image: try image(), destination: .word, observations: [token], region: region)
    let second = try XCTUnwrap(appDelegate.screenOCROverlay)
    XCTAssertFalse(first === second)
    XCTAssertFalse(first.isVisible)
    XCTAssertFalse(firstLookup.isVisible)
    XCTAssertTrue(second.isVisible)
    second.close()
  }

  func testNewCaptureReplacesContextAndBothDirectionsCloseOldWindow() throws {
    appDelegate.showScreenshot(text: "First question", image: try image(), destination: .question)
    let first = try XCTUnwrap(appDelegate.directQuestionPanel)
    appDelegate.showScreenshot(text: "Second question", image: try image(), destination: .question)
    XCTAssertFalse(first.isVisible)
    XCTAssertFalse(appDelegate.directQuestionPanel === first)
    let second = try XCTUnwrap(appDelegate.directQuestionPanel)
    appDelegate.showScreenshot(text: "Word capture", image: try image(), destination: .word)
    XCTAssertFalse(second.isVisible)
    XCTAssertNil(appDelegate.directQuestionPanel)
    let wordPanel = try XCTUnwrap(appDelegate.ocrPanel)
    XCTAssertTrue(wordPanel.isVisible)
    appDelegate.showScreenshot(
      text: "Back to questions", image: try image(), destination: .question)
    XCTAssertFalse(wordPanel.isVisible)
    XCTAssertNil(appDelegate.ocrPanel)
    XCTAssertTrue(appDelegate.directQuestionPanel?.isVisible == true)
  }
}
