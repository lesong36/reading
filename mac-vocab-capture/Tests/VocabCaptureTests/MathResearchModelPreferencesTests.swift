import Foundation
import XCTest
@testable import VocabCapture

final class MathResearchModelPreferencesTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!
  private var keys: [String: String] = [:]
  private var reads: [String] = []
  private var writes: [String] = []
  private let fallback = AIConfiguration(baseURL: "https://fallback.test", model: "fallback", apiKey: "fallback-secret")

  override func setUp() {
    super.setUp()
    suite = "MathResearchModelPreferencesTests." + UUID().uuidString
    defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    keys = [:]; reads = []; writes = []
  }
  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil; suite = nil
    super.tearDown()
  }
  private func questionPreferences() -> ScreenshotQuestionPreferences {
    ScreenshotQuestionPreferences(defaults: defaults,
      readAPIKey: { XCTFail("Unexpected legacy credential access"); return "" },
      saveAPIKey: { _ in XCTFail("Unexpected legacy credential write") },
      readProfileAPIKey: { [self] in reads.append($0); return keys[$0] ?? "" },
      saveProfileAPIKey: { [self] in writes.append($0); keys[$0] = $1 })
  }
  private func add(_ preferences: ScreenshotQuestionPreferences, name: String,
    api: ScreenshotQuestionAPI = .automatic, direct: Bool = false) throws -> String {
    try preferences.saveProfile(name: name,
      configuration: .init(baseURL: "https://\(name).test", model: name, apiKey: "\(name)-secret"),
      api: api, directConnection: direct)
  }

  func testDefaultFollowsCurrentQuestionSelectionAndFallback() throws {
    let question = questionPreferences()
    let research = MathResearchModelPreferences(defaults: defaults)
    XCTAssertNil(research.selectedProfileID)
    XCTAssertNil(defaults.object(forKey: MathResearchModelPreferences.profileIDKey))
    var resolved = research.resolve(preferences: question, fallback: fallback)
    XCTAssertEqual(resolved.configuration.model, "fallback")
    XCTAssertEqual(resolved.configuration.apiKey, "fallback-secret")
    let first = try add(question, name: "first", api: .responses, direct: true)
    let second = try add(question, name: "second", api: .anthropicMessages)
    question.selectProfile(first)
    resolved = research.resolve(preferences: question, fallback: fallback)
    XCTAssertEqual(resolved.configuration.model, "first")
    XCTAssertEqual(resolved.api, .responses)
    XCTAssertTrue(resolved.directConnection)
    question.selectProfile(second)
    resolved = research.resolve(preferences: question, fallback: fallback)
    XCTAssertEqual(resolved.configuration.model, "second")
    XCTAssertEqual(resolved.api, .anthropicMessages)
    XCTAssertFalse(resolved.directConnection)
    XCTAssertNil(research.selectedProfileID)
  }

  func testExplicitChoicePersistsAndReadsExactCredentialsWithoutChangingForeground() throws {
    let question = questionPreferences()
    let foreground = try add(question, name: "foreground", api: .chatCompletions)
    let background = try add(question, name: "background", api: .anthropicMessages, direct: true)
    question.selectProfile(foreground)
    let metadataBefore = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    let keyWritesBefore = writes
    let research = MathResearchModelPreferences(defaults: defaults)
    try research.select(profileID: background, available: question.profiles)
    XCTAssertTrue(reads.isEmpty, "Choosing a profile must not read credentials")
    let reopened = MathResearchModelPreferences(defaults: defaults)
    XCTAssertEqual(reopened.selectedProfileID, background)
    let resolved = reopened.resolve(preferences: question, fallback: fallback)
    XCTAssertEqual(resolved.configuration.baseURL, "https://background.test")
    XCTAssertEqual(resolved.configuration.model, "background")
    XCTAssertEqual(resolved.configuration.apiKey, "background-secret")
    XCTAssertEqual(resolved.api, .anthropicMessages)
    XCTAssertTrue(resolved.directConnection)
    XCTAssertEqual(reads, [background])
    XCTAssertEqual(writes, keyWritesBefore)
    XCTAssertEqual(question.selectedProfileID, foreground)
    XCTAssertEqual(defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), metadataBefore)
    XCTAssertEqual(defaults.string(forKey: MathResearchModelPreferences.profileIDKey), background)
    let domain = defaults.persistentDomain(forName: suite)!
    XCTAssertFalse(String(describing: domain).contains("background-secret"))
    XCTAssertFalse(String(describing: domain).contains("foreground-secret"))
  }

  func testDeletedExplicitChoiceFailsClosedAndCanBeResetToFollow() throws {
    let question = questionPreferences()
    let foreground = try add(question, name: "foreground")
    let background = try add(question, name: "background")
    question.selectProfile(foreground)
    let research = MathResearchModelPreferences(defaults: defaults)
    try research.select(profileID: background, available: question.profiles)
    try question.removeProfile(id: background)
    reads.removeAll()
    let missing = research.resolve(preferences: question, fallback: fallback)
    XCTAssertEqual(missing.configuration.baseURL, "")
    XCTAssertEqual(missing.configuration.model, "")
    XCTAssertEqual(missing.configuration.apiKey, "")
    XCTAssertTrue(reads.isEmpty)
    XCTAssertEqual(research.selectedProfileID, background, "Keep missing identity visible for correction")
    XCTAssertEqual(question.selectedProfileID, foreground)
    try research.select(profileID: nil, available: question.profiles)
    XCTAssertNil(research.selectedProfileID)
    XCTAssertNil(defaults.object(forKey: MathResearchModelPreferences.profileIDKey))
    XCTAssertEqual(research.resolve(preferences: question, fallback: fallback).configuration.model, "foreground")
    XCTAssertEqual(reads, [foreground])
  }

  func testInvalidSelectionDoesNotMutateExistingChoiceOrReadKeys() throws {
    let question = questionPreferences()
    let id = try add(question, name: "existing")
    let research = MathResearchModelPreferences(defaults: defaults)
    XCTAssertThrowsError(try research.select(profileID: "absent", available: question.profiles))
    XCTAssertNil(research.selectedProfileID)
    try research.select(profileID: id, available: question.profiles)
    let before = defaults.persistentDomain(forName: suite)! as NSDictionary
    XCTAssertThrowsError(try research.select(profileID: "absent", available: question.profiles))
    XCTAssertThrowsError(try research.select(profileID: "", available: question.profiles))
    XCTAssertEqual(research.selectedProfileID, id)
    XCTAssertEqual(defaults.persistentDomain(forName: suite)! as NSDictionary, before)
    XCTAssertTrue(reads.isEmpty)
  }
}
