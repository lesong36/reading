import Foundation
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionPreferencesTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private let dictionary = AIConfiguration(
    baseURL: "http://127.0.0.1:8080/v1", model: "dictionary-model", apiKey: "dictionary-secret")
  private let firstModel = AIConfiguration(
    baseURL: "https://first.test/v1", model: "first-model", apiKey: "first-secret")
  private let secondModel = AIConfiguration(
    baseURL: "https://second.test/v1", model: "second-model", apiKey: "second-secret")

  override func setUp() {
    super.setUp()
    suiteName = "VocabCapture.ModelProfileTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  private func preferences(_ keys: ProfileTestKeys) -> ScreenshotQuestionPreferences {
    ScreenshotQuestionPreferences(
      defaults: defaults,
      readAPIKey: {
        XCTFail("Per-profile injection must also handle legacy keys")
        return ""
      },
      saveAPIKey: { _ in XCTFail("Per-profile injection must also handle legacy keys") },
      readProfileAPIKey: { keys.read($0) }, saveProfileAPIKey: { try keys.save($1, id: $0) })
  }

  private func assertConfiguration(
    _ actual: AIConfiguration, equals expected: AIConfiguration,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(actual.baseURL, expected.baseURL, file: file, line: line)
    XCTAssertEqual(actual.model, expected.model, file: file, line: line)
    XCTAssertEqual(actual.apiKey, expected.apiKey, file: file, line: line)
  }

  private func legacyMetadata(enabled: Bool, key: String = "") throws {
    let metadata = AIConfiguration(
      baseURL: firstModel.baseURL, model: firstModel.model, apiKey: key)
    defaults.set(
      try JSONEncoder().encode(metadata), forKey: ScreenshotQuestionPreferences.configurationKey)
    defaults.set(enabled, forKey: ScreenshotQuestionPreferences.enabledKey)
  }

  func testConstructionDoesNotWritePreferencesOrReadCredentials() {
    let keys = ProfileTestKeys()
    _ = preferences(keys)
    XCTAssertNil(defaults.object(forKey: ScreenshotQuestionPreferences.profilesKey))
    XCTAssertTrue(keys.reads.isEmpty)
    XCTAssertTrue(keys.writes.isEmpty)
  }

  func testProtocolChoicePersistsAndDoesNotChangeOtherProfileOrKey() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(
      name: "原生 Claude", configuration: firstModel, api: .anthropicMessages)
    let second = try prefs.saveProfile(
      name: "通用问答", configuration: secondModel, api: .chatCompletions)
    prefs.selectProfile(first)
    let reopened = preferences(keys)
    XCTAssertEqual(reopened.selectedAPI, .anthropicMessages)
    XCTAssertEqual(reopened.profiles.first { $0.id == second }?.api, .chatCompletions)
    XCTAssertTrue(keys.reads.isEmpty)
    try prefs.saveProfile(id: first, name: "Responses", configuration: firstModel, api: .responses)
    XCTAssertEqual(reopened.selectedAPI, .responses)
    XCTAssertEqual(keys.values[first], firstModel.apiKey)
    XCTAssertEqual(keys.values[second], secondModel.apiKey)
  }

  func testPreProtocolProfilesLoadAsAutomaticWithoutCredentialWrites() throws {
    let metadata: [String: Any] = [
      "profiles": [
        [
          "id": "existing", "name": "已有模型", "baseURL": "https://api.aicodewith.com",
          "model": "claude-test",
        ]
      ], "selectedProfileID": "existing",
    ]
    let data = try JSONSerialization.data(withJSONObject: metadata)
    defaults.set(data, forKey: ScreenshotQuestionPreferences.profilesKey)
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    XCTAssertEqual(prefs.selectedProfileID, "existing")
    XCTAssertEqual(prefs.selectedAPI, .automatic)
    XCTAssertEqual(prefs.profiles.first?.name, "已有模型")
    XCTAssertEqual(defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), data)
    XCTAssertTrue(keys.reads.isEmpty)
    XCTAssertTrue(keys.writes.isEmpty)
  }

  func testDefaultAndMetadataBrowsingNeverReadCredentials() {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    XCTAssertTrue(prefs.profiles.isEmpty)
    XCTAssertNil(prefs.selectedProfileID)
    XCTAssertFalse(prefs.isEnabled)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: dictionary)
    assertConfiguration(
      prefs.configuration(for: "missing"),
      equals: AIConfiguration(baseURL: "", model: "", apiKey: ""))
    XCTAssertTrue(keys.reads.isEmpty)
    XCTAssertTrue(keys.writes.isEmpty)
  }

  func testTwoNamedModelsSaveWithoutSelectingAndKeepKeysSeparate() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: " 阅读模型 ", configuration: firstModel)
    let second = try prefs.saveProfile(name: "语法模型", configuration: secondModel)
    XCTAssertNotNil(UUID(uuidString: first))
    XCTAssertNotNil(UUID(uuidString: second))
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(prefs.profiles.map(\.id), [first, second])
    XCTAssertEqual(prefs.profiles.map(\.name), ["阅读模型", "语法模型"])
    XCTAssertNil(prefs.selectedProfileID)
    XCTAssertTrue(keys.reads.isEmpty, "Browsing saved metadata cannot require Keychain access")
    XCTAssertEqual(keys.values[first], firstModel.apiKey)
    XCTAssertEqual(keys.values[second], secondModel.apiKey)
    prefs.selectProfile(second)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: secondModel)
    XCTAssertEqual(keys.reads, [second])
    prefs.selectProfile(first)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: firstModel)
  }

  func testProfileAndSelectionPersistAcrossRestart() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    let second = try prefs.saveProfile(name: "Two", configuration: secondModel)
    prefs.selectProfile(second)
    let reopened = ScreenshotQuestionPreferences(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
      readProfileAPIKey: { keys.read($0) }, saveProfileAPIKey: { try keys.save($1, id: $0) })
    XCTAssertEqual(reopened.profiles.map(\.id), [first, second])
    XCTAssertEqual(reopened.selectedProfileID, second)
    assertConfiguration(reopened.configuration(fallingBackTo: dictionary), equals: secondModel)
  }

  func testUpdatingOneModelPreservesOtherModelKeyAndActiveSelection() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    let second = try prefs.saveProfile(name: "Two", configuration: secondModel)
    prefs.selectProfile(second)
    let replacement = AIConfiguration(
      baseURL: "https://replacement.test/v1", model: "replacement", apiKey: "replacement-secret")
    XCTAssertEqual(
      try prefs.saveProfile(id: first, name: "Updated", configuration: replacement), first)
    XCTAssertEqual(prefs.profiles.count, 2)
    XCTAssertEqual(prefs.profiles[0].name, "Updated")
    XCTAssertEqual(prefs.selectedProfileID, second)
    assertConfiguration(prefs.configuration(for: first), equals: replacement)
    assertConfiguration(prefs.configuration(for: second), equals: secondModel)
    let noKey = AIConfiguration(baseURL: replacement.baseURL, model: replacement.model, apiKey: "")
    try prefs.saveProfile(id: first, name: "Updated", configuration: noKey)
    XCTAssertNil(keys.values[first])
    XCTAssertEqual(keys.values[second], secondModel.apiKey)
    assertConfiguration(prefs.configuration(for: first), equals: noKey)
  }

  func testSaveFailurePreservesMetadataSelectionAndAllKeys() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    prefs.selectProfile(first)
    let originalMetadata = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    let originalKeys = keys.values
    keys.failWrites = true
    XCTAssertThrowsError(try prefs.saveProfile(name: "New", configuration: secondModel))
    XCTAssertThrowsError(
      try prefs.saveProfile(id: first, name: "Changed", configuration: secondModel))
    XCTAssertEqual(
      defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), originalMetadata)
    XCTAssertEqual(prefs.selectedProfileID, first)
    XCTAssertEqual(keys.values, originalKeys)
    XCTAssertEqual(prefs.profiles.count, 1)
  }

  func testCredentialPersistencePrecedesMetadataChanges() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let originalMetadata = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    keys.beforeWrite = { _, _ in
      XCTAssertEqual(
        self.defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), originalMetadata)
    }
    try prefs.saveProfile(name: "One", configuration: firstModel)
    XCTAssertNotEqual(
      defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), originalMetadata)
  }

  func testDeletingSelectedModelUsesDictionaryButRetainsOtherModel() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    let second = try prefs.saveProfile(name: "Two", configuration: secondModel)
    prefs.selectProfile(first)
    keys.beforeWrite = { id, value in
      XCTAssertEqual(id, first)
      XCTAssertEqual(value, "")
      XCTAssertEqual(prefs.selectedProfileID, first)
      XCTAssertEqual(prefs.profiles.map(\.id), [first, second])
    }
    try prefs.removeProfile(id: first)
    XCTAssertNil(prefs.selectedProfileID)
    XCTAssertFalse(prefs.isEnabled)
    XCTAssertEqual(prefs.profiles.map(\.id), [second])
    XCTAssertNil(keys.values[first])
    XCTAssertEqual(keys.values[second], secondModel.apiKey)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: dictionary)
    assertConfiguration(prefs.configuration(for: second), equals: secondModel)
  }

  func testDeletingInactiveModelKeepsSelectionAndDeleteFailureChangesNothing() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    let second = try prefs.saveProfile(name: "Two", configuration: secondModel)
    prefs.selectProfile(first)
    let originalMetadata = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    keys.failDeletes = true
    XCTAssertThrowsError(try prefs.removeProfile(id: first))
    XCTAssertEqual(
      defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), originalMetadata)
    XCTAssertEqual(prefs.selectedProfileID, first)
    XCTAssertEqual(keys.values[first], firstModel.apiKey)
    keys.failDeletes = false
    try prefs.removeProfile(id: second)
    XCTAssertEqual(prefs.selectedProfileID, first)
    XCTAssertEqual(prefs.profiles.map(\.id), [first])
    XCTAssertEqual(keys.values[first], firstModel.apiKey)
  }

  func testUnknownProfileAndEmptyNameCannotMutateStateOrCredentials() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    prefs.selectProfile(first)
    let originalMetadata = defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey)
    let writes = keys.writes.count
    prefs.selectProfile("missing")
    XCTAssertThrowsError(try prefs.removeProfile(id: "missing"))
    XCTAssertThrowsError(
      try prefs.saveProfile(id: "missing", name: "Unknown", configuration: secondModel))
    XCTAssertThrowsError(try prefs.saveProfile(name: " \n ", configuration: secondModel))
    XCTAssertEqual(prefs.selectedProfileID, first)
    XCTAssertEqual(
      defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey), originalMetadata)
    XCTAssertEqual(keys.writes.count, writes)
  }

  func testStoredProfilesContainNoCredentialsAndDoNotTouchDictionaryMetadata() throws {
    let keys = ProfileTestKeys()
    defaults.set(Data("untouched-dictionary".utf8), forKey: "VocabCapture.aiConfiguration")
    let prefs = preferences(keys)
    try prefs.saveProfile(name: "One", configuration: firstModel)
    try prefs.saveProfile(name: "Two", configuration: secondModel)
    let raw = try XCTUnwrap(defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey))
    let json = String(decoding: raw, as: UTF8.self)
    XCTAssertFalse(json.contains("apiKey"))
    XCTAssertFalse(json.contains(firstModel.apiKey))
    XCTAssertFalse(json.contains(secondModel.apiKey))
    XCTAssertEqual(
      defaults.data(forKey: "VocabCapture.aiConfiguration"), Data("untouched-dictionary".utf8))
  }

  func testLegacyMigrationPreservesEnabledStateWithoutReadingOrCopyingKey() throws {
    try legacyMetadata(enabled: true, key: "embedded-key-must-be-discarded")
    let keys = ProfileTestKeys()
    keys.values["legacy"] = firstModel.apiKey
    let prefs = preferences(keys)
    XCTAssertEqual(prefs.profiles.map(\.id), ["legacy"])
    XCTAssertEqual(prefs.selectedProfileID, "legacy")
    XCTAssertTrue(keys.reads.isEmpty)
    XCTAssertTrue(keys.writes.isEmpty)
    XCTAssertNil(defaults.object(forKey: ScreenshotQuestionPreferences.configurationKey))
    XCTAssertNil(defaults.object(forKey: ScreenshotQuestionPreferences.enabledKey))
    let raw = try XCTUnwrap(defaults.data(forKey: ScreenshotQuestionPreferences.profilesKey))
    XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("embedded-key-must-be-discarded"))
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: firstModel)
    XCTAssertEqual(keys.reads, ["legacy"])
  }

  func testDisabledLegacyMigrationKeepsProfileButUsesDictionary() throws {
    try legacyMetadata(enabled: false)
    let keys = ProfileTestKeys()
    keys.values["legacy"] = firstModel.apiKey
    let prefs = preferences(keys)
    XCTAssertEqual(prefs.profiles.map(\.id), ["legacy"])
    XCTAssertNil(prefs.selectedProfileID)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: dictionary)
    XCTAssertTrue(keys.reads.isEmpty)
    XCTAssertTrue(keys.writes.isEmpty)
    prefs.selectProfile("legacy")
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: firstModel)
  }

  func testCorruptEnabledLegacyAndMissingActiveProfileNeverFallback() {
    defaults.set(
      Data("corrupt legacy".utf8), forKey: ScreenshotQuestionPreferences.configurationKey)
    defaults.set(true, forKey: ScreenshotQuestionPreferences.enabledKey)
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    XCTAssertTrue(prefs.isEnabled)
    XCTAssertEqual(prefs.selectedProfileID, "legacy")
    XCTAssertTrue(prefs.profiles.isEmpty)
    var dictionaryReads = 0
    func readDictionary() -> AIConfiguration {
      dictionaryReads += 1
      return dictionary
    }
    assertConfiguration(
      prefs.configuration(fallingBackTo: readDictionary()),
      equals: AIConfiguration(baseURL: "", model: "", apiKey: ""))
    XCTAssertEqual(dictionaryReads, 0)
    XCTAssertTrue(keys.reads.isEmpty)
    prefs.useDictionaryConfiguration()
    assertConfiguration(prefs.configuration(fallingBackTo: readDictionary()), equals: dictionary)
    XCTAssertEqual(dictionaryReads, 1)
  }

  func testMissingEnabledLegacyAndCorruptProfileStateFailClosed() {
    defaults.set(true, forKey: ScreenshotQuestionPreferences.enabledKey)
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    XCTAssertTrue(prefs.isEnabled)
    XCTAssertTrue(prefs.profiles.isEmpty)
    defaults.set(
      Data("corrupt profile state".utf8), forKey: ScreenshotQuestionPreferences.profilesKey)
    assertConfiguration(
      prefs.configuration(fallingBackTo: dictionary),
      equals: AIConfiguration(baseURL: "", model: "", apiKey: ""))
    XCTAssertTrue(keys.reads.isEmpty)
  }

  func testSelectedValidModelNeverEvaluatesDictionaryFallback() throws {
    let keys = ProfileTestKeys()
    let prefs = preferences(keys)
    let first = try prefs.saveProfile(name: "One", configuration: firstModel)
    prefs.selectProfile(first)
    var dictionaryReads = 0
    func readDictionary() -> AIConfiguration {
      dictionaryReads += 1
      return dictionary
    }
    assertConfiguration(prefs.configuration(fallingBackTo: readDictionary()), equals: firstModel)
    XCTAssertEqual(dictionaryReads, 0)
    prefs.useDictionaryConfiguration()
    assertConfiguration(prefs.configuration(fallingBackTo: readDictionary()), equals: dictionary)
    XCTAssertEqual(dictionaryReads, 1)
    XCTAssertEqual(prefs.profiles.map(\.id), [first])
    XCTAssertEqual(keys.values[first], firstModel.apiKey)
  }

  func testLegacyClosureInjectionRemainsCompatibleWithoutMigrationKeyAccess() throws {
    try legacyMetadata(enabled: true)
    var key = firstModel.apiKey
    var reads = 0
    var writes = 0
    let prefs = ScreenshotQuestionPreferences(
      defaults: defaults,
      readAPIKey: {
        reads += 1
        return key
      },
      saveAPIKey: {
        writes += 1
        key = $0
      })
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(writes, 0)
    assertConfiguration(prefs.configuration(fallingBackTo: dictionary), equals: firstModel)
    try prefs.saveProfile(id: "legacy", name: "Renamed", configuration: secondModel)
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(key, secondModel.apiKey)
    XCTAssertEqual(prefs.selectedProfileID, "legacy")
    try prefs.removeProfile(id: "legacy")
    XCTAssertEqual(key, "")
    XCTAssertNil(prefs.selectedProfileID)
  }
}

private final class ProfileTestKeys {
  var values: [String: String] = [:]
  var reads: [String] = []
  var writes: [(String, String)] = []
  var failWrites = false
  var failDeletes = false
  var beforeWrite: ((String, String) -> Void)?

  func read(_ id: String) -> String {
    reads.append(id)
    return values[id] ?? ""
  }

  func save(_ key: String, id: String) throws {
    beforeWrite?(id, key)
    if failWrites || (key.isEmpty && failDeletes) {
      throw NSError(domain: "ProfileTestKeys", code: 1)
    }
    writes.append((id, key))
    values[id] = key.isEmpty ? nil : key
  }
}
