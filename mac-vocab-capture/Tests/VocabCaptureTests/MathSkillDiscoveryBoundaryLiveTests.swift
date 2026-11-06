import AppKit
import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import VocabCapture

/// Background discovery only: no foreground latency claim, library writes or human approval.
@MainActor
final class MathSkillDiscoveryBoundaryLiveTests: XCTestCase {
  struct Fixture: Decodable {
    struct Evidence: Decodable {
      let question_id: String
      let text: String
      let role: String
      let grade: Int
      let user_constraint: String
      let verification: String
      let image_file: String
      let answer: String?
    }
    let id: String
    let current_id: String
    let evidence: [Evidence]
    let expected_match_ids: [String]
    let expect_draft: Bool
    let source_kind: String
  }
  private struct Manifest: Decodable { let cases: [Fixture] }

  /// Checks the externally frozen grouping, rather than trusting a plausible pattern name.
  static func accepts(_ result: [String: Any], expectedIDs: Set<String>,
    suppliedIDs: Set<String>, expectDraft: Bool) -> Bool {
    guard result["human_decision"] == nil,
      let matched = result["pattern_evidence_ids"] as? [String],
      Set(matched).count == matched.count, Set(matched).isSubset(of: suppliedIDs),
      Set(matched) == expectedIDs,
      let status = result["status"] as? String,
      !["approved", "published", "rejected", "revision_required"].contains(status) else { return false }
    if !expectDraft {
      return result["proposal"] is NSNull && result["review"] is NSNull
        && ["observing", "covered"].contains(status)
    }
    guard status == "awaiting_human", result["coverage"] as? String == "uncovered",
      let draft = result["proposal"] as? [String: Any],
      let citations = draft["evidence_ids"] as? [String],
      Set(citations).count == citations.count, Set(citations) == expectedIDs,
      !(draft["instructions"] as? String ?? "").isEmpty,
      let review = result["review"] as? [String: Any],
      review["recommendation"] as? String == "needs_revision",
      let checks = review["checks"] as? [[String: Any]], checks.count == 5,
      Set(checks.compactMap { $0["dimension"] as? String }) == MathSkillLearningValidation.dimensions,
      let boundary = checks.first(where: { $0["dimension"] as? String == "counterexamples" }),
      let passed = boundary["passed"] as? NSNumber,
      CFGetTypeID(passed) == CFBooleanGetTypeID(), !passed.boolValue else { return false }
    return true
  }

  func testDiscoveryEvidenceKeepsOptionalOriginalModelAnswer() throws {
    let source: [String: Any] = ["question_id": "existing-question", "text": "原题OCR", "role": "positive", "grade": 4,
      "user_constraint": "不用方程", "verification": "unverified", "image_file": "original.png"]
    var withAnswer = source
    withAnswer["answer"] = "未核验的原始模型回答"
    let encoder = { (value: [String: Any]) throws in try JSONSerialization.data(withJSONObject: value) }
    XCTAssertNil(try JSONDecoder().decode(Fixture.Evidence.self, from: encoder(source)).answer)
    XCTAssertEqual(try JSONDecoder().decode(Fixture.Evidence.self, from: encoder(withAnswer)).answer, "未核验的原始模型回答")
  }

