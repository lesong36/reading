import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class UnifiedSettingsTests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func click(_ title: String, in view: NSView) throws {
    try XCTUnwrap(views(view).compactMap { $0 as? NSButton }.first { $0.title == title }).performClick(nil)
  }

  func testNavigationReusesDraftWithoutSaving() {
    _ = NSApplication.shared
    var builds = 0
    let editor = NSTextField(string: "saved")
    let settings = SettingsWindow(makePage: { _ in builds += 1; return builds == 1 ? editor : NSView() })
    settings.select(.dictionary)
    editor.stringValue = "draft"
    settings.select(.question)
    settings.select(.dictionary)
    XCTAssertEqual(builds, 2)
    XCTAssertEqual(editor.stringValue, "draft")
    XCTAssertTrue(editor.window === settings.panel)
  }

  func testDictionarySaveFailureLeavesOriginalAndRestoreDoesNotSave() throws {
    _ = NSApplication.shared
    let original = AIConfiguration(baseURL: "https://example.com/v1", model: "original", apiKey: "")
    var saved = original
    var writes = 0
    let editor = DictionarySettingsView(configuration: original, save: { candidate in
      writes += 1
      if writes == 1 { throw NSError(domain: "test", code: 1) }
      saved = candidate
    }, test: { _ in "通过" })
    let model = try XCTUnwrap(views(editor.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "模型名称" })
    model.stringValue = "changed"
    try click("保存", in: editor.view)
    XCTAssertEqual(saved.model, "original")
    try click("还原更改", in: editor.view)
    XCTAssertEqual(model.stringValue, "original")
    XCTAssertEqual(writes, 1)
    model.stringValue = "changed"
    try click("保存", in: editor.view)
    XCTAssertEqual(saved.model, "changed")
    try click("还原更改", in: editor.view)
    XCTAssertEqual(model.stringValue, "changed")
  }

  func testDictionaryConnectionTestDoesNotSave() async throws {
    _ = NSApplication.shared
    var writes = 0
    var tests = 0
    let editor = DictionarySettingsView(configuration: AIConfiguration(baseURL: "https://example.com", model: "test", apiKey: ""), save: { _ in writes += 1 }, test: { _ in tests += 1; return "通过" })
    try click("测试连接", in: editor.view)
    for _ in 0..<100 where tests == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertEqual(tests, 1)
    XCTAssertEqual(writes, 0)
  }

  func testMenuOffersOneSettingsEntryAndNoMaintenanceSubmenus() throws {
    _ = NSApplication.shared
    let delegate = makeIsolatedAppDelegate()
    let menu = delegate.makeMenu()
    let settings = try XCTUnwrap(menu.items.first { $0.title == "设置…" })
    XCTAssertEqual(settings.keyEquivalent, ",")
    XCTAssertTrue(settings.target === delegate)
    XCTAssertTrue(delegate.responds(to: try XCTUnwrap(settings.action)))
    XCTAssertFalse(menu.items.contains { ["账号与本机词库", "快捷键与取词", "模型与服务"].contains($0.title) })
    XCTAssertTrue(menu.items.contains { $0.title == "最近收藏…" })
  }
  func testRecordingNotifiesFocusAndSettingsNotifiesActivationChanges() throws {
    _ = NSApplication.shared
    var recording: [Bool] = []
    var keyStates: [Bool] = []
    let editor = CaptureShortcutSettings(selection: .defaultSelection, screenshot: .defaultScreenshot)
    let form = editor.makeEmbeddedView(validateAndSave: { _, _, _ in nil }, onRecordingChange: { recording.append($0) })
    let window = SettingsWindow(makePage: { _ in form }, onKeyChange: { keyStates.append($0) })
    window.select(.capture)
    let recorder = try XCTUnwrap(views(form).first { $0.accessibilityLabel() == "截图取词" })
    XCTAssertTrue(window.panel.makeFirstResponder(recorder))
    XCTAssertTrue(editor.isRecording)
    XCTAssertEqual(recording.last, true)
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    XCTAssertEqual(keyStates.last, false)
    XCTAssertTrue(window.panel.makeFirstResponder(nil))
    XCTAssertFalse(editor.isRecording)
    XCTAssertEqual(recording.last, false)
  }

  func testAccountOnlyOffersRelevantActionsAndCollapsesMaintenance() throws {
    _ = NSApplication.shared
    var exports = 0
    let editor = AccountSettingsView(login: {}, logout: {}, sync: {}, conflicts: {}, bind: {}, export: { exports += 1 }, exportUnassigned: {}, restore: {})
    let buttons = views(editor.view).compactMap { $0 as? NSButton }
    let export = try XCTUnwrap(buttons.first { $0.title == "导出本机词库…" })
    let maintenance = try XCTUnwrap(buttons.first { $0.title == "词库维护" })
    let conflict = try XCTUnwrap(buttons.first { $0.title == "处理同步冲突…" })
    let bind = try XCTUnwrap(buttons.first { $0.title == "将未归属词条加入当前账号…" })
    XCTAssertTrue(export.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(conflict.isHidden)
    XCTAssertTrue(bind.isHidden)
    maintenance.performClick(nil)
    XCTAssertFalse(export.isHiddenOrHasHiddenAncestor)
    export.performClick(nil)
    XCTAssertEqual(exports, 1)
    editor.update(userID: "public-test", message: "等待同步", unassigned: 2, conflicts: 1, issue: nil)
    XCTAssertFalse(conflict.isHidden)
    XCTAssertFalse(bind.isHidden)
    editor.update(userID: nil, message: "未登录", unassigned: 2, conflicts: 0, issue: nil)
    XCTAssertTrue(bind.isHidden)
  }

  func testAccountPageUsesAvailableWidthWhenActionsAreHidden() throws {
    _ = NSApplication.shared
    let editor = AccountSettingsView(login: {}, logout: {}, sync: {}, conflicts: {}, bind: {}, export: {}, exportUnassigned: {}, restore: {})
    let window = SettingsWindow(makePage: { _ in editor.view })
    window.show(section: .account)
    defer { window.panel.close() }
    let root = try XCTUnwrap(window.panel.contentView)
    root.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(editor.view.frame.width, 590)
    let title = try XCTUnwrap(views(editor.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "账号与同步" })
    XCTAssertGreaterThan(title.frame.width, 590)
  }

}
