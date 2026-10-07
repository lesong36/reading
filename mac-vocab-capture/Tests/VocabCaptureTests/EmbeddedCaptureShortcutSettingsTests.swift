import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class EmbeddedCaptureShortcutSettingsTests: XCTestCase {
  private func descendants(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(in: $0) }
  }

  private func button(_ title: String, in view: NSView) throws -> NSButton {
    try XCTUnwrap(descendants(in: view).compactMap { $0 as? NSButton }.first { $0.title == title })
  }

  func testEmbeddedSaveFailureCanRetryWithoutClosingHost() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(selection: .defaultSelection, screenshot: .defaultScreenshot)
    var attempts = 0
    var screenshots: [CaptureShortcut] = []
    let form = settings.makeEmbeddedView { _, screenshot, _ in
      attempts += 1
      screenshots.append(screenshot)
      return attempts == 1 ? "已被其他应用占用" : nil
    }
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    host.contentView = form
    host.orderFront(nil)
    defer { host.orderOut(nil) }
    try button("⌥D", in: form).performClick(nil)
    try button("保存", in: form).performClick(nil)
    XCTAssertTrue(host.isVisible)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertTrue(descendants(in: form).compactMap { $0 as? NSTextField }
      .contains { $0.stringValue == "已被其他应用占用" })
    try button("保存", in: form).performClick(nil)
    XCTAssertTrue(host.isVisible)
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(screenshots, [.simpleScreenshot, .simpleScreenshot])
  }

  func testEmbeddedRestoreChangesUsesLastSuccessfulSaveAndDoesNotPersistDraft() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(selection: .defaultSelection, screenshot: .defaultScreenshot)
    var screenshots: [CaptureShortcut] = []
    let form = settings.makeEmbeddedView { _, screenshot, _ in
      screenshots.append(screenshot)
      return nil
    }
    try button("⌥D", in: form).performClick(nil)
    try button("保存", in: form).performClick(nil)
    try button("恢复默认", in: form).performClick(nil)
    XCTAssertEqual(screenshots, [.simpleScreenshot])
    try button("还原更改", in: form).performClick(nil)
    XCTAssertEqual(screenshots, [.simpleScreenshot])
    let recorder = try XCTUnwrap(descendants(in: form).first {
      $0.accessibilityLabel() == "截图取词"
    })
    XCTAssertEqual(recorder.accessibilityValue() as? String, CaptureShortcut.simpleScreenshot.title)
    try button("保存", in: form).performClick(nil)
    XCTAssertEqual(screenshots, [.simpleScreenshot, .simpleScreenshot])
  }

  func testEmbeddedRestoreBeforeSaveReturnsInitialCustomShortcut() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(selection: .defaultSelection, screenshot: .alternateScreenshot)
    var saves = 0
    let form = settings.makeEmbeddedView { _, _, _ in saves += 1; return nil }
    try button("恢复默认", in: form).performClick(nil)
    try button("还原更改", in: form).performClick(nil)
    XCTAssertEqual(saves, 0)
    let recorder = try XCTUnwrap(descendants(in: form).first { $0.accessibilityLabel() == "截图取词" })
    XCTAssertEqual(recorder.accessibilityValue() as? String, CaptureShortcut.alternateScreenshot.title)
    XCTAssertFalse(settings.panel.contentView === form)
  }
}
