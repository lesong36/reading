import XCTest

@testable import VocabCapture

final class QuestionWebSearchPreferencesTests: XCTestCase {
  func testKeyStaysInInjectedCredentialStoreAndBlankCanClearIt() throws {
    let suite = "QuestionWebSearchPreferencesTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var key = ""
    let preferences = ScreenshotQuestionWebSearchPreferences(
      defaults: defaults, readAPIKey: { key }, saveAPIKey: { key = $0 })
    XCTAssertFalse(preferences.directConnection)
    XCTAssertThrowsError(try preferences.configuration()) { error in
      XCTAssertTrue(error is ScreenshotQuestionWebSearchError)
    }
    try preferences.save(apiKey: "  fake-tavily-key \n", directConnection: true)
    let configuration = try preferences.configuration()
    XCTAssertEqual(configuration.apiKey, "fake-tavily-key")
    XCTAssertTrue(configuration.directConnection)
    XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1)
    XCTAssertEqual(
      defaults.bool(forKey: ScreenshotQuestionWebSearchPreferences.directConnectionKey), true)
    try preferences.save(apiKey: "  ", directConnection: false)
    XCTAssertEqual(key, "")
    XCTAssertThrowsError(try preferences.configuration())
  }

  func testFailedCredentialWriteDoesNotPersistNetworkChange() throws {
    let suite = "QuestionWebSearchWriteFailureTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenshotQuestionWebSearchPreferences(
      defaults: defaults, readAPIKey: { "fake" },
      saveAPIKey: { _ in throw CocoaError(.fileWriteUnknown) })
    XCTAssertThrowsError(try preferences.save(apiKey: "replacement", directConnection: true))
    XCTAssertFalse(preferences.directConnection)
    XCTAssertNil(defaults.persistentDomain(forName: suite))
  }
}