  func testGroupingOracleRejectsBroadMatchesLostPositivesAndUnjustifiedApproval() {
    let supplied = Set(["ones-nines", "ascending-eight", "nines-factor"])
    var result: [String: Any] = ["pattern_key": "multiplication-pattern-by-digit-arrangement",
      "pattern_evidence_ids": ["ones-nines"], "status": "observing", "proposal": NSNull(), "review": NSNull()]
    XCTAssertTrue(Self.accepts(result, expectedIDs: ["ones-nines"], suppliedIDs: supplied, expectDraft: false))
    result["pattern_evidence_ids"] = supplied.sorted()
    XCTAssertFalse(Self.accepts(result, expectedIDs: ["ones-nines"], suppliedIDs: supplied, expectDraft: false))
    result["pattern_evidence_ids"] = ["ones-nines", "fabricated"]
    XCTAssertFalse(Self.accepts(result, expectedIDs: ["ones-nines"], suppliedIDs: supplied, expectDraft: false))
    result["pattern_evidence_ids"] = ["ones-nines"]
    XCTAssertFalse(Self.accepts(result, expectedIDs: supplied, suppliedIDs: supplied, expectDraft: true))
    result["pattern_evidence_ids"] = supplied.sorted()
    result["coverage"] = "uncovered"
    result["status"] = "awaiting_human"
    result["proposal"] = ["evidence_ids": supplied.sorted(), "instructions": "A shared full algorithm pending human review"]
    let checks = MathSkillLearningValidation.dimensions.sorted().map {
      ["dimension": $0, "passed": $0 != "counterexamples", "reason": "Unverified test fixture"] as [String: Any]
    }
    result["review"] = ["checks": checks, "recommendation": "needs_revision"]
    XCTAssertTrue(Self.accepts(result, expectedIDs: supplied, suppliedIDs: supplied, expectDraft: true))
    result["pattern_evidence_ids"] = ["ones-nines", "ascending-eight"]
    XCTAssertFalse(Self.accepts(result, expectedIDs: supplied, suppliedIDs: supplied, expectDraft: true))
    result["pattern_evidence_ids"] = supplied.sorted()
    result["review"] = ["checks": checks.map { ["dimension": $0["dimension"]!, "passed": true] }, "recommendation": "ready_for_human"]
    XCTAssertFalse(Self.accepts(result, expectedIDs: supplied, suppliedIDs: supplied, expectDraft: true))
    result["status"] = "approved"
    XCTAssertFalse(Self.accepts(result, expectedIDs: supplied, suppliedIDs: supplied, expectDraft: true))
  }

