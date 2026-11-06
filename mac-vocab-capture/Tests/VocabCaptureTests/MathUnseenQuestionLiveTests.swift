import AppKit
import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import VocabCapture

/// Photo-only, one-attempt evidence collection. Mathematical quality is reviewed
/// against the separately frozen task, never against truth supplied to the model.
@MainActor
final class MathUnseenQuestionLiveTests: XCTestCase {
  private struct Manifest: Codable {
    struct Item: Codable { var id: String; var photoPath: String; var photoSHA256: String; var request: String }
    var cases: [Item]
    var profileName: String
    var engineExecutable: String
    var outputDirectory: String
    /// Copies genuine lifecycle records read-only; never reconstructs an approval.
    var sourceLibraryDirectory: String? = nil
    var requiredApprovedMethodVersionIDs: [String]? = nil
  }
  private struct Prepared { let manifest: Manifest; let photos: [Data]; let output: URL }
  private enum Validation: Error { case invalidManifest, invalidPhoto, hashMismatch, outputOccupied }
  private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

  /// Complete preflight before opening credentials or constructing a client.
  private static func preflight(_ bytes: Data) throws -> Prepared {
    let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
    guard !manifest.cases.isEmpty, !manifest.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      manifest.engineExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: manifest.engineExecutable),
      manifest.outputDirectory.hasPrefix("/") else { throw Validation.invalidManifest }
    if let sourcePath = manifest.sourceLibraryDirectory {
      guard sourcePath.hasPrefix("/"), let required = manifest.requiredApprovedMethodVersionIDs,
        !required.isEmpty, Set(required).count == required.count,
        required.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw Validation.invalidManifest }
      let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath()
      let output = URL(fileURLWithPath: manifest.outputDirectory).standardizedFileURL.resolvingSymlinksInPath()
      guard source != output, !source.path.hasPrefix(output.path + "/"), !output.path.hasPrefix(source.path + "/"),
        FileManager.default.fileExists(atPath: source.appendingPathComponent("questions.sqlite").path)
      else { throw Validation.invalidManifest }
    } else if manifest.requiredApprovedMethodVersionIDs != nil { throw Validation.invalidManifest }
    var identifiers = Set<String>()
    var photos: [Data] = []
    for item in manifest.cases {
      guard item.id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
        identifiers.insert(item.id).inserted, item.photoPath.hasPrefix("/"),
        !item.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        item.photoSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
      else { throw Validation.invalidManifest }
      let data = try Data(contentsOf: URL(fileURLWithPath: item.photoPath))
      guard let image = NSBitmapImageRep(data: data), image.pixelsWide > 0, image.pixelsHigh > 0 else { throw Validation.invalidPhoto }
      guard digest(data) == item.photoSHA256 else { throw Validation.hashMismatch }
      photos.append(data)
    }
    let output = URL(fileURLWithPath: manifest.outputDirectory, isDirectory: true)
    if FileManager.default.fileExists(atPath: output.path) {
      let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true,
        try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else { throw Validation.outputOccupied }
    }
    return Prepared(manifest: manifest, photos: photos, output: output)
  }

  func testManifestPreflightAcceptsValidFrozenPhotoAndRejectsUnsafeInputs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let photo = directory.appendingPathComponent("original.png"); try fixture.write(to: photo)
    let item = Manifest.Item(id: "fresh-photo", photoPath: photo.path, photoSHA256: Self.digest(fixture), request: "请解题并验算")
    let valid = Manifest(cases: [item], profileName: "fixture", engineExecutable: "/usr/bin/true", outputDirectory: directory.appendingPathComponent("output").path)
    func check(_ value: Manifest) throws -> Prepared { try Self.preflight(JSONEncoder().encode(value)) }
    XCTAssertEqual(try check(valid).photos, [fixture])
    var bad = valid; bad.cases[0].photoSHA256 = String(repeating: "0", count: 64)
    XCTAssertThrowsError(try check(bad))
    bad = valid; bad.cases[0].photoPath = directory.appendingPathComponent("missing.png").path
    XCTAssertThrowsError(try check(bad))
    bad = valid; bad.cases.append(item); XCTAssertThrowsError(try check(bad))
    bad = valid; bad.cases[0].id = "../escape"; XCTAssertThrowsError(try check(bad))
    bad = valid; bad.cases = []; XCTAssertThrowsError(try check(bad))
    bad = valid; bad.requiredApprovedMethodVersionIDs = [UUID().uuidString]
    XCTAssertThrowsError(try check(bad))
    bad = valid; bad.sourceLibraryDirectory = directory.path
    XCTAssertThrowsError(try check(bad))
    bad.requiredApprovedMethodVersionIDs = ["not-a-version"]
    XCTAssertThrowsError(try check(bad))
    bad.requiredApprovedMethodVersionIDs = [UUID().uuidString]
    XCTAssertThrowsError(try check(bad)) // Missing source database cannot become an empty store.
    try FileManager.default.createDirectory(atPath: valid.outputDirectory, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: URL(fileURLWithPath: valid.outputDirectory).appendingPathComponent("report.json"))
    XCTAssertThrowsError(try check(valid))
    let missingField = Data(#"{"cases":[{"id":"photo"}],"profileName":"fixture","engineExecutable":"/usr/bin/true","outputDirectory":"/tmp/no-write"}"#.utf8)
    XCTAssertThrowsError(try Self.preflight(missingField))
  }

  /// Identify offered entries from the actual assembled prompt, rather than
  /// confusing the full active catalogue with the local retrieval shortlist.
  private static func offeredMethods(in prompt: String, catalogue: [MathTeachingMethod]) -> [MathTeachingMethod] {
    catalogue.filter { prompt.contains("名称：\($0.title)\n全文：\n\($0.instructions)") }
  }

  func testOfferedMethodEvidenceUsesExactTitleAndFullBody() {
    let first = MathTeachingMethod(id: "one", versionID: "v1", title: "统计", category: "方法",
      instructions: "完整统计方法", createdAt: Date(timeIntervalSince1970: 0))
    let second = MathTeachingMethod(id: "two", versionID: "v2", title: "另一统计", category: "方法",
      instructions: "完整统计方法", createdAt: Date(timeIntervalSince1970: 0))
    let prompt = "id:0\nroles:solution\n名称：统计\n全文：\n完整统计方法\n后续合同"
    XCTAssertEqual(Self.offeredMethods(in: prompt, catalogue: [first, second]), [first])
    XCTAssertTrue(Self.offeredMethods(in: "统计，完整统计方法", catalogue: [first, second]).isEmpty)
  }

  func testFrozenUnseenOriginalsOnceThroughInstalledEngine() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_UNSEEN_LIVE_MANIFEST"] else {
      throw XCTSkip("Set MATH_UNSEEN_LIVE_MANIFEST for one-attempt real-photo evidence")
    }
    guard path.hasPrefix("/") else { throw Validation.invalidManifest }
    let input = try Data(contentsOf: URL(fileURLWithPath: path))
    let prepared = try Self.preflight(input)
    let manifest = prepared.manifest, destination = prepared.output
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try input.write(to: destination.appendingPathComponent("run-manifest.json"), options: .atomic)
    let library = destination.appendingPathComponent("isolated-library")
    if let source = manifest.sourceLibraryDirectory {
      // Source is opened READONLY by the existing archive helper. Full persisted
      // lifecycle/evidence records are copied, including genuine human approvals.
      try MathQuestionArchive.create(directory: URL(fileURLWithPath: source), to: library)
    }
    let store = MathQuestionStore(directory: library)
    if manifest.sourceLibraryDirectory == nil { _ = try await store.importBundledMathSkills(MathSkillCatalogue.load()) }
    if manifest.sourceLibraryDirectory != nil {
      let assetNames = try FileManager.default.contentsOfDirectory(at: library.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
      let existingHashes = Set(assetNames.map { $0.deletingPathExtension().lastPathComponent })
      guard manifest.cases.allSatisfy({ !existingHashes.contains($0.photoSHA256) }) else {
        await store.close()
        throw MathQuestionStoreError.database("Held-out photograph already exists in the source library; no provider request sent")
      }
    }
    let activeMethods = try await store.automaticMethods()
    for versionID in manifest.requiredApprovedMethodVersionIDs ?? [] {
      let profile = try await store.skillProfile(versionID: versionID)
      guard activeMethods.contains(where: { $0.versionID == versionID }), profile?.status == "approved" else {
        await store.close()
        throw MathQuestionStoreError.database("Frozen approved method version is not current and eligible: \(versionID)")
      }
    }
    let catalogueEncoder = JSONEncoder(); catalogueEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try catalogueEncoder.encode(activeMethods).write(to: destination.appendingPathComponent("active-method-catalogue.json"), options: .atomic)
    let configurationStarted = ProcessInfo.processInfo.systemUptime
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      MathRoutingEvaluationDelegate.credential(profileID: id)
    })
    let profile = try XCTUnwrap(preferences.profiles.first { $0.name == manifest.profileName }, "Existing named profile required")
    let configuration = preferences.configuration(for: profile.id)
    guard !configuration.apiKey.isEmpty else { await store.close(); throw XCTSkip("Credentials unavailable noninteractively; no provider request sent") }
    let configurationSeconds = ProcessInfo.processInfo.systemUptime - configurationStarted
    let client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: manifest.engineExecutable)))
    let warmStarted = ProcessInfo.processInfo.systemUptime
    await client.warmUp()
    let warmSeconds = ProcessInfo.processInfo.systemUptime - warmStarted
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func write(_ value: Any, _ name: String) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent(name), options: .atomic)
    }
    var reports: [[String: Any]] = []
    for (index, item) in manifest.cases.enumerated() {
      let photo = prepared.photos[index]
      try photo.write(to: destination.appendingPathComponent(item.id + "-question.png"), options: .atomic)
      var offeredMethods: [MathTeachingMethod] = []
      var calls = 0, usage: ScreenshotQuestionUsage?, requestSeconds: Double?, providerFailure: String?
      let measured: ScreenshotQuestionMeasuredAnswer = { question, source, history, recordUsage, partial in
        calls += 1
        guard calls == 1 else { XCTFail("Second provider request forbidden"); throw Validation.invalidManifest }
        XCTAssertEqual(source.imageData, photo)
        XCTAssertTrue(source.mathReferences.isEmpty)
        offeredMethods = Self.offeredMethods(in: question, catalogue: activeMethods)
        try question.write(to: destination.appendingPathComponent(item.id + "-prompt.txt"), atomically: true, encoding: .utf8)
        let started = ProcessInfo.processInfo.systemUptime
        defer { requestSeconds = ProcessInfo.processInfo.systemUptime - started }
        do {
          let response = try await client.answer(question: question, context: source, history: history,
            configuration: configuration, api: profile.api, thinking: .off, directConnection: profile.directConnection,
            onUsage: { usage = $0; recordUsage($0) }, onPartial: partial)
          try response.write(to: destination.appendingPathComponent(item.id + "-response.txt"), atomically: true, encoding: .utf8)
          return response
        } catch { providerFailure = error.localizedDescription; throw error }
      }
      let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
        answer: { _, _, _, _ in XCTFail("Measured path required"); throw Validation.invalidManifest }, measuredAnswer: measured,
        originalImageData: photo, saveQuestion: { try await store.save($0) }, solutionModel: { configuration.model }, mathStore: store,
        selectMethodAutomatically: { _, _, _ in XCTFail("Extra selector forbidden"); throw Validation.invalidManifest },
        singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true,
        canUseReviewedMathExamples: { false })
      var report: [String: Any] = ["id": item.id, "profileName": manifest.profileName, "model": configuration.model,
        "api": profile.api.resolved(for: configuration).rawValue, "thinking": "off", "directConnection": profile.directConnection,
        "configurationResolutionSeconds": configurationSeconds, "enginePrewarmSeconds": warmSeconds,
        "engineExecutable": manifest.engineExecutable, "engineSHA256": Self.digest(try Data(contentsOf: URL(fileURLWithPath: manifest.engineExecutable))),
        "originalSHA256": Self.digest(photo), "qualityReview": "pending_independent_review", "deliveryStatus": "collection_incomplete",
        "sourceLibrarySnapshot": manifest.sourceLibraryDirectory != nil,
        "requiredApprovedMethodVersionIDs": manifest.requiredApprovedMethodVersionIDs ?? [],
        "activeMethodVersionIDs": activeMethods.map(\.versionID),
        "singlePass": true, "programArithmetic": true, "singleSubmission": true, "rendererTools": true, "photoOnly": true, "reviewedExamplesEnabled": false]
      do {
        panel.present()
        let all = views(try XCTUnwrap(panel.contentView))
        try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
        try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = item.request
        try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
        for _ in 0..<1800 { if !panel.isAnswering { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        report["timedOut"] = panel.isAnswering
        if panel.isAnswering {
          views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "停止" }?.performClick(nil)
        }
        report["history"] = panel.history.map { ["question": $0.question, "answer": $0.answer] }
        // Save original even when the request fails. Only complete/partial answers
        // the application itself permits are persisted, always as unverified.
        try XCTUnwrap(views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
        for _ in 0..<300 { if panel.savedQuestionID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        if let savedID = panel.savedQuestionID {
          report["savedQuestionID"] = savedID
          let original = try await store.originalImage(questionID: savedID)
          report["savedOriginalSHA256"] = Self.digest(original)
          XCTAssertEqual(original, photo)
          let solutions = try await store.solutions(questionID: savedID)
          let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          try encoder.encode(solutions).write(to: destination.appendingPathComponent(item.id + "-solutions.json"), options: .atomic)
          report["savedSolutionCount"] = solutions.count
          report["deliveryStatus"] = solutions.isEmpty ? "no_saved_answer" : solutions.contains { $0.answer.contains("解答尚未完成") || $0.answer.contains("回答失败") } ? "incomplete" : "complete_pending_quality_review"
          for solution in solutions { XCTAssertEqual(solution.verificationStatus, "unverified"); XCTAssertTrue(solution.reviewedExamples.isEmpty) }
          if let solution = solutions.last {
            report["selectedMethod"] = try solution.method.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
            report["selectedMethodWasOfferedExactly"] = solution.method.map { offeredMethods.contains($0) } as Any? ?? NSNull()
            report["selectedRequiredApprovedVersion"] = solution.method.map { (manifest.requiredApprovedMethodVersionIDs ?? []).contains($0.versionID) } as Any? ?? NSNull()
            try solution.answer.write(to: destination.appendingPathComponent(item.id + "-answer.txt"), atomically: true, encoding: .utf8)
            report["diagramFailure"] = solution.diagramFailure as Any? ?? NSNull()
            report["selectionFailure"] = solution.selectionFailure as Any? ?? NSNull()
            for (number, diagram) in solution.diagrams.enumerated() {
              try MathDiagramRenderer.renderPNG(diagram).write(to: destination.appendingPathComponent("\(item.id)-diagram-\(number).png"))
            }
          }
          let records = try await store.list()
          if let record = records.first(where: { $0.id == savedID }) {
            report["pdfPages"] = try await MathQuestionPDFExporter.export(records: [record], store: store,
              to: destination.appendingPathComponent(item.id + ".pdf"), options: .init(includeSolutions: true))
          }
        } else { report["deliveryStatus"] = "save_failed" }
      } catch { report["collectionFailure"] = error.localizedDescription }
      report["offeredMethods"] = offeredMethods.map { ["id": $0.id, "versionID": $0.versionID,
        "title": $0.title, "instructionsSHA256": Self.digest(Data($0.instructions.utf8))] }
      report["calls"] = calls
      XCTAssertLessThanOrEqual(calls, 1)
      report["providerFailure"] = providerFailure as Any? ?? NSNull()
      report["requestSeconds"] = requestSeconds as Any? ?? NSNull()
      report["userAnswerSeconds"] = panel.performance?.elapsed as Any? ?? NSNull()
      report["preparationSeconds"] = panel.singlePassPreparationDurations
      report["latencyBreakdown"] = panel.performance?.breakdown(localDurations: panel.singlePassPreparationDurations) ?? "未记录"
      report["engineTimings"] = usage?.engineTimings ?? [:]
      report["inputTokens"] = usage?.inputTokens as Any? ?? NSNull()
      report["outputTokens"] = usage?.outputTokens as Any? ?? NSNull()
      report["reasoningTokens"] = usage?.reasoningTokens as Any? ?? NSNull()
      report["failurePhase"] = usage?.failurePhase as Any? ?? NSNull()
      report["submissionIssue"] = usage?.failureIssue as Any? ?? NSNull()
      report["streamTermination"] = usage?.streamTermination as Any? ?? NSNull()
      if let diagnostic = usage?.submissionDiagnostic { report["submissionDiagnostic"] = ["tool": diagnostic.tool, "path": diagnostic.path, "rule": diagnostic.rule] }
      reports.append(report)
      try write(reports, "report.json")
      panel.close()
    }
    await store.close()
    await client.shutdown()
  }
}
