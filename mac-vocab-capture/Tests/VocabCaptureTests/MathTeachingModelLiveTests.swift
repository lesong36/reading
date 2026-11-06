import Foundation
import Security
import XCTest
@testable import VocabCapture

/// Explicitly enabled evaluation of the user's configured model. The key is read
/// through the normal native preference path and sent only through anonymous stdin.
@MainActor
final class MathTeachingModelLiveTests: XCTestCase {
  func testConfiguredModelFrameworkAndFullSnapshotComparison() async throws {
    guard let output = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_ARTIFACTS"] else {
      throw XCTSkip("Set MATH_TEACHING_LIVE_ARTIFACTS to run the actual configured model comparison")
    }
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let bundledSource = package.appendingPathComponent("question-engine")
    // Opt-in isolated source experiments retain the existing local runtime and
    // anonymous credential bridge. The evaluator hashes its actual source tree.
    let engine = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_ENGINE_SOURCE"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? bundledSource
    let python = bundledSource.appendingPathComponent(".venv/bin/python")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
      throw XCTSkip("Requires the existing question-engine runtime")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    // Comparisons must never wait on an interactive Keychain permission prompt.
    // This only changes this opt-in test's credential reader, not app settings.
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      // AuthenticationUIFail is ignored by some legacy macOS keychain items.
      // Suppress interaction in this test process only and restore immediately.
      var previous: DarwinBoolean = true
      guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
        SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return "" }
      defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
      let account = id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)"
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account,
        kSecReturnData: true, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return "" }
      return String(decoding: data, as: UTF8.self)
    })
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    var configuration = preferences.configuration(fallingBackTo: fallback)
    var evaluationAPI = preferences.selectedAPI
    var evaluationDirectConnection = preferences.selectedDirectConnection
    if let model = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_PROFILE_MODEL"] {
      let matching = preferences.profiles.filter { $0.model == model }
      guard matching.count == 1, let profile = matching.first else {
        throw XCTSkip("Comparison requires one existing configured model profile")
      }
      configuration = preferences.configuration(for: profile.id)
      guard !configuration.apiKey.isEmpty else {
        throw XCTSkip("Configured profile credential is unavailable without interactive Keychain access; no model request made")
      }
      evaluationAPI = profile.api
      evaluationDirectConnection = profile.directConnection
    }
    if let model = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_MODEL"] {
      // Same-provider, opt-in comparison. Never persist this experiment in the
      // user's settings or forward their credential to another provider.
      XCTAssertEqual(URL(string: configuration.baseURL)?.host, "api.deepseek.com")
      guard URL(string: configuration.baseURL)?.host == "api.deepseek.com",
        ["deepseek-flash", "deepseek-v4-pro"].contains(model) else {
        throw XCTSkip("Model comparison requires the configured official DeepSeek endpoint")
      }
      configuration.model = model
    }
    let store = MathQuestionStore(directory: destination.appendingPathComponent("isolated-methods"))
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let methods = try await store.methods()
    await store.close()
    let data = try ScreenshotQuestionClient.payload(question: "方法选择评测", context: .init(text: "只读评测资料", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: evaluationAPI, thinking: .off,
      directConnection: evaluationDirectConnection, instructions: MathMethodMatcher.instructions,
      teachingSkills: methods)
    let complete = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bridge = try JSONSerialization.data(withJSONObject: complete.filter {
      ["configuration", "instructions", "teaching_skills"].contains($0.key)
    })
    let reportURL = destination.appendingPathComponent("model-comparison.json")
    var arguments = [engine.appendingPathComponent("evaluate_teaching.py").path,
      "--corpus", package.appendingPathComponent("Sources/VocabCapture/Resources/MathTeachingReview/evaluation-corpus.json").path,
      "--output", reportURL.path,
      "--limit", ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_LIMIT"] ?? "6"]
    if let cases = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_CASES"] { arguments += ["--cases", cases] }
    if let timeout = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_TIMEOUT"] {
      arguments += ["--timeout", timeout]
    }
    if let photo = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_PHOTO"] {
      arguments += ["--photo", photo]
    }
    if ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_FAST_ONLY"] == "1" {
      arguments += ["--fast-only", "--profiles", package.appendingPathComponent("Sources/VocabCapture/Resources/MathTeachingReview/profiles.json").path,
        "--skill-index", package.appendingPathComponent("Sources/VocabCapture/Resources/MathSkills/index.json").path]
    }
    if ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_LEARNING"] == "1" { arguments += ["--learning-smoke"] }
    let result = try await Task.detached {
      let process = Process(), input = Pipe(), output = Pipe()
      process.executableURL = python; process.currentDirectoryURL = engine
      process.arguments = arguments; process.standardInput = input; process.standardOutput = output
      // stderr contains only case IDs, not provider exceptions or configuration.
      process.standardError = FileHandle.standardError
      var environment = ProcessInfo.processInfo.environment
      environment["LANGSMITH_TRACING"] = "false"; environment["LANGCHAIN_TRACING_V2"] = "false"
      process.environment = environment
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: bridge)
      try input.fileHandleForWriting.close()
      let response = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, response)
    }.value
    XCTAssertEqual(result.0, 0, String(decoding: result.1, as: UTF8.self))
    let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
    XCTAssertEqual(report["complete"] as? Bool, true)
    XCTAssertEqual(report["answer_accuracy_evaluated"] as? Bool, false)
    XCTAssertEqual(report["human_approval_granted"] as? Bool, false)
    let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
    XCTAssertFalse(cases.isEmpty)
    for row in cases {
      let lanes = ProcessInfo.processInfo.environment["MATH_TEACHING_LIVE_FAST_ONLY"] == "1"
        ? ["fast_selection"] : ["framework", "full_snapshot"]
      for lane in lanes {
        let attempt = try XCTUnwrap(row[lane] as? [String: Any])
        let metrics = try XCTUnwrap(attempt["metrics"] as? [String: Any])
        let execution = attempt["execution"] as? [String: Any]
        if execution?["mode"] as? String == "eligibility_gate" {
          XCTAssertEqual(metrics["model_calls"] as? Int, 0)
          XCTAssertEqual(metrics["cumulative_message_utf8_bytes"] as? Int, 0)
        } else {
          XCTAssertGreaterThan(try XCTUnwrap(metrics["model_calls"] as? Int), 0)
          XCTAssertGreaterThan(try XCTUnwrap(metrics["cumulative_message_utf8_bytes"] as? Int), 0)
          if lane == "fast_selection" { XCTAssertEqual(metrics["model_calls"] as? Int, 1) }
        }
      }
    }
    // Routing failures are evidence in the report. This integration test checks
    // completeness and real measurements, and does not certify model accuracy.
    print("Live teaching comparison: \(cases.count) cases; report \(reportURL.path)")
  }
}
