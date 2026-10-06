import AppKit
import XCTest

@testable import VocabCapture

@MainActor final class QuestionNetworkTests: XCTestCase {
  func testNetworkChoiceIsIndependentAndNeverTouchesCredentials() throws {
    let suite = "QuestionNetworkTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var reads = 0
    var writes = 0
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults,
      readProfileAPIKey: { _ in
        reads += 1
        return ""
      },
      saveProfileAPIKey: { _, _ in writes += 1 })
    let config = AIConfiguration(baseURL: "https://example.test", model: "test", apiKey: "")
    let first = try prefs.saveProfile(name: "first", configuration: config, thinking: .high)
    let second = try prefs.saveProfile(name: "second", configuration: config)
    prefs.selectProfile(first)
    XCTAssertFalse(prefs.selectedDirectConnection)
    prefs.setDirectConnection(true)
    prefs.setThinking(.low)
    XCTAssertTrue(prefs.selectedDirectConnection)
    XCTAssertEqual(prefs.selectedThinking, .low)
    prefs.selectProfile(second)
    XCTAssertFalse(prefs.selectedDirectConnection)
    prefs.selectProfile(nil)
    prefs.setDirectConnection(true)
    prefs.selectProfile(first)
    prefs.setDirectConnection(false)
    prefs.selectProfile(nil)
    XCTAssertTrue(prefs.selectedDirectConnection)
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(writes, 2)
    let legacy = try JSONDecoder().decode(
      ScreenshotQuestionModelProfile.self,
      from: Data(#"{"id":"old","name":"old","baseURL":"https://test","model":"test"}"#.utf8))
    XCTAssertFalse(legacy.directConnection)
  }

  func testPayloadForwardsNetworkChoiceWithoutChangingSourceOrProtocol() throws {
    let config = AIConfiguration(
      baseURL: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "")
    let context = ScreenshotQuestionContext(
      text: "original\nsource", selectedWord: nil, imageData: nil)
    let payload = try ScreenshotQuestionClient.payload(
      question: "question", context: context, history: [], configuration: config,
      api: .chatCompletions, thinking: .off, directConnection: true)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let settings = try XCTUnwrap(body["configuration"] as? [String: Any])
    XCTAssertEqual(settings["direct_connection"] as? Bool, true)
    XCTAssertEqual(settings["endpoint"] as? String, "https://api.deepseek.com/chat/completions")
    XCTAssertEqual((body["context"] as? [String: Any])?["text"] as? String, context.text)
  }

  func testSettingsLoadsAndSavesModelNetworkChoice() throws {
    _ = NSApplication.shared
    let suite = "QuestionNetworkSettingsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let id = try prefs.saveProfile(
      name: "test",
      configuration: AIConfiguration(baseURL: "https://example.test", model: "test", apiKey: ""),
      thinking: .high, directConnection: true)
    prefs.selectProfile(id)
    let settings = ScreenshotQuestionModelSettings(preferences: prefs, dictionaryModel: "fallback")
    defer { settings.panel.close() }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let buttons = views(settings.panel.contentView!).compactMap { $0 as? NSButton }
    let direct = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "此模型直连" })
    XCTAssertEqual(direct.state, .on)
    direct.state = .off
    try XCTUnwrap(buttons.first { $0.title == "保存并使用" }).performClick(nil)
    XCTAssertFalse(prefs.selectedDirectConnection)
    XCTAssertEqual(prefs.selectedThinking, .high)
  }
}
