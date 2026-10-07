import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class EmbeddedModelServiceSettingsTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var keys: [String: String] = [:]
  private var preferences: ScreenshotQuestionPreferences!

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    suite = "EmbeddedModelSettingsTests.\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
    keys = [:]
    preferences = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { [unowned self] in self.keys[$0] ?? "" },
      saveProfileAPIKey: { [unowned self] in self.keys[$0] = $1 })
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    preferences = nil
    defaults = nil
    super.tearDown()
  }

  func testEmbeddedProfileSaveRetainsSelectionAndCallbackForFurtherEdits() throws {
    let settings = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertFalse(settings.panel.contentView === view)
    XCTAssertTrue(settings.makeEmbeddedView { changes += 1 } === view)
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
      styleMask: [.titled], backing: .buffered, defer: false)
    host.contentView = view
    try button("新增配置", view).performClick(nil)
    let nameField = try field("配置名称", view)
    XCTAssertTrue(host.firstResponder === nameField.currentEditor())
    try field("配置名称", view).stringValue = "日常问答"
    try field("服务地址（Base URL）", view).stringValue = "https://question.test/v1"
    try field("模型名称（Model）", view).stringValue = "first-model"
    try field("API Key", view).stringValue = "fixture-only"
    try button("保存并使用", view).performClick(nil)
    let id = try XCTUnwrap(preferences.selectedProfileID)
    XCTAssertEqual(preferences.profiles.count, 1)
    XCTAssertEqual(changes, 1)
    XCTAssertTrue(try field("设置状态", view).stringValue.contains("已保存"))
    XCTAssertTrue(host.contentView === view)
    try field("模型名称（Model）", view).stringValue = "updated-model"
    try button("保存并使用", view).performClick(nil)
    XCTAssertEqual(preferences.profiles.count, 1)
    XCTAssertEqual(preferences.selectedProfileID, id)
    XCTAssertEqual(preferences.configuration(for: id).model, "updated-model")
    XCTAssertEqual(changes, 2)
    host.makeFirstResponder(nil)
  }

  func testEmbeddedProfileRevertDiscardsNewAndEditedFields() throws {
    let id = try preferences.saveProfile(name: "已保存", configuration: configuration)
    preferences.selectProfile(id)
    let settings = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    try field("模型名称（Model）", view).stringValue = "unsaved"
    try field("API Key", view).stringValue = "unsaved-fixture"
    try button("还原更改", view).performClick(nil)
    XCTAssertEqual(try field("模型名称（Model）", view).stringValue, configuration.model)
    XCTAssertEqual(try field("API Key", view).stringValue, configuration.apiKey)
    try button("新增配置", view).performClick(nil)
    try button("还原更改", view).performClick(nil)
    XCTAssertEqual(try field("配置名称", view).stringValue, "已保存")
    XCTAssertEqual(preferences.profiles.count, 1)
    XCTAssertEqual(changes, 0)
    XCTAssertEqual(try button("删除配置", view).keyEquivalent, "")
  }

  func testEmbeddedDeleteRequiresConfirmationAndKeepsOtherSelectedProfile() throws {
    let first = try preferences.saveProfile(name: "第一个", configuration: configuration)
    let second = try preferences.saveProfile(name: "第二个", configuration: configuration)
    preferences.selectProfile(second)
    let settings = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    let picker = try XCTUnwrap(views(view).compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "已保存的模型配置"
    })
    picker.select(picker.itemArray.first { $0.representedObject as? String == first })
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    try button("删除配置", view).performClick(nil)
    XCTAssertEqual(preferences.profiles.count, 2)
    XCTAssertEqual(changes, 0)
    try button("确认删除", view).performClick(nil)
    XCTAssertEqual(preferences.profiles.map(\.id), [second])
    XCTAssertEqual(preferences.selectedProfileID, second)
    XCTAssertEqual(try field("配置名称", view).stringValue, "第二个")
    XCTAssertEqual(changes, 1)
  }

  func testEmbeddedValidationDoesNotPersistOrDismissForm() throws {
    let settings = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    try button("新增配置", view).performClick(nil)
    try field("服务地址（Base URL）", view).stringValue = "file:///tmp/model"
    try button("保存并使用", view).performClick(nil)
    XCTAssertTrue(preferences.profiles.isEmpty)
    XCTAssertEqual(changes, 0)
    XCTAssertEqual(try field("设置状态", view).textColor, .systemRed)
    XCTAssertTrue(try field("设置状态", view).stringValue.contains("有效"))
    try button("还原更改", view).performClick(nil)
    XCTAssertFalse(try field("模型名称（Model）", view).isEnabled)
  }

  func testEmbeddedFallbackPreferenceSaveAndRevertRemainOnPage() throws {
    let settings = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    try button("此模型直连（跳过系统 HTTP 代理）", view).performClick(nil)
    try button("保存并使用", view).performClick(nil)
    XCTAssertTrue(preferences.fallbackDirectConnection)
    XCTAssertNil(preferences.selectedProfileID)
    XCTAssertEqual(changes, 1)
    try button("此模型直连（跳过系统 HTTP 代理）", view).performClick(nil)
    try button("还原更改", view).performClick(nil)
    XCTAssertEqual(try button("此模型直连（跳过系统 HTTP 代理）", view).state, .on)
    XCTAssertEqual(changes, 1)
  }

  func testEmbeddedSearchSaveRevertAndClearPreserveCallbackAndIsolatedStorage() throws {
    var key = "fixture-original"
    var writes = 0
    let search = ScreenshotQuestionWebSearchPreferences(defaults: defaults,
      readAPIKey: { key }, saveAPIKey: { key = $0; writes += 1 })
    let settings = ScreenshotQuestionWebSearchSettings(preferences: search)
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    XCTAssertFalse(settings.panel.isVisible)
    XCTAssertFalse(settings.panel.contentView === view)
    try field("Tavily API Key", view).stringValue = "  fixture-new  "
    try button("搜索服务直连（跳过系统 HTTP 代理）", view).performClick(nil)
    try button("保存", view).performClick(nil)
    XCTAssertEqual(key, "fixture-new")
    XCTAssertTrue(search.directConnection)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(writes, 1)
    XCTAssertTrue(try field("检索设置状态", view).stringValue.contains("已保存"))
    try field("Tavily API Key", view).stringValue = "discard-me"
    try button("搜索服务直连（跳过系统 HTTP 代理）", view).performClick(nil)
    try button("还原更改", view).performClick(nil)
    XCTAssertEqual(try field("Tavily API Key", view).stringValue, "fixture-new")
    XCTAssertEqual(try button("搜索服务直连（跳过系统 HTTP 代理）", view).state, .on)
    XCTAssertEqual(writes, 1)
    try field("Tavily API Key", view).stringValue = ""
    try button("保存", view).performClick(nil)
    XCTAssertEqual(key, "")
    XCTAssertEqual(writes, 2)
    XCTAssertEqual(changes, 2)
    XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1)
  }

  func testEmbeddedSearchCredentialFailureDoesNotPersistConnection() throws {
    let search = ScreenshotQuestionWebSearchPreferences(defaults: defaults,
      readAPIKey: { "fixture-key" }, saveAPIKey: { _ in throw NSError(domain: "Fixture", code: 1) })
    let settings = ScreenshotQuestionWebSearchSettings(preferences: search)
    var changes = 0
    let view = settings.makeEmbeddedView { changes += 1 }
    try button("搜索服务直连（跳过系统 HTTP 代理）", view).performClick(nil)
    try button("保存", view).performClick(nil)
    XCTAssertFalse(search.directConnection)
    XCTAssertEqual(changes, 0)
    XCTAssertTrue(try field("检索设置状态", view).stringValue.contains("无法保存"))
    XCTAssertEqual(try field("检索设置状态", view).textColor, .systemRed)
  }

  func testEmbeddedFormsFitNarrowSettingsPageWithNaturalHeight() throws {
    let model = ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local")
    let searchPreferences = ScreenshotQuestionWebSearchPreferences(defaults: defaults,
      readAPIKey: { "" }, saveAPIKey: { _ in })
    let search = ScreenshotQuestionWebSearchSettings(preferences: searchPreferences)
    for view in [model.makeEmbeddedView(), search.makeEmbeddedView()] {
      view.translatesAutoresizingMaskIntoConstraints = false
      let width = view.widthAnchor.constraint(equalToConstant: 479)
      width.isActive = true
      view.layoutSubtreeIfNeeded()
      let height = view.fittingSize.height
      XCTAssertGreaterThan(height, 200)
      XCTAssertLessThan(height, 900)
      view.setFrameSize(NSSize(width: 479, height: height))
      view.layoutSubtreeIfNeeded()
      for control in views(view).filter({ $0 is NSTextField || $0 is NSPopUpButton }) {
        // Native text labels draw 2 pt beyond their layout alignment rect.
        let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: view)
        XCTAssertGreaterThanOrEqual(frame.minX, -1)
        XCTAssertLessThanOrEqual(frame.maxX, 480)
        XCTAssertGreaterThanOrEqual(frame.minY, -1)
        XCTAssertLessThanOrEqual(frame.maxY, height + 1)
      }
      width.isActive = false
    }
  }

  private var configuration: AIConfiguration {
    AIConfiguration(baseURL: "https://question.test/v1", model: "fixture-model", apiKey: "fixture-key")
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func button(_ title: String, _ view: NSView) throws -> NSButton {
    try XCTUnwrap(views(view).compactMap { $0 as? NSButton }.first { $0.title == title })
  }
  private func field(_ label: String, _ view: NSView) throws -> NSTextField {
    try XCTUnwrap(views(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
  }
}
