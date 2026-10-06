import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotQuestionQuickPromptSettingsTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var preferences: ScreenshotQuestionQuickPrompts!

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    suite = "VocabCapture.QuickPromptSettingsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    preferences = nil
    defaults = nil
    super.tearDown()
  }

  func testEditorUpdatesTitleAndMultilinePromptPreservingOtherEntries() throws {
    let original = preferences.prompts
    var saved = 0
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences) { saved += 1 }
    settings.present()
    try title(1, settings).stringValue = "查语法"
    try prompt(1, settings).string = "请分析语法。\n请给出修正例句。"
    try button("保存", settings).performClick(nil)
    XCTAssertEqual(saved, 1)
    XCTAssertEqual(preferences.prompts[0].id, original[0].id)
    XCTAssertEqual(preferences.prompts[0].title, "查语法")
    XCTAssertEqual(preferences.prompts[0].prompt, "请分析语法。\n请给出修正例句。")
    XCTAssertEqual(Array(preferences.prompts.dropFirst()), Array(original.dropFirst()))
    XCTAssertFalse(settings.panel.isVisible)
  }

  func testAddLimitAndDeleteRetainUnsavedEdits() throws {
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences)
    settings.present()
    try title(1, settings).stringValue = "保留草稿"
    let add = try button("新增快捷问题", settings)
    for index in 4...5 {
      add.performClick(nil)
      try title(index, settings).stringValue = "新增 \(index)"
      try prompt(index, settings).string = "完整的问题 \(index)"
    }
    XCTAssertFalse(add.isEnabled)
    add.performClick(nil)
    XCTAssertEqual(try title(1, settings).stringValue, "保留草稿")
    let remove = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "删除快捷问题 2"
      })
    remove.performClick(nil)
    XCTAssertTrue(add.isEnabled)
    XCTAssertEqual(try title(1, settings).stringValue, "保留草稿")
    XCTAssertEqual(try title(2, settings).stringValue, "总结要点")
    try button("保存", settings).performClick(nil)
    XCTAssertEqual(preferences.prompts.map(\.title), ["保留草稿", "总结要点", "新增 4", "新增 5"])
  }

  func testInvalidPromptKeepsEditorOpenAndNeverSaves() throws {
    var saves = 0
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences) { saves += 1 }
    settings.present()
    try prompt(1, settings).string = " "
    try button("保存", settings).performClick(nil)
    XCTAssertTrue(settings.panel.isVisible)
    XCTAssertEqual(preferences.prompts, ScreenshotQuestionQuickPrompts.defaultPrompts)
    XCTAssertEqual(saves, 0)
    XCTAssertEqual(
      try field("快捷问题设置状态", settings).stringValue, "请填写每个快捷问题的提问内容。")
    try button("取消", settings).performClick(nil)
  }

  func testCancelAndWindowCloseDiscardEdits() throws {
    var saves = 0
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences) { saves += 1 }
    for windowClose in [false, true] {
      settings.present()
      try title(1, settings).stringValue = "未保存"
      if windowClose {
        settings.panel.performClose(nil)
      } else {
        try button("取消", settings).performClick(nil)
      }
      XCTAssertFalse(settings.panel.isVisible)
      XCTAssertEqual(preferences.prompts, ScreenshotQuestionQuickPrompts.defaultPrompts)
    }
    XCTAssertEqual(saves, 0)
  }

  func testRemovingAllKeepsAddButtonAndPersistsEmptyList() throws {
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences)
    settings.present()
    for _ in 0..<3 { try button("删除", settings).performClick(nil) }
    XCTAssertTrue(try button("新增快捷问题", settings).isEnabled)
    try button("保存", settings).performClick(nil)
    XCTAssertTrue(preferences.prompts.isEmpty)
    settings.present()
    XCTAssertTrue(try button("新增快捷问题", settings).isEnabled)
    try button("取消", settings).performClick(nil)
  }

  func testMultilineEditorsRemainVisibleAndWrapWhenWindowResizes() throws {
    let settings = ScreenshotQuestionQuickPromptSettings(preferences: preferences)
    settings.present()
    for width in [620.0, 530.0, 700.0] {
      settings.panel.setContentSize(NSSize(width: width, height: 610))
      settings.panel.contentView?.layoutSubtreeIfNeeded()
      let editor = try prompt(1, settings)
      let scroll = try XCTUnwrap(editor.enclosingScrollView)
      XCTAssertGreaterThan(editor.frame.width, 100)
      XCTAssertGreaterThan(editor.frame.height, 20)
      XCTAssertLessThanOrEqual(editor.frame.width, scroll.contentSize.width + 1)
      XCTAssertEqual(editor.textContainer?.widthTracksTextView, true)
      XCTAssertEqual(editor.textContainer?.heightTracksTextView, false)
      XCTAssertFalse(editor.isHorizontallyResizable)
    }
    try button("取消", settings).performClick(nil)
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func button(_ title: String, _ settings: ScreenshotQuestionQuickPromptSettings) throws
    -> NSButton
  {
    try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
  }

  private func field(_ label: String, _ settings: ScreenshotQuestionQuickPromptSettings) throws
    -> NSTextField
  {
    try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == label
      })
  }

  private func title(_ index: Int, _ settings: ScreenshotQuestionQuickPromptSettings) throws
    -> NSTextField
  {
    try field("快捷问题 \(index) 标题", settings)
  }

  private func prompt(_ index: Int, _ settings: ScreenshotQuestionQuickPromptSettings) throws
    -> NSTextView
  {
    try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSTextView }.first {
        $0.accessibilityLabel() == "快捷问题 \(index) 内容"
      })
  }
}
