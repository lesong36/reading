import AppKit
import XCTest

@testable import VocabCapture

@MainActor final class QuestionThinkingTests: XCTestCase {
  func testDefaultsAndIndependentProfileChoicesNeverRewriteCredentials() throws {
    let suite = "QuestionThinkingTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var keyWrites = 0
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "fake-key" },
      saveProfileAPIKey: { _, _ in keyWrites += 1 })
    let config = AIConfiguration(
      baseURL: "https://example.test/v1", model: "gpt-6.1-sol", apiKey: "fake-key")
    let first = try prefs.saveProfile(name: "first", configuration: config)
    let second = try prefs.saveProfile(name: "second", configuration: config, thinking: .high)
    XCTAssertEqual(prefs.fallbackThinking, .off)
    prefs.selectProfile(first)
    XCTAssertEqual(prefs.selectedThinking, .off)
    prefs.setThinking(.low)
    XCTAssertEqual(prefs.selectedThinking, .low)
    prefs.selectProfile(second)
    XCTAssertEqual(prefs.selectedThinking, .high)
    prefs.selectProfile(nil)
    prefs.setThinking(.medium)
    prefs.selectProfile(first)
    XCTAssertEqual(prefs.selectedThinking, .low)
    prefs.selectProfile(nil)
    XCTAssertEqual(prefs.selectedThinking, .medium)
    XCTAssertEqual(keyWrites, 2)
    let legacy = try JSONDecoder().decode(
      ScreenshotQuestionModelProfile.self,
      from: Data(#"{"id":"old","name":"old","baseURL":"https://test/v1","model":"model"}"#.utf8))
    XCTAssertEqual(legacy.thinking, .off)
  }
  func testOCRPreviewReflowsWithoutChangingSourceSentToModel() throws {
    let raw = "tools. You can\nalso provide a subagent\r\nwith a custom model."
    XCTAssertEqual(
      ScreenshotQuestionPanel.sourcePreview(raw),
      "tools. You can also provide a subagent with a custom model.")
    let data = try ScreenshotQuestionClient.payload(
      question: "解释",
      context: ScreenshotQuestionContext(text: raw, selectedWord: nil, imageData: nil), history: [],
      configuration: AIConfiguration(
        baseURL: "https://api.deepseek.com", model: "deepseek-flash", apiKey: ""),
      api: .chatCompletions, thinking: .low)
    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual((obj["context"] as? [String: Any])?["text"] as? String, raw)
    XCTAssertEqual((obj["configuration"] as? [String: Any])?["thinking"] as? String, "low")
  }
  func testGroupedMenusHaveWorkingTargetsAndDistinctModelSettings() throws {
    _ = NSApplication.shared
    let delegate = makeIsolatedAppDelegate()
    let menu = delegate.makeMenu()
    XCTAssertFalse(menu.items.contains { $0.title == "AI 服务设置…" || $0.title == "问一问模型设置…" })
    let settings = try XCTUnwrap(menu.items.first { $0.title == "设置…" })
    XCTAssertTrue(settings.target === delegate)
    XCTAssertEqual(settings.keyEquivalent, ",")
    XCTAssertTrue(delegate.responds(to: try XCTUnwrap(settings.action)))
    XCTAssertFalse(menu.items.contains { $0.title == "快捷键与取词" || $0.title == "模型与服务" })
  }
  func testThinkingSettingsPickerLoadsSelectedProfileAndSavesChoice() throws {
    _ = NSApplication.shared
    let suite = "ThinkingSettingsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let id = try prefs.saveProfile(
      name: "test",
      configuration: AIConfiguration(
        baseURL: "https://test.example/v1", model: "gpt-6.1-sol", apiKey: ""), thinking: .high)
    prefs.selectProfile(id)
    let settings = ScreenshotQuestionModelSettings(preferences: prefs, dictionaryModel: "fallback")
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let picker = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSPopUpButton }.first {
        $0.accessibilityLabel() == "思考强度"
      })
    XCTAssertEqual(picker.selectedItem?.representedObject as? String, "high")
    picker.select(picker.itemArray.first { $0.representedObject as? String == "low" })
    let save = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSButton }.first {
        $0.title == "保存并使用"
      })
    save.performClick(nil)
    XCTAssertEqual(prefs.selectedThinking, .low)
    settings.panel.close()
  }

  func testPanelThinkingChoiceSynchronizesPendingModelSelection() throws {
    _ = NSApplication.shared
    let suite = "PanelThinkingTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let config = AIConfiguration(baseURL: "https://example.test", model: "test", apiKey: "")
    let first = try prefs.saveProfile(name: "first", configuration: config)
    let second = try prefs.saveProfile(name: "second", configuration: config, thinking: .high)
    prefs.selectProfile(first)
    let panel = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(text: "public", selectedWord: nil, imageData: nil),
      answer: { _, _, _, _ in "unused" }, modelPreferences: prefs, interfaceDefaults: defaults)
    defer { panel.close() }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let pickers = views(panel.contentView!).compactMap { $0 as? NSPopUpButton }
    let models = try XCTUnwrap(pickers.first { $0.accessibilityLabel() == "问答模型" })
    let thinking = try XCTUnwrap(pickers.first { $0.accessibilityLabel() == "问答思考强度" })
    models.select(models.itemArray.first { $0.representedObject as? String == second })
    thinking.select(thinking.itemArray.first { $0.representedObject as? String == "low" })
    NSApp.sendAction(try XCTUnwrap(thinking.action), to: thinking.target, from: thinking)
    XCTAssertEqual(prefs.selectedProfileID, second)
    XCTAssertEqual(prefs.selectedThinking, .low)
    XCTAssertEqual(thinking.selectedItem?.representedObject as? String, "low")
    prefs.selectProfile(first)
    XCTAssertEqual(prefs.selectedThinking, .off)
    panel.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(models.frame.width, thinking.frame.width, accuracy: 1)
  }
}
