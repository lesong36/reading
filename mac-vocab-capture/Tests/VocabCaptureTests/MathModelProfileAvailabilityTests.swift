import Foundation
import Security
import XCTest
@testable import VocabCapture

final class MathModelProfileAvailabilityTests: XCTestCase {
  func testReadOnlyNonInteractiveProfileAvailability() throws {
    guard let directory = ProcessInfo.processInfo.environment["MATH_MODEL_PROFILE_AVAILABILITY"] else {
      throw XCTSkip("Opt-in local credential availability audit; no provider requests")
    }
    var allowed = DarwinBoolean(true)
    guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
      throw XCTSkip("Cannot query credentials without interactive authorization")
    }
    defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var records = preferences.profiles.map { profile -> [String:Any] in
      let configuration = preferences.configuration(for: profile.id)
      let account = profile.id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(profile.id)"
      let query: [CFString:Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account, kSecReturnData: true]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      return ["name": profile.name, "model": profile.model,
        "api": profile.api.resolved(for: configuration).rawValue,
        "credentialAvailableWithoutInteraction": !configuration.apiKey.isEmpty,
        "credentialStatus": status,
        "thinkingPreference": profile.thinking.rawValue,
        "providerRequests": 0]
    }
    if let data = defaults.data(forKey: "VocabCapture.aiConfiguration"),
      var configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data) {
      configuration.apiKey = KeychainStore.readAPIKey()
      records.append(["name": "existing-main-configuration", "model": configuration.model,
        "api": ScreenshotQuestionAPI.automatic.resolved(for: configuration).rawValue,
        "credentialAvailableWithoutInteraction": !configuration.apiKey.isEmpty,
        "providerRequests": 0])
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("profile-availability.json"))
  }
}