  func testConfiguredProviderDiscoveryBoundaries() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let output = environment["MATH_DISCOVERY_BOUNDARY_ARTIFACTS"],
      let fixturePath = environment["MATH_DISCOVERY_BOUNDARY_FIXTURES"],
      let profileName = environment["MATH_DISCOVERY_BOUNDARY_PROFILE"],
      let executable = environment["MATH_DISCOVERY_BOUNDARY_ENGINE"] else {
      throw XCTSkip("Requires explicit discovery boundary fixtures, profile, installed helper and artifact directory")
    }
    let root = URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    XCTAssertTrue((1...8).contains(manifest.cases.count))
    guard (1...8).contains(manifest.cases.count) else { return }
    var caseIDs = Set<String>()
    var inputs: [(Fixture, Data)] = []
    for fixture in manifest.cases {
      XCTAssertNotNil(fixture.id.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression))
      let uniqueCase = caseIDs.insert(fixture.id).inserted
      XCTAssertTrue(uniqueCase)
      let ids = fixture.evidence.map(\.question_id)
      guard uniqueCase, fixture.id.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
        Set(ids).count == ids.count, (3...24).contains(ids.count),
        ids.first == fixture.current_id, Set(fixture.expected_match_ids).count == fixture.expected_match_ids.count,
        Set(fixture.expected_match_ids).isSubset(of: Set(ids)), !fixture.source_kind.isEmpty else {
        XCTFail("Invalid frozen discovery fixture contract"); return
      }
      var evidence: [[String: Any]] = [], originals: [[String: String]] = []
      for source in fixture.evidence {
        let file = root.appendingPathComponent(source.image_file).standardizedFileURL.resolvingSymlinksInPath()
        guard !source.image_file.hasPrefix("/"), file.path.hasPrefix(root.path + "/"),
          file.pathExtension.lowercased() == "png", source.role == "positive", source.grade == 4,
          source.verification == "unverified", !source.text.isEmpty else {
          XCTFail("Fixtures must preserve unverified original positive photographs"); return
        }
        let photo = try Data(contentsOf: file)
        guard NSBitmapImageRep(data: photo) != nil else { XCTFail("Invalid original image"); return }
        evidence.append(["question_id": source.question_id, "text": source.text, "role": source.role,
          "grade": source.grade, "user_constraint": source.user_constraint, "verification": source.verification,
          "answer": source.answer ?? "", "reference_answer": ""])
        originals.append(["question_id": source.question_id, "image_data": photo.base64EncodedString()])
      }
      inputs.append((fixture, try JSONSerialization.data(withJSONObject:
        ["evidence": evidence, "existing_patterns": [], "originals": originals], options: [.sortedKeys])))
    }
    guard FileManager.default.isExecutableFile(atPath: executable) else { XCTFail("Installed helper is unavailable"); return }
    let catalogue = try MathSkillCatalogue.load()
    XCTAssertEqual(catalogue.skills.count, 49)
    guard catalogue.skills.count == 49 else { return }
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: $0.version,
      title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date(timeIntervalSince1970: 0)) }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      let authentication = LAContext()
      authentication.interactionNotAllowed = true
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture",
        kSecAttrAccount: id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)",
        kSecReturnData: true, kSecUseAuthenticationContext: authentication]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return "" }
      return String(decoding: data, as: UTF8.self)
    })
    let profile = try XCTUnwrap(preferences.profiles.first { $0.name == profileName }, "Exact existing profile is required")
    let configuration = preferences.configuration(for: profile.id)
    guard !configuration.apiKey.isEmpty else { throw XCTSkip("Configured credentials unavailable without interaction; no provider request sent") }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: executable)))
    var observations: [[String: Any]] = []
    func sanitize(_ value: Any) -> Any {
      if let string = value as? String {
        var safe = string
        for secret in [configuration.apiKey, configuration.baseURL] where !secret.isEmpty {
          safe = safe.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return safe.replacingOccurrences(of: "https?://[^\\s\\\"<>]+", with: "<redacted-url>", options: .regularExpression)
      }
      if let list = value as? [Any] { return list.map(sanitize) }
      if let object = value as? [String: Any] {
        return object.filter { !["api_key", "base_url", "image_data"].contains($0.key) }.mapValues(sanitize)
      }
      return value
    }
    func writeReport() throws {
      let report: [String: Any] = ["scope": "background learning; no foreground latency claim", "profile": profileName,
        "catalogue_count": methods.count, "planned_cases": inputs.count, "completed_cases": observations.count,
        "manifest_sha256": SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent("manifest.json"))).map { String(format: "%02x", $0) }.joined(),
        "production_writes": false, "human_approval": false, "outer_calls_per_case": 1, "observations": observations,
        "engine_sha256": SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable))).map { String(format: "%02x", $0) }.joined(),
        "acceptance_passed": observations.count == inputs.count && observations.allSatisfy { $0["acceptance_passed"] as? Bool == true }]
      try JSONSerialization.data(withJSONObject: sanitize(report), options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("report.json"), options: .atomic)
    }
    try writeReport()
    for (fixture, learning) in inputs {
      let started = ProcessInfo.processInfo.systemUptime
      var observation: [String: Any] = ["case": fixture.id, "source_kind": fixture.source_kind,
        "expected_match_ids": fixture.expected_match_ids.sorted(), "expect_draft": fixture.expect_draft,
        "acceptance_passed": false]
      do {
        let response = try await client.learnSkills(learning: learning, imageData: Data(), methods: methods,
          configuration: configuration, api: profile.api, directConnection: profile.directConnection)
        guard let result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] else {
          throw ScreenshotQuestionError.invalidResponse
        }
        var validNativeProtocol = false
        do {
          try MathSkillLearningValidation.validate(result, allowedMethodIDs: Set(methods.map(\.id)),
            allowLegacyWithoutCheckpoint: false)
          validNativeProtocol = true
        } catch { /* Retain sanitized returned data as failed evidence, never as an approved report. */ }
        observation["native_protocol_valid"] = validNativeProtocol
        observation["result"] = result
        observation["actual_match_ids"] = result["pattern_evidence_ids"] ?? NSNull()
        observation["reason"] = result["reason"] ?? NSNull()
        observation["model_calls"] = ((result["workflow_state"] as? [String: Any])?["state"] as? [String: Any])?["model_calls"] ?? NSNull()
        observation["acceptance_passed"] = validNativeProtocol && Self.accepts(result, expectedIDs: Set(fixture.expected_match_ids),
          suppliedIDs: Set(fixture.evidence.map(\.question_id)), expectDraft: fixture.expect_draft)
        try JSONSerialization.data(withJSONObject: sanitize(result), options: [.sortedKeys, .prettyPrinted])
          .write(to: destination.appendingPathComponent(fixture.id + "-result.json"), options: .atomic)
      } catch {
        observation["failure_category"] = "transport_protocol_or_artifact_failure"
        observation["arbitrary_error_recorded"] = false
      }
      observation["wall_seconds"] = ProcessInfo.processInfo.systemUptime - started
      observations.append(observation)
      do { try writeReport() } catch { XCTFail("Unable to save sanitized boundary report") }
      XCTAssertEqual(observation["acceptance_passed"] as? Bool, true, "Frozen discovery boundary failed: \(fixture.id)")
    }
    await client.shutdown()
  }
}
