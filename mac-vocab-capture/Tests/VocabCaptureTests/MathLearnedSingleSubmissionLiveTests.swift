import AppKit
import CryptoKit
import PDFKit
import Security
import LocalAuthentication
import XCTest
@testable import VocabCapture

/// Explicit real-provider probe. The restored approval is an old isolated human-action
/// fixture, never approval of user data. This tests enrichment, not ordinary grade four.
@MainActor
final class MathLearnedSingleSubmissionLiveTests: XCTestCase {
  private enum ProbeFailure: Error { case acceptance, deadline, provider }

  func testRestoredLearnedVersionSingleSubmissionAndRevocation() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["MATH_LEARNED_SINGLE_CALL_ARTIFACTS"],
      let executable = env["MATH_LEARNED_SINGLE_CALL_ENGINE"] else {
      throw XCTSkip("Requires explicit isolated learned single-call live configuration")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
    // Require a new directory: no existing library or old evidence can be overwritten.
    guard !FileManager.default.fileExists(atPath: destination.path),
      destination.path.hasPrefix("/tmp/") || destination.path.hasPrefix("/private/tmp/") else {
      throw XCTSkip("Live artifacts must use a new isolated temporary directory")
    }
    let backup = URL(fileURLWithPath: env["MATH_LEARNED_SINGLE_CALL_BACKUP"] ?? "/tmp/math-packaged105-learning-20261013/published-backup", isDirectory: true).standardizedFileURL
    guard backup.path.hasPrefix("/tmp/") || backup.path.hasPrefix("/private/tmp/"),
      FileManager.default.fileExists(atPath: backup.appendingPathComponent("questions.sqlite").path),
      FileManager.default.isExecutableFile(atPath: executable) else {
      throw XCTSkip("Requires the prior isolated approved backup and an executable helper")
    }
    let configurationStarted = ProcessInfo.processInfo.systemUptime
    let model = try configuredModel(environment: env)
    let configurationSeconds = ProcessInfo.processInfo.systemUptime - configurationStarted
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let copiedBackup = destination.appendingPathComponent("restored-fixture-source")
    try FileManager.default.copyItem(at: backup, to: copiedBackup)
    let arguments = env["MATH_LEARNED_SINGLE_CALL_SOURCE"].map { [$0] } ?? []
    let client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: executable), arguments: arguments))
    let directory = destination.appendingPathComponent("isolated-library")
    let store = MathQuestionStore(directory: directory)
    var reopenedStore: MathQuestionStore?
    let suite = "MathLearnedSingleSubmission." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var observations: [[String: Any]] = []
    var phase = "restoring_isolated_human_action_fixture"
    var report: [String: Any] = [
      "scope": "real provider; new synthetic original; restored isolated test approval; elementary enrichment only",
      "real_user_approval": false, "production_writes": false,
      "configuration_resolution_seconds": configurationSeconds,
      "ordinary_grade_four_certified": false, "discovery_rerun": false,
      "isolated_backup": backup.path,
      "single_submission": true, "renderer_tools": true, "acceptance_passed": false,
      "engine_kind": arguments.isEmpty ? "packaged" : "source",
      "engine_executable_sha256": try hash(Data(contentsOf: URL(fileURLWithPath: executable)))
    ]
    let nativeSources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VocabCapture")
    report["ui_source_hashes"] = try Dictionary(uniqueKeysWithValues:
      ["ScreenshotQuestionPanel.swift", "MathLocalSkillRetrieval.swift", "MathStructuredSolution.swift"].map {
        ($0, try hash(Data(contentsOf: nativeSources.appendingPathComponent($0))))
      })
    func writeReport() throws {
      report["phase"] = phase
      report["observations"] = observations
      try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("report.json"), options: .atomic)
    }
    if let source = arguments.first {
      let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: source).deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix("test_") }
      report["engine_source_hashes"] = try Dictionary(uniqueKeysWithValues: files.map {
        ($0.lastPathComponent, try hash(Data(contentsOf: $0)))
      })
    }
    try writeReport()
    do {
      _ = try await store.restoreBackup(from: copiedBackup)
      let methods = try await store.automaticMethods()
      let catalogue = try MathSkillCatalogue.load()
      let builtinIDs = Set(catalogue.skills.map(\.sourceID))
      try require(catalogue.skills.count == 49 && methods.count == 50)
      try require(builtinIDs.isSubset(of: Set(methods.map(\.id))))
      let learned = try XCTUnwrap(methods.filter { !builtinIDs.contains($0.id) }.only)
      let snapshots = try await store.projectSkillSnapshots(versionID: learned.versionID)
      let snapshot = try XCTUnwrap(snapshots.only)
      try require(snapshot.automaticEligible && snapshot.profile?.status == "approved")
      let oldQuestions = try await store.list()
      let oldIDs = Set(oldQuestions.map(\.id))
      report["restored_method_id"] = learned.id
      report["restored_version_id"] = learned.versionID
      report["instructions_sha256"] = hash(Data(learned.instructions.utf8))
      report["automatic_method_count"] = methods.count
      let request = "小学四年级，明确允许拓展方法，不使用方程。请参照原图，使用适用方法并逐边验算；末尾单独一行写‘最终路径：E→F→…’，用实际点名替代示例，不要在这一行写其他文字。"
      try require(MathMethodMatcher.eligibleMethods(methods, question: request).contains(learned))
      try require(!MathMethodMatcher.eligibleMethods(methods, question: "小学四年级，不用方程，不允许拓展").contains(learned))
      let project = destination.appendingPathComponent("isolated-project")
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      let sync = MathSkillProjectSyncCoordinator(store: store, defaults: defaults)
      try sync.selectProject(project)
      await sync.synchronize()
      let artifact = try MathSkillProjectArtifact(snapshot: snapshot)
      let artifactDirectory = project.appendingPathComponent(artifact.relativePath)
      try verifyProject(artifact: artifact, directory: artifactDirectory, learned: learned)
      let edges = ["EF", "FG", "GH", "HI", "IE", "EG"]
      try require(Self.oddVertices(edges) == Set(["E", "G"]))
      try require(Self.validTrail(["E", "F", "G", "H", "I", "E", "G"], edges: edges))
      let original = try photo(edges: edges)
      for historical in oldQuestions {
        let historicalPhoto = try await store.originalImage(questionID: historical.id)
        try require(historicalPhoto != original)
      }
      report["original_is_new_evidence"] = true
      try original.write(to: destination.appendingPathComponent("unseen-original.png"))
      phase = "solving_unseen_original"
      try writeReport()
      let firstID = try await solve(label: "before-revocation", store: store, client: client,
        model: model, defaults: defaults, photo: original, request: request,
        learned: learned, expectedReuse: true, destination: destination, observations: &observations)
      try require(!oldIDs.contains(firstID))
      await store.close()
      let reopened = MathQuestionStore(directory: directory)
      reopenedStore = reopened
      let answers = try await reopened.solutions(questionID: firstID)
      let saved = try XCTUnwrap(answers.only)
      try require(saved.method == learned && saved.verificationStatus == "unverified")
      try require(saved.selectionFailure == nil && saved.diagramFailure == nil)
      try require(try await reopened.originalImage(questionID: firstID) == original)
      let trail = try returnedTrail(saved.answer)
      try require(Self.validTrail(trail, edges: edges))
      report["returned_path"] = trail
      report["independent_path_passed"] = true
      let records = try await reopened.list()
      let record = try XCTUnwrap(records.first { $0.id == firstID })
      let pdf = destination.appendingPathComponent("before-revocation.pdf")
      let pages = try await MathQuestionPDFExporter.export(records: [record], store: reopened, to: pdf, options: .init(includeSolutions: true))
      let pdfText = try XCTUnwrap(PDFDocument(url: pdf)?.string)
      try require(pages > 1 && pdfText.contains("参考方法建议（未确认采用）：\(learned.title)")
        && pdfText.contains("尚未核验") && pdfText.contains("最终路径") && !pdfText.contains("用户已确认"))
      try JSONEncoder().encode(answers).write(to: destination.appendingPathComponent("history-before-revocation.json"))
      phase = "revoking_only_isolated_fixture"
      try writeReport()
      try await reopened.revokeSkillMethod(versionID: learned.versionID,
        note: "ISOLATED TEST HUMAN ACTION ONLY: revoke restored test-fixture approval for future reuse; preserve historical answer")
      let future = try await reopened.automaticMethods()
      try require(future.count == 49 && !future.contains { $0.id == learned.id })
      phase = "solving_after_revocation"
      try writeReport()
      let secondID = try await solve(label: "after-revocation", store: reopened, client: client,
        model: model, defaults: defaults, photo: original, request: request,
        learned: learned, expectedReuse: false, destination: destination, observations: &observations)
      try require(firstID != secondID && !oldIDs.contains(secondID))
      let secondAnswers = try await reopened.solutions(questionID: secondID)
      let second = try XCTUnwrap(secondAnswers.only)
      try require(second.method?.id != learned.id && !second.visualMethods.contains { $0.id == learned.id })
      try require(second.verificationStatus == "unverified")
      try require(Self.validTrail(try returnedTrail(second.answer), edges: edges))
      let historical = try await reopened.solutions(questionID: firstID)
      try require(historical == answers)
      try JSONEncoder().encode(historical).write(to: destination.appendingPathComponent("history-after-revocation.json"))
      let afterPDF = destination.appendingPathComponent("historical-after-revocation.pdf")
      _ = try await MathQuestionPDFExporter.export(records: [record], store: reopened, to: afterPDF, options: .init(includeSolutions: true))
      try require(PDFDocument(url: afterPDF)?.string == pdfText)
      let revokedSync = MathSkillProjectSyncCoordinator(store: reopened, defaults: defaults)
      await revokedSync.synchronize()
      try verifyProject(artifact: artifact, directory: artifactDirectory, learned: learned)
      let revokedSnapshots = try await reopened.projectSkillSnapshots(versionID: learned.versionID)
      let revokedSnapshot = try XCTUnwrap(revokedSnapshots.only)
      try require(!revokedSnapshot.automaticEligible && revokedSnapshot.method == learned)
      let revokedArtifact = try MathSkillProjectArtifact(snapshot: revokedSnapshot)
      try verifyProject(artifact: revokedArtifact, directory: project.appendingPathComponent(revokedArtifact.relativePath), learned: learned)
      report["project_historical_exact_version_preserved"] = true
      report["project_revoked_snapshot_ineligible"] = true
      report["history_and_pdf_text_unchanged"] = true
      report["new_question_ids"] = [firstID, secondID]
      report["pdf_pages"] = pages
      report["quality_lifecycle_passed"] = true
      report["speed_target_met"] = observations.allSatisfy { $0["speed_target_met"] as? Bool == true }
      report["acceptance_passed"] = report["speed_target_met"]
      phase = "completed"
      try writeReport()
      await reopened.close()
      await client.shutdown()
    } catch {
      report["acceptance_passed"] = false
      report["partial_failure"] = "Live acceptance did not complete at the recorded phase"
      report["raw_error_recorded"] = false
      try? writeReport()
      await store.close()
      if let reopenedStore { await reopenedStore.close() }
      await client.shutdown()
      // Never bubble a raw provider error (which may contain request details) to XCTest.
      throw ProbeFailure.acceptance
    }
  }

  private func solve(label: String, store: MathQuestionStore, client: ScreenshotQuestionClient,
    model: MathTagModelConfiguration, defaults: UserDefaults, photo: Data, request: String,
    learned: MathTeachingMethod, expectedReuse: Bool, destination: URL,
    observations: inout [[String: Any]]) async throws -> String {
    var calls = 0, selectors = 0
    var exactBody = false, exactID = false
    var requestHandle: String?
    var requestSeconds: TimeInterval = 0
    var usage: ScreenshotQuestionUsage?
    var submissionIssue: String?
    var providerErrorType: String?
    var providerStatus: Int?
    var providerCategory: String?
    var providerFields: [String]?
    let started = Date()
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, context, history, partial in
        calls += 1
        exactBody = prompt.contains(learned.instructions)
        exactID = prompt.contains(learned.id)
        let pattern = #"(?m)^id:(m*\d+)\nroles:solution\n名称："#
          + NSRegularExpression.escapedPattern(for: learned.title) + "\n全文：\n"
        let expression = try NSRegularExpression(pattern: pattern)
        if let match = expression.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
          let range = Range(match.range(at: 1), in: prompt) { requestHandle = String(prompt[range]) }
        else { requestHandle = nil }
        try self.require(calls == 1 && context.imageData == photo)
        try self.require(exactBody == expectedReuse && (requestHandle != nil) == expectedReuse)
        try prompt.write(to: destination.appendingPathComponent(label + "-prompt.txt"), atomically: true, encoding: .utf8)
        let requestStarted = Date()
        defer { requestSeconds = Date().timeIntervalSince(requestStarted) }
        let result: String
        do {
          result = try await client.answer(question: prompt, context: context, history: history,
            configuration: model.configuration, api: model.api, thinking: .off,
            directConnection: model.directConnection, onUsage: { usage = $0 }, onPartial: partial)
        } catch {
          providerErrorType = String(reflecting: type(of: error))
          if let diagnostic = error as? MathProviderRequestError {
            providerStatus = diagnostic.status; providerCategory = "http"; providerFields = diagnostic.fields
          }
          if let typed = error as? ScreenshotQuestionError {
            switch typed {
            case .server(let status): providerStatus = status; providerCategory = "http"
            case .invalidConfiguration: providerCategory = "configuration"
            case .unsupportedThinking: providerCategory = "thinking"
            case .invalidImage: providerCategory = "image"
            case .truncatedResponse: providerCategory = "truncated"
            case .emptyResponse: providerCategory = "empty"
            default: providerCategory = "response"
            }
          }
          submissionIssue = (error as? MathSolutionSubmissionError)?.issue
          throw ProbeFailure.provider
        }
        try result.write(to: destination.appendingPathComponent(label + "-response.txt"), atomically: true, encoding: .utf8)
        return result
      }, interfaceDefaults: defaults, originalImageData: photo,
      saveQuestion: { try await store.save($0) }, solutionModel: { model.configuration.model },
      mathStore: store, selectMethodAutomatically: { _, _, _ in
        selectors += 1
        XCTFail("Single-pass must never invoke a separate provider selector")
        throw ProbeFailure.acceptance
      }, singlePassAutomaticMethods: true, programArithmetic: true,
      singleSubmissionMath: true, rendererToolsMath: true)
    defer {
      observations.append(["case": label, "solver_calls": calls, "selector_calls": selectors,
        "candidate_exact_body": exactBody, "candidate_exact_id": exactID,
        "candidate_request_handle": requestHandle as Any? ?? NSNull(),
        "expected_learned_candidate": expectedReuse, "request_seconds": requestSeconds,
        "total_seconds": Date().timeIntervalSince(started),
        "user_answer_seconds": panel.performance?.elapsed as Any? ?? NSNull(),
        "preparation_seconds": panel.singlePassPreparationDurations,
        "engine_timings": usage?.engineTimings ?? [:],
        "speed_target_met": !panel.isAnswering && panel.history.count == 1 && providerErrorType == nil && (panel.performance?.elapsed ?? .infinity) <= 5,
        "input_tokens": usage?.inputTokens as Any? ?? NSNull(),
        "output_tokens": usage?.outputTokens as Any? ?? NSNull(),
        "answer_completed": !panel.isAnswering && panel.history.count == 1,
        "saved_question_id": panel.savedQuestionID as Any? ?? NSNull()])
      if let submissionIssue { observations[observations.count - 1]["submission_issue"] = submissionIssue }
      if let providerErrorType { observations[observations.count - 1]["provider_error_type"] = providerErrorType }
      if let providerStatus { observations[observations.count - 1]["provider_status"] = providerStatus }
      if let providerCategory { observations[observations.count - 1]["provider_category"] = providerCategory }
      if let providerFields { observations[observations.count - 1]["provider_fields"] = providerFields }
      panel.close()
    }
    panel.present()
    let controls = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = request
    try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering }
    try require(calls == 1 && selectors == 0 && panel.history.count == 1)
    // Full identity and immutable version are checked on the stored adoption
    // below. Wire handles intentionally replace the long source ID.
    try require(exactBody == expectedReuse && (requestHandle != nil) == expectedReuse)
    try require(panel.singlePassPreparationDurations["sourceIndex"] != nil)
    for text in views(try XCTUnwrap(panel.contentView)).compactMap({ $0 as? NSTextView }) {
      try require(!text.string.contains("图解未生成"))
    }
    try XCTUnwrap(views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let solutions = try await store.solutions(questionID: id)
    let saved = try XCTUnwrap(solutions.only)
    try require(expectedReuse ? saved.method == learned : saved.method?.id != learned.id)
    try require(saved.selectionFailure == nil && saved.diagramFailure == nil)
    let view = try XCTUnwrap(panel.contentView)
    let capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: capture)
    try XCTUnwrap(capture.representation(using: .png, properties: [:]))
      .write(to: destination.appendingPathComponent(label + "-panel.png"))
    return id
  }

  private func configuredModel(environment: [String: String]) throws -> MathTagModelConfiguration {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let allowKeychainInteraction = environment["MATH_LEARNED_SINGLE_CALL_KEYCHAIN_INTERACTION"] == "1"
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      let authentication = LAContext()
      authentication.interactionNotAllowed = !allowKeychainInteraction
      let account = id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)"
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account,
        kSecReturnData: true, kSecUseAuthenticationContext: authentication]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return "" }
      return String(decoding: data, as: UTF8.self)
    })
    let profile = try environment["MATH_LEARNED_SINGLE_CALL_PROFILE"].map { name in
      try XCTUnwrap(preferences.profiles.first { $0.name == name })
    }
    let fallback = defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? .init(baseURL: "", model: "", apiKey: "")
    let configuration = profile.map { preferences.configuration(for: $0.id) }
      ?? preferences.configuration(fallingBackTo: fallback)
    guard !configuration.apiKey.isEmpty else { throw XCTSkip("Configured credential unavailable; no request sent") }
    return .init(configuration: configuration, api: profile?.api ?? preferences.selectedAPI,
      directConnection: profile?.directConnection ?? preferences.selectedDirectConnection)
  }

  private func verifyProject(artifact: MathSkillProjectArtifact, directory: URL, learned: MathTeachingMethod) throws {
    try artifact.verify(at: directory)
    let method = try JSONDecoder().decode(MathTeachingMethod.self,
      from: Data(contentsOf: directory.appendingPathComponent(artifact.name + "/references/method.json")))
    try require(method == learned)
    let skills = try MathSkillCatalogue(directory: directory)
    try require(skills.skills.count == 1)
    try require(try XCTUnwrap(skills.skills.first).instructions.hasPrefix("# \(learned.title)\n\n" + learned.instructions + "\n\n"))
  }

  private func returnedTrail(_ answer: String) throws -> [String] {
    let expression = try NSRegularExpression(pattern: #"(?m)^\s*(?:\*\*)?最终路径\s*[:：]\s*([E-I](?:\s*→\s*[E-I])+)(?:\*\*)?\s*[。．]?\s*$"#)
    let matches = expression.matches(in: answer, range: NSRange(answer.startIndex..., in: answer))
    try require(matches.count == 1)
    let match = try XCTUnwrap(matches.first)
    let range = try XCTUnwrap(Range(match.range(at: 1), in: answer))
    return answer[range].components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func oddVertices(_ edges: [String]) -> Set<String> {
    var degrees: [String: Int] = [:]
    for edge in edges { for point in edge.map(String.init) { degrees[point, default: 0] += 1 } }
    return Set(degrees.filter { $0.value % 2 == 1 }.map(\.key))
  }

  private static func validTrail(_ trail: [String], edges: [String]) -> Bool {
    guard trail.count == edges.count + 1 else { return false }
    var remaining = edges.map { $0.map(String.init).sorted().joined() }
    for pair in zip(trail, trail.dropFirst()) {
      let edge = [pair.0, pair.1].sorted().joined()
      guard let index = remaining.firstIndex(of: edge) else { return false }
      remaining.remove(at: index)
    }
    return remaining.isEmpty
  }

  private func photo(edges: [String]) throws -> Data {
    let image = NSImage(size: NSSize(width: 1150, height: 510))
    image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1150, height: 510).fill()
    let text = "小学拓展一笔画：五点E、F、G、H、I。\n边为EF、FG、GH、HI、IE、EG。\n不抬笔，每条边只画一次，能否画完？请给出完整路径。"
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 29), .foregroundColor: NSColor.black])
      .draw(in: NSRect(x: 30, y: 360, width: 1090, height: 120))
    var positions: [String: NSPoint] = [:]
    for (index, point) in ["E", "F", "G", "H", "I"].enumerated() {
      let angle = CGFloat(index) * 2 * .pi / 5 + .pi / 2
      positions[point] = NSPoint(x: 575 + 155 * cos(angle), y: 185 + 135 * sin(angle))
    }
    NSColor.black.setStroke()
    for edge in edges {
      let points = edge.map(String.init)
      let line = NSBezierPath(); line.lineWidth = 3
      line.move(to: positions[points[0]]!); line.line(to: positions[points[1]]!); line.stroke()
    }
    for (label, point) in positions {
      NSColor.black.setFill()
      NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
      NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.black])
        .draw(at: NSPoint(x: point.x + 10, y: point.y + 5))
    }
    image.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  private func require(_ condition: Bool) throws {
    XCTAssertTrue(condition, "Isolated live acceptance requirement failed")
    guard condition else { throw ProbeFailure.acceptance }
  }
  private func settle(_ condition: () -> Bool) async throws {
    for _ in 0..<1800 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw ProbeFailure.deadline
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

private extension Array {
  var only: Element? { count == 1 ? first : nil }
}
