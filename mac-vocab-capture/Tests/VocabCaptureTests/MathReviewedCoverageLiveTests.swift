import CryptoKit
import LocalAuthentication
import Security
import XCTest

@testable import VocabCapture

/// One opt-in coverage request against a copied real library. Never fabricates a review.
@MainActor
final class MathReviewedCoverageLiveTests: XCTestCase {
  func testFinalAnswerReviewedOriginalUsesExistingDifferenceSkillWithoutPublishing() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["MATH_REVIEWED_COVERAGE_DIRECTORY"],
      let enginePath = environment["MATH_REVIEWED_COVERAGE_ENGINE"],
      let outputPath = environment["MATH_REVIEWED_COVERAGE_OUTPUT"] else {
      throw XCTSkip("Requires an explicit copied library, source engine and fresh artifact directory")
    }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: outputPath, isDirectory: true).resolvingSymlinksInPath()
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
    func isolated(_ url: URL) -> Bool {
      url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/") || url.path.hasPrefix(temporary.path + "/")
    }
    guard isolated(directory), isolated(output), !output.path.hasPrefix(directory.path + "/"),
      directory != output, FileManager.default.fileExists(atPath: directory.appendingPathComponent("questions.sqlite").path),
      !FileManager.default.fileExists(atPath: output.path), FileManager.default.isExecutableFile(atPath: enginePath) else {
      XCTFail("Use an existing temporary library copy, executable helper, and a fresh separate temporary output directory")
      return
    }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      let authentication = LAContext()
      authentication.interactionNotAllowed = true
      let account = id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)"
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account,
        kSecReturnData: true, kSecUseAuthenticationContext: authentication]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let bytes = result as? Data else { return "" }
      return String(decoding: bytes, as: UTF8.self)
    })
    let profile = try XCTUnwrap(preferences.profiles.first { $0.name == "deepseek-flash" },
      "Requires the existing deepseek-flash profile; no automatic fallback")
    let configuration = preferences.configuration(for: profile.id)
    guard configuration.isComplete else {
      throw XCTSkip("Existing DeepSeek credentials unavailable; no interaction or provider request sent")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let store = MathQuestionStore(directory: directory)
    let client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: enginePath)))
    var summary: [String: Any] = ["profile": profile.name, "model": configuration.model,
      "native_requests": 0, "outer_retries": 0, "production_writes": false,
      "human_decision_written": false, "scope": "existing skill coverage of one real final-answer-reviewed original; not new skill publication"]
    func saveSummary() throws {
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("summary.json"), options: .atomic)
    }
    do {
      let id = "A6DA1825-9CDE-4402-89AA-7210148E983C"
      let snapshot = try await store.learningSnapshot(questionID: id)
      let finalOnly = snapshot.solutions.contains { solution in
        guard solution.verificationStatus == "confirmed",
          let review = snapshot.reviews.last(where: { $0.solutionID == solution.id }) else { return false }
        return review.status == "confirmed" && review.scope != "答案及解题过程"
      }
      guard finalOnly else {
        XCTFail("Copied source must contain the real final-answer-only user review; never create one in this probe")
        await store.close(); await client.shutdown(); return
      }
      let evidence = MathSkillLearningValidation.backgroundEvidence(snapshot)
      guard evidence["verification"] as? String == "unverified" else {
        XCTFail("Answer-only probe must not submit process-confirmed evidence")
        await store.close(); await client.shutdown(); return
      }
      let methods = try await store.automaticMethods()
      let expected = "markdown-e14ff12fca2a06626ace5bd71275820060bcdae8f28550f59137c78b1f92eb00"
      guard methods.contains(where: { $0.id == expected }) else {
        XCTFail("Copied complete active catalogue must contain the existing difference-and-ratio skill")
        await store.close(); await client.shutdown(); return
      }
      let image = try await store.originalImage(questionID: id)
      let learning = try JSONSerialization.data(withJSONObject: ["evidence": [evidence], "existing_patterns": []], options: [.sortedKeys])
      try JSONEncoder().encode(snapshot).write(to: output.appendingPathComponent("source-snapshot.json"), options: .atomic)
      try image.write(to: output.appendingPathComponent("original.png"), options: .atomic)
      summary["question_id"] = id
      summary["method_count"] = methods.count
      summary["original_sha256"] = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
      summary["snapshot_has_final_answer_only_confirmation"] = finalOnly
      summary["learning_process_verification"] = evidence["verification"]
      summary["native_requests"] = 1
      let start = ProcessInfo.processInfo.systemUptime
      let report: String
      do {
        report = try await client.learnSkills(learning: learning, imageData: image, methods: methods,
          configuration: configuration, api: profile.api, directConnection: profile.directConnection)
      } catch {
        summary["request_seconds"] = ProcessInfo.processInfo.systemUptime - start
        summary["failure"] = "provider_or_protocol_failure"
        try saveSummary()
        await store.close(); await client.shutdown()
        XCTFail("Single coverage request failed; fixed diagnostics saved without provider error text")
        return
      }
      summary["request_seconds"] = ProcessInfo.processInfo.systemUptime - start
      try report.write(to: output.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
      try MathSkillLearningValidation.validate(object, sourceSnapshots: [snapshot], allowedMethodIDs: Set(methods.map(\.id)), allowLegacyWithoutCheckpoint: false)
      let state = (object["workflow_state"] as? [String: Any])?["state"] as? [String: Any]
      summary["model_calls"] = state?["model_calls"]
      summary["coverage"] = object["coverage"]
      summary["covered_method_ids"] = object["covered_method_ids"]
      XCTAssertEqual(object["coverage"] as? String, "covered")
      XCTAssertTrue((object["covered_method_ids"] as? [String] ?? []).contains(expected))
      XCTAssertTrue(object["proposal"] is NSNull)
      XCTAssertNil(object["human_decision"])
      XCTAssertNil(state?["human_decision"])
      let afterSnapshot = try await store.learningSnapshot(questionID: id)
      XCTAssertEqual(afterSnapshot, snapshot)
      summary["acceptance_passed"] = object["coverage"] as? String == "covered"
        && (object["covered_method_ids"] as? [String] ?? []).contains(expected)
        && object["proposal"] is NSNull && object["human_decision"] == nil && state?["human_decision"] == nil
      try saveSummary()
      await store.close(); await client.shutdown()
    } catch {
      summary["failure"] = "source_or_validation_failure"
      try? saveSummary()
      await store.close(); await client.shutdown()
      XCTFail("Copied-source coverage validation failed; provider details are not printed")
    }
  }
}
