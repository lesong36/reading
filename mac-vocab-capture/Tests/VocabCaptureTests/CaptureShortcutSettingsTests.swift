import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class CaptureShortcutSettingsTests: XCTestCase {
  private func buttons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
  }

  func testColdOpenURLWaitsForApplicationInitialization() {
    let app = NSApplication.shared
    let delegate = makeIsolatedAppDelegate()
    let url = URL(string: "vocabcapture://capture?word=curious&context=A%20curious%20reader.")!
    delegate.application(app, open: [url])
    XCTAssertEqual(delegate.pendingOpenURLs, [url])
  }

  func testMenuHasAnExplicitTarget() throws {
    _ = NSApplication.shared
    let delegate = makeIsolatedAppDelegate()
    let menu = try XCTUnwrap(delegate.makeCaptureMethodMenu().submenu)
    let entry = try XCTUnwrap(menu.items.first { $0.title == "设置取词与截图快捷键…" })
    XCTAssertTrue(entry.target === delegate)
    XCTAssertEqual(entry.action, NSSelectorFromString("openShortcutSettings"))
    XCTAssertTrue(delegate.responds(to: try XCTUnwrap(entry.action)))
  }

  func testPresentReturnsWithWindowVisibleAndCancelRestoresOnce() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(
      selection: .defaultSelection, screenshot: .defaultScreenshot)
    var saves = 0
    var closes = 0
    settings.present(
      validateAndSave: { _, _, _ in
        saves += 1
        return nil
      }, onClose: { closes += 1 })
    XCTAssertTrue(settings.panel.isVisible)
    XCTAssertFalse(settings.panel.hidesOnDeactivate)
    settings.show()
    let cancel = try XCTUnwrap(buttons(in: settings.panel.contentView!).first { $0.title == "取消" })
    cancel.performClick(nil)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertEqual(saves, 0)
    XCTAssertEqual(closes, 1)
    _ = settings.windowShouldClose(settings.panel)
    XCTAssertEqual(closes, 1)
  }

  func testFailedRegistrationStaysVisibleAndRetrySavesThenCloses() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(
      selection: .defaultSelection, screenshot: .defaultScreenshot)
    var attempts = 0
    var closes = 0
    var screenshot: CaptureShortcut?
    settings.present(
      validateAndSave: { _, value, _ in
        attempts += 1
        screenshot = value
        return attempts == 1 ? "已被其他应用占用" : nil
      }, onClose: { closes += 1 })
    let all = buttons(in: settings.panel.contentView!)
    try XCTUnwrap(all.first { $0.title == "⌥D" }).performClick(nil)
    let save = try XCTUnwrap(all.first { $0.title == "保存" })
    save.performClick(nil)
    XCTAssertTrue(settings.panel.isVisible)
    XCTAssertEqual(closes, 0)
    XCTAssertEqual(screenshot, .simpleScreenshot)
    save.performClick(nil)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(closes, 1)
  }
}
