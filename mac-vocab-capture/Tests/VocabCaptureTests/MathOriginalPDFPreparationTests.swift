import CryptoKit
import Foundation
import XCTest
@testable import VocabCapture

/// Explicit archival work only: no provider calls, human decisions or publication.
@MainActor
final class MathOriginalPDFPreparationTests: XCTestCase {
  private struct Input: Decodable {
    struct Source: Decodable {
      let name: String
      let captureID: String
      let photoPath: String
      let photoSHA256: String
      let solutionsPath: String
      let solutionsSHA256: String
    }
    let sources: [Source]
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func require(_ value: Bool) throws {
    guard value else { throw MathQuestionStoreError.database("原卷归档依据不完整或已变化") }
  }

  func testPrepareExplicitOriginalSourcesWithoutApproving() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let manifestPath = env["MATH_PDF_SOURCE_MANIFEST"],
      let expectedHash = env["MATH_PDF_SOURCE_MANIFEST_SHA256"],
      let targetPath = env["MATH_PDF_SOURCE_LIBRARY"],
      let outputPath = env["MATH_PDF_SOURCE_OUTPUT"] else {
      throw XCTSkip("Explicit frozen original sources, target library and output required")
    }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    try Self.require(Self.digest(bytes) == expectedHash)
    let manifest = try JSONDecoder().decode(Input.self, from: bytes)
    try Self.require(manifest.sources.count == 4 && Set(manifest.sources.map(\.captureID)).count == 4
      && Set(manifest.sources.map(\.photoSHA256)).count == 4
      && Set(manifest.sources.map(\.name)).count == 4)
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    try Self.require(!FileManager.default.fileExists(atPath: output.path))
    var prepared: [(Input.Source, Data, [MathQuestionSolution], String)] = []
    // All bytes and answers are checked before opening the target for mutation.
    for source in manifest.sources {
      let photo = try Data(contentsOf: URL(fileURLWithPath: source.photoPath))
      let answers = try Data(contentsOf: URL(fileURLWithPath: source.solutionsPath))
      try Self.require(Self.digest(photo) == source.photoSHA256 && Self.digest(answers) == source.solutionsSHA256)
      let solutions = try JSONDecoder().decode([MathQuestionSolution].self, from: answers)
      try Self.require(solutions.count == 1 && solutions[0].verificationStatus == "unverified")
      let ocr = try await MathQuestionIndexer.recognize(photo)
      prepared.append((source, photo, solutions, ocr))
    }
    let store = MathQuestionStore(directory: URL(fileURLWithPath: targetPath, isDirectory: true))
    if try await store.automaticMethods().isEmpty {
      _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    }
    let before = try await store.listSkillCandidates()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try bytes.write(to: output.appendingPathComponent("source-manifest.json"))
    var evidence: [[String: Any]] = [], ids: [String] = [], snapshots: [MathSkillLearningSnapshot] = []
    for (source, photo, solutions, ocr) in prepared {
      let record = try await store.save(.init(captureID: source.captureID, imageData: photo,
        ocrText: ocr, solutions: solutions))
      try await store.updateQuestionGrade(questionID: record.id, grade: 4)
      let snapshot = try await store.learningSnapshot(questionID: record.id)
      try Self.require(snapshot.reviews.isEmpty && snapshot.references.isEmpty
        && snapshot.solutions == solutions && snapshot.ocrText == ocr)
      try Self.require(try await store.originalImage(questionID: record.id) == photo)
      let imageFile = source.name + ".png"
      try photo.write(to: output.appendingPathComponent(imageFile))
      var item = MathSkillLearningValidation.backgroundEvidence(snapshot)
      item["image_file"] = imageFile
      evidence.append(item); ids.append(record.id); snapshots.append(snapshot)
    }
    let fixture: [String: Any] = ["cases": [["id": "real-statistics-discovery", "current_id": ids[0],
      "evidence": evidence, "expected_match_ids": Array(ids.prefix(3)), "expect_draft": true,
      "source_kind": "three distinct complete user PDF questions; unverified actual answers; fourth question is unrelated"]]]
    try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("manifest.json"))
    try JSONEncoder().encode(snapshots).write(to: output.appendingPathComponent("native-snapshots.json"))
    try Self.require(try await store.listSkillCandidates() == before)
    await store.close()
  }

  func testArchiveExplicitActualDiscoveryWithoutApproving() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let input = env["MATH_PDF_DISCOVERY_REPORT"], let hash = env["MATH_PDF_DISCOVERY_REPORT_SHA256"],
      let target = env["MATH_PDF_SOURCE_LIBRARY"], let snapshotsPath = env["MATH_PDF_DISCOVERY_SNAPSHOTS"] else {
      throw XCTSkip("Explicit actual discovery and unchanged native snapshots required")
    }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: input))
    try Self.require(Self.digest(bytes) == hash)
    let snapshots = try JSONDecoder().decode([MathSkillLearningSnapshot].self,
      from: Data(contentsOf: URL(fileURLWithPath: snapshotsPath)))
    try Self.require(snapshots.count == 4)
    let store = MathQuestionStore(directory: URL(fileURLWithPath: target, isDirectory: true))
    for snapshot in snapshots {
      try Self.require(try await store.learningSnapshot(questionID: snapshot.questionID) == snapshot)
    }
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    try MathSkillLearningValidation.validate(object, sourceSnapshots: snapshots,
      allowedMethodIDs: Set(try await store.automaticMethods().map(\.id)), allowLegacyWithoutCheckpoint: false)
    let text = String(decoding: bytes, as: UTF8.self)
    let result = try MathSkillLearningResult.parse(text, questionIDs: Set(snapshots.map(\.questionID)))
    try await store.enqueueSkillLearning(questionID: snapshots[0].questionID)
    let claimed = try await store.claimSkillLearning(questionID: snapshots[0].questionID)
    let attempt = try XCTUnwrap(claimed)
    try await store.finishSkillLearning(attempt: attempt, proposal: result.proposal, report: text,
      model: "gpt-6.1-sol", patternKey: result.patternKey, evidenceSnapshots: Array(snapshots.dropFirst()))
    await store.close()
  }
}
