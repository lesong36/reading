import AppKit
import XCTest

@testable import VocabCapture

@MainActor final class QuestionModelDefaultsTests: XCTestCase {
  func testPristineInstallationUsesDeepSeekWithoutAccessingKeys() throws {
    let suite = "QuestionDefaults.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var keyAccesses = 0
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults,
      readProfileAPIKey: { _ in
        keyAccesses += 1
        return ""
      },
      saveProfileAPIKey: { _, _ in keyAccesses += 1 })
    prefs.prepareDefaultModel()
    XCTAssertEqual(prefs.profiles, [ScreenshotQuestionPreferences.defaultProfile])
    XCTAssertEqual(prefs.selectedProfileID, ScreenshotQuestionPreferences.defaultProfile.id)
    XCTAssertEqual(prefs.selectedThinking, .off)
    XCTAssertFalse(prefs.selectedDirectConnection)
    prefs.prepareDefaultModel()
    XCTAssertEqual(prefs.profiles.count, 1)
    XCTAssertEqual(keyAccesses, 0)
    prefs.useDictionaryConfiguration()
    prefs.prepareDefaultModel()
    XCTAssertNil(prefs.selectedProfileID, "Remember an explicit fallback choice")
  }

  func testDefaultDoesNotReplaceExistingOrLegacySelection() throws {
    let suite = "QuestionDefaultMigration.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let id = try prefs.saveProfile(
      name: "Kimi",
      configuration: AIConfiguration(
        baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2.6", apiKey: ""))
    prefs.selectProfile(id)
    let previous = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    prefs.prepareDefaultModel()
    XCTAssertEqual(defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), previous)
    XCTAssertEqual(prefs.selectedProfileID, id)
    defaults.removeObject(forKey: ScreenshotQuestionPreferences.profilesKey)
    defaults.set(true, forKey: ScreenshotQuestionPreferences.enabledKey)
    prefs.prepareDefaultModel()
    XCTAssertNil(defaults.object(forKey: ScreenshotQuestionPreferences.profilesKey))
    XCTAssertEqual(prefs.selectedProfileID, "legacy")
  }

  func testNewEditorPrefillsDeepSeekAndLeavesKeyEmpty() throws {
    _ = NSApplication.shared
    let suite = "QuestionDefaultEditor.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let settings = ScreenshotQuestionModelSettings(preferences: prefs, dictionaryModel: "local")
    defer { settings.panel.close() }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(settings.panel.contentView!)
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "新增配置" }).performClick(nil)
    func field(_ label: String) throws -> NSTextField {
      try XCTUnwrap(
        all.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
    }
    XCTAssertEqual(try field("配置名称").stringValue, "DeepSeek Flash")
    XCTAssertEqual(try field("服务地址（Base URL）").stringValue, "https://api.deepseek.com")
    XCTAssertEqual(try field("模型名称（Model）").stringValue, "deepseek-flash")
    XCTAssertEqual(try field("API Key").stringValue, "")
    XCTAssertTrue(prefs.profiles.isEmpty, "A draft must not persist until saved")
  }

  func testKimiRootVersionedAndCompleteURLsResolveOnce() throws {
    for host in ["api.moonshot.cn", "api.moonshot.ai"] {
      for path in ["", "/v1", "/v1/chat/completions/"] {
        let cfg = AIConfiguration(baseURL: "https://" + host + path, model: "kimi-k2.6", apiKey: "")
        XCTAssertEqual(
          try ScreenshotQuestionAPI.automatic.endpoint(for: cfg).absoluteString,
          "https://" + host + "/v1/chat/completions")
      }
    }
  }
}
