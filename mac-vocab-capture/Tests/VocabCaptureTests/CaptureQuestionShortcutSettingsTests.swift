import AppKit
import Carbon.HIToolbox
import XCTest

@testable import VocabCapture

@MainActor
final class CaptureQuestionShortcutSettingsTests: XCTestCase {
  private func descendants(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(in: $0) }
  }

  private func button(_ title: String, in settings: CaptureShortcutSettings) throws -> NSButton {
    try XCTUnwrap(
      descendants(in: settings.panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == title })
  }

  private func recorder(_ label: String, in settings: CaptureShortcutSettings) throws -> NSView {
    try XCTUnwrap(
      descendants(in: settings.panel.contentView!).first {
        $0.accessibilityLabel() == label && $0.accessibilityRole() == .textField
      })
  }

  private func record(_ keyCode: Int, flags: NSEvent.ModifierFlags, in view: NSView) throws {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(keyCode)))
    view.keyDown(with: event)
  }

  func testQuestionRecorderUpdatesAccessibleValueAndSavesIndependently() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(
      selection: .defaultSelection, screenshot: .defaultScreenshot)
    var saved: [CaptureShortcut] = []
    settings.present(validateAndSave: {
      saved = [$0, $1, $2]
      return nil
    })
    defer { settings.panel.close() }
    let question = try recorder("截图问一问", in: settings)
    XCTAssertEqual(question.accessibilityValue() as? String, "⌥⌘A")
    XCTAssertTrue(question.accessibilityPerformPress())
    XCTAssertTrue(settings.panel.firstResponder === question)
    try record(kVK_ANSI_Q, flags: [.option, .command], in: question)
    XCTAssertEqual(question.accessibilityValue() as? String, "⌥⌘Q")
    try button("保存", in: settings).performClick(nil)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertEqual(
      saved,
      [
        .defaultSelection, .defaultScreenshot,
        CaptureShortcut.recorded(keyCode: UInt32(kVK_ANSI_Q), flags: [.option, .command])!,
      ])
  }

  func testQuestionConflictBlocksCallbackUntilCorrected() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(
      selection: .defaultSelection, screenshot: .defaultScreenshot)
    var saves = 0
    settings.present(validateAndSave: { _, _, _ in
      saves += 1
      return nil
    })
    defer { settings.panel.close() }
    let question = try recorder("截图问一问", in: settings)
    try record(kVK_ANSI_O, flags: [.option, .command], in: question)
    try button("保存", in: settings).performClick(nil)
    XCTAssertTrue(settings.panel.isVisible)
    XCTAssertEqual(saves, 0)
    try record(kVK_ANSI_A, flags: [.option, .control], in: question)
    try button("保存", in: settings).performClick(nil)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertEqual(saves, 1)
  }

  func testRestoreDefaultsResetsAllThreeAndScreenshotPresetOnlyChangesScreenshot() throws {
    _ = NSApplication.shared
    let settings = CaptureShortcutSettings(
      selection: CaptureShortcut.selectionPresets[1], screenshot: .alternateScreenshot,
      questionScreenshot: CaptureShortcut.questionScreenshotFallbacks[2])
    var saved: [CaptureShortcut] = []
    settings.present(validateAndSave: {
      saved = [$0, $1, $2]
      return nil
    })
    defer { settings.panel.close() }
    try button("⌥D", in: settings).performClick(nil)
    XCTAssertEqual(try recorder("选中文字查词", in: settings).accessibilityValue() as? String, "⌃⌥D")
    XCTAssertEqual(try recorder("截图取词", in: settings).accessibilityValue() as? String, "⌥D")
    XCTAssertEqual(try recorder("截图问一问", in: settings).accessibilityValue() as? String, "⌃⌥A")
    try button("恢复默认", in: settings).performClick(nil)
    XCTAssertEqual(try recorder("截图问一问", in: settings).accessibilityValue() as? String, "⌥⌘A")
    try button("保存", in: settings).performClick(nil)
    XCTAssertEqual(saved, [.defaultSelection, .defaultScreenshot, .defaultQuestionScreenshot])
  }

  func testEscapeCancelsQuestionRecorderWithoutSavingAndClosesOnce() throws {
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
    defer { settings.panel.close() }
    let question = try recorder("截图问一问", in: settings)
    try record(kVK_ANSI_Q, flags: [.option, .command], in: question)
    try record(kVK_Escape, flags: [], in: question)
    _ = settings.windowShouldClose(settings.panel)
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertEqual(saves, 0)
    XCTAssertEqual(closes, 1)
  }

  func testReturnInQuestionRecorderSavesAllThree() throws {
    _ = NSApplication.shared
    let question = CaptureShortcut.questionScreenshotFallbacks[1]
    let settings = CaptureShortcutSettings(
      selection: .defaultSelection, screenshot: .simpleScreenshot, questionScreenshot: question)
    var saved: [CaptureShortcut] = []
    settings.present(validateAndSave: {
      saved = [$0, $1, $2]
      return nil
    })
    defer { settings.panel.close() }
    try record(kVK_Return, flags: [], in: recorder("截图问一问", in: settings))
    XCTAssertEqual(saved, [.defaultSelection, .simpleScreenshot, question])
    XCTAssertFalse(settings.panel.isVisible)
  }
}
