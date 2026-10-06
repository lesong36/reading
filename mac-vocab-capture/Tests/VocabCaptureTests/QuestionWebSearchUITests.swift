import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class QuestionWebSearchUITests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func button(_ title: String, _ panel: NSPanel) throws -> NSButton {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title })
  }
  private func question(_ panel: NSPanel) throws -> NSTextField {
    try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == "提问内容"
      })
  }
  private func transcript(_ panel: NSPanel) throws -> NSTextView {
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSTextView }.first)
  }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for UI request")
  }

  func testSearchControlsOnlyAppearWithSupportedCallbackAndSavedChoiceRestores() throws {
    _ = NSApplication.shared
    let suite = "QuestionWebSearchVisibilityTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ScreenshotQuestionPanel.webSearchEnabledKey)
    let context = ScreenshotQuestionContext(text: "source", selectedWord: nil, imageData: nil)
    let unsupported = ScreenshotQuestionPanel(
      context: context, answer: { _, _, _, _ in "" }, interfaceDefaults: defaults)
    defer { unsupported.close() }
    XCTAssertTrue(try button("联网检索", unsupported).isHiddenOrHasHiddenAncestor)
    let supported = ScreenshotQuestionPanel(
      context: context, answer: { _, _, _, _ in "" }, interfaceDefaults: defaults,
      webAnswer: { _, _, _, _, _, _, _ in "" })
    defer { supported.close() }
    let checkbox = try button("联网检索", supported)
    XCTAssertFalse(checkbox.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(checkbox.state, .on)
  }

  func testSearchToggleForwardsSnapshotCancelsAndRejectsLatePhases() async throws {
    _ = NSApplication.shared
    let suite = "QuestionWebSearchUITests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = WebGate()
    let panel = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(
        text: "Release information", selectedWord: nil, imageData: nil),
      answer: { _, _, _, _ in
        XCTFail("Wrong callback")
        return ""
      },
      interfaceDefaults: defaults,
      webAnswer: { _, _, _, enabled, _, progress, partial in
        try await gate.answer(enabled: enabled, progress: progress, partial: partial)
      }, onSearchSettings: {})
    defer { panel.close() }
    let checkbox = try button("联网检索", panel)
    let field = try question(panel)
    XCTAssertEqual(checkbox.state, .off)
    field.stringValue = "第一问"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    XCTAssertFalse(gate.requests[0].enabled)
    gate.requests[0].continuation.resume(returning: "完成")
    try await wait { !panel.isAnswering }
    XCTAssertEqual(panel.history.count, 1)
    checkbox.performClick(nil)
    XCTAssertEqual(checkbox.state, .on)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertTrue(defaults.bool(forKey: ScreenshotQuestionPanel.webSearchEnabledKey))
    field.stringValue = "检索问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    XCTAssertTrue(gate.requests[1].enabled)
    gate.requests[1].progress(.search)
    XCTAssertNil(panel.performance?.firstTextAt)
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue == ScreenshotQuestionSearchStage.search.title
      })
    field.stringValue = "保留草稿"
    checkbox.performClick(nil)
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(field.stringValue, "保留草稿")
    gate.requests[1].progress(.answer)
    gate.requests[1].partial("旧回答")
    gate.requests[1].continuation.resume(returning: "旧结果")
    await Task.yield()
    XCTAssertEqual(try transcript(panel).string, "")
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertFalse(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue == ScreenshotQuestionSearchStage.answer.title
      })
  }

  func testToggleRestoresPendingQuestionAndSourceLinksSurviveZoom() async throws {
    _ = NSApplication.shared
    let suite = "QuestionWebSearchLinkTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = WebGate()
    let panel = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(text: "source", selectedWord: nil, imageData: nil),
      answer: { _, _, _, _ in "" }, interfaceDefaults: defaults,
      webAnswer: { _, _, _, enabled, _, progress, partial in
        try await gate.answer(enabled: enabled, progress: progress, partial: partial)
      })
    defer { panel.close() }
    try question(panel).stringValue = "原问题"
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 1 }
    try button("联网检索", panel).performClick(nil)
    XCTAssertEqual(try question(panel).stringValue, "原问题")
    gate.requests[0].continuation.resume(returning: "迟到")
    try button("提问", panel).performClick(nil)
    try await wait { gate.requests.count == 2 }
    gate.requests[1].continuation.resume(
      returning: "来源：[官网](https://example.org/docs)\n不执行 file:///tmp/test")
    try await wait { !panel.isAnswering }
    let view = try transcript(panel)
    let text = view.string as NSString
    let range = text.range(of: "https://example.org/docs")
    XCTAssertEqual(
      view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
      URL(string: "https://example.org/docs"))
    let fileRange = text.range(of: "file:///tmp/test")
    XCTAssertNil(view.textStorage?.attribute(.link, at: fileRange.location, effectiveRange: nil))
    panel.zoomIn(nil)
    XCTAssertNotNil(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
  }

  func testSettingsSaveAndCancelUseInjectedKeyStoreOnly() throws {
    _ = NSApplication.shared
    let suite = "QuestionWebSearchSettingsTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var key = "fake-original"
    var writes = 0
    let preferences = ScreenshotQuestionWebSearchPreferences(
      defaults: defaults, readAPIKey: { key },
      saveAPIKey: {
        key = $0
        writes += 1
      })
    let settings = ScreenshotQuestionWebSearchSettings(preferences: preferences)
    let secure = try XCTUnwrap(
      views(settings.panel.contentView!).compactMap { $0 as? NSSecureTextField }.first)
    XCTAssertEqual(secure.stringValue, "fake-original")
    secure.stringValue = "fake-replacement"
    try button("取消", settings.panel).performClick(nil)
    XCTAssertEqual(writes, 0)
    let saved = ScreenshotQuestionWebSearchSettings(preferences: preferences)
    let savedKey = try XCTUnwrap(
      views(saved.panel.contentView!).compactMap { $0 as? NSSecureTextField }.first)
    savedKey.stringValue = ""
    try button("搜索服务直连（跳过系统 HTTP 代理）", saved.panel).performClick(nil)
    try button("保存", saved.panel).performClick(nil)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(key, "")
    XCTAssertTrue(preferences.directConnection)
    XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1)
  }
}

@MainActor private final class WebGate {
  struct Request {
    let enabled: Bool
    let progress: @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void
    let partial: @MainActor @Sendable (String) -> Void
    let continuation: CheckedContinuation<String, Error>
  }
  var requests: [Request] = []
  func answer(
    enabled: Bool, progress: @escaping @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void,
    partial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(
        Request(enabled: enabled, progress: progress, partial: partial, continuation: continuation))
    }
  }
}
