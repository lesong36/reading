import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotQuestionModelSettingsTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var keys: [String: String] = [:]
  private var failWrites = false
  private var preferences: ScreenshotQuestionPreferences!
  private let configuration = AIConfiguration(
    baseURL: "https://question.test/v1", model: "reading-model", apiKey: "test-only-key")

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    suite = "VocabCapture.ProfileSettingsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    keys = [:]
    failWrites = false
    preferences = ScreenshotQuestionPreferences(
      defaults: defaults,
      readProfileAPIKey: { [unowned self] in self.keys[$0] ?? "" },
      saveProfileAPIKey: { [unowned self] id, value in
        if self.failWrites { throw NSError(domain: "Fixture", code: 1) }
        self.keys[id] = value
      })
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    preferences = nil
    defaults = nil
    super.tearDown()
  }

  func testFallbackSaveDoesNotRequireFields() throws {
    let settings = makeSettings()
    var closed = false
    settings.present(onClose: { closed = true })
    XCTAssertFalse(try field("模型名称（Model）", settings).isEnabled)
    try button("保存并使用", settings).performClick(nil)
    XCTAssertNil(preferences.selectedProfileID)
    XCTAssertTrue(closed)
    XCTAssertFalse(settings.panel.isVisible)
  }

  func testAddTwoConfigurationsAndEditOneWithoutReplacingOther() throws {
    for (name, model, key) in [("日常问答", "fast", "first-key"), ("语法分析", "strong", "second-key")] {
      let settings = makeSettings()
      settings.present()
      try button("新增配置", settings).performClick(nil)
      try field("配置名称", settings).stringValue = " \(name) "
      try field("服务地址（Base URL）", settings).stringValue = " https://question.test/v1 "
      try field("模型名称（Model）", settings).stringValue = " \(model) "
      try field("API Key", settings).stringValue = key
      try button("保存并使用", settings).performClick(nil)
      XCTAssertFalse(settings.panel.isVisible)
    }
    XCTAssertEqual(preferences.profiles.map(\.name), ["日常问答", "语法分析"])
    let firstID = preferences.profiles[0].id
    let secondID = preferences.profiles[1].id
    XCTAssertEqual(preferences.selectedProfileID, secondID)
    let settings = makeSettings()
    settings.present()
    let picker = try picker(settings)
    picker.selectItem(at: 1)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    XCTAssertEqual(try field("API Key", settings).stringValue, "first-key")
    try field("模型名称（Model）", settings).stringValue = "updated"
    try button("保存并使用", settings).performClick(nil)
    XCTAssertEqual(preferences.profiles.count, 2)
    XCTAssertEqual(preferences.selectedProfileID, firstID)
    XCTAssertEqual(preferences.configuration(for: firstID).model, "updated")
    XCTAssertEqual(preferences.configuration(for: secondID).apiKey, "second-key")
  }

  func testProtocolCanBeChosenSavedAndReopened() throws {
    let id = try preferences.saveProfile(name: "原生模型", configuration: configuration)
    preferences.selectProfile(id)
    let settings = makeSettings()
    settings.present()
    let api = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSPopUpButton }.first {
        $0.accessibilityLabel() == "接口协议"
      })
    api.select(
      api.itemArray.first {
        $0.representedObject as? String == ScreenshotQuestionAPI.anthropicMessages.rawValue
      })
    try button("保存并使用", settings).performClick(nil)
    XCTAssertEqual(preferences.selectedAPI, .anthropicMessages)
    let reopened = makeSettings()
    let reopenedAPI = try XCTUnwrap(
      views(reopened.panel.contentView!).compactMap { $0 as? NSPopUpButton }.first {
        $0.accessibilityLabel() == "接口协议"
      })
    XCTAssertEqual(
      reopenedAPI.selectedItem?.representedObject as? String,
      ScreenshotQuestionAPI.anthropicMessages.rawValue)
  }

  func testValidationAndCredentialFailureKeepFormOpen() throws {
    let settings = makeSettings()
    settings.present()
    try button("新增配置", settings).performClick(nil)
    try field("配置名称", settings).stringValue = ""
    try button("保存并使用", settings).performClick(nil)
    XCTAssertEqual(try field("设置状态", settings).stringValue, "请为配置填写名称。")
    try field("配置名称", settings).stringValue = "配置"
    for invalid in [
      "", "file:///tmp/model", "https://user:password@question.test/v1",
      "https://question.test/v1?key=secret",
    ] {
      try field("服务地址（Base URL）", settings).stringValue = invalid
      try button("保存并使用", settings).performClick(nil)
      XCTAssertTrue(preferences.profiles.isEmpty)
      XCTAssertTrue(settings.panel.isVisible)
    }
    try field("服务地址（Base URL）", settings).stringValue = configuration.baseURL
    try field("模型名称（Model）", settings).stringValue = " "
    try button("保存并使用", settings).performClick(nil)
    XCTAssertTrue(preferences.profiles.isEmpty)
    try field("模型名称（Model）", settings).stringValue = configuration.model
    failWrites = true
    try button("保存并使用", settings).performClick(nil)
    XCTAssertTrue(preferences.profiles.isEmpty)
    XCTAssertTrue(try field("设置状态", settings).stringValue.contains("无法保存"))
    XCTAssertTrue(settings.panel.isVisible)
    try button("取消", settings).performClick(nil)
  }

  func testCancelAndWindowCloseNeverSave() throws {
    var closes = 0
    for closeViaWindow in [false, true] {
      let settings = makeSettings()
      settings.present(onClose: { closes += 1 })
      try button("新增配置", settings).performClick(nil)
      try field("模型名称（Model）", settings).stringValue = "unsaved-model"
      if closeViaWindow {
        settings.panel.performClose(nil)
      } else {
        try button("取消", settings).performClick(nil)
      }
      XCTAssertTrue(preferences.profiles.isEmpty)
      XCTAssertFalse(settings.panel.isVisible)
    }
    XCTAssertEqual(closes, 2)
  }

  func testDeleteRequiresSecondClickAndSelectedRemovalUsesFallback() throws {
    let id = try preferences.saveProfile(name: "待删除", configuration: configuration)
    preferences.selectProfile(id)
    let settings = makeSettings()
    var changed = 0
    settings.present(onChange: { changed += 1 })
    try button("删除配置", settings).performClick(nil)
    XCTAssertEqual(preferences.profiles.count, 1)
    XCTAssertEqual(changed, 0)
    try button("确认删除", settings).performClick(nil)
    XCTAssertTrue(preferences.profiles.isEmpty)
    XCTAssertNil(preferences.selectedProfileID)
    XCTAssertEqual(changed, 1)
    try button("取消", settings).performClick(nil)
  }

  func testMenuItemTargetsDelegateDirectly() {
    let delegate = AppDelegate()
    let item = delegate.makeQuestionModelSettingsItem()
    XCTAssertEqual(item.title, "问一问模型设置…")
    XCTAssertTrue(item.target === delegate)
    XCTAssertEqual(item.action, #selector(AppDelegate.openQuestionModelSettings))
  }

  private func makeSettings() -> ScreenshotQuestionModelSettings {
    ScreenshotQuestionModelSettings(preferences: preferences, dictionaryModel: "local-model")
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func picker(_ settings: ScreenshotQuestionModelSettings) throws -> NSPopUpButton {
    try XCTUnwrap(views(settings.panel.contentView!).compactMap { $0 as? NSPopUpButton }.first)
  }
  private func button(_ title: String, _ settings: ScreenshotQuestionModelSettings) throws
    -> NSButton
  {
    try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
  }
  private func field(_ label: String, _ settings: ScreenshotQuestionModelSettings) throws
    -> NSTextField
  {
    try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == label
      })
  }
}
