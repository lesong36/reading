import CSQLite
import CryptoKit
import Foundation
import XCTest
@testable import VocabCapture

/// Opt-in archival preparation only. This never calls a provider, confirms an answer,
/// records a human boundary decision, runs research, or publishes a method.
@MainActor
final class MathRealDraftPreparationTests: XCTestCase {
  private struct Source {
    let questionID: String
    let captureID: String
    let hash: String
    let answerFile: String?
    let answerHash: String?
  }
  private static let sources: [Source] = [
    .init(questionID: "EC79A14D-07BE-42D4-84E0-8D8E87703D92", captureID: "999BEB53-CFF5-4543-9CDC-AF119A71A9F1",
      hash: "8ca19198a2dea4daa3751bea68966ae69113b8f3a37d5f24ad0be055e8049e43", answerFile: "factor-changes-solutions.json",
      answerHash: "0d82cbf8110650fc26fdeedb634bd5a5adab359a851e6d4edf949352e06fbda9"),
    .init(questionID: "A6A532A3-CC7C-4119-9304-DE22B5B48E7F", captureID: "A266016A-6D79-4397-96C4-102EE6844CEA",
      hash: "a1391eb4cecb7c3cff71722b4387a47429c96a76294e09282f69d383e77576a2", answerFile: "two-column-products-solutions.json",
      answerHash: "e7a6cbec6832fedb8ff33d69a8e0ef3bd4b544a7d0b2a8894796db4da18bc8ab"),
    .init(questionID: "CC7A43F6-B9D6-493D-AEED-400BB4354C89", captureID: "0BBDF891-58C3-4E70-A4A0-7392CD725398",
      hash: "d24c1b7e1780d3b1933d1200f8497f1d6e20da12a1a48b461ce283eaea870031", answerFile: nil, answerHash: nil),
    .init(questionID: "1BB7C0AA-A054-47D9-B49F-D14453B4210B", captureID: "9488B562-24FA-432D-9E11-64EF638ED680",
      hash: "5a44385bdc425138f87c4c12214a58c7cbbf90c07007f2ae1275a2d90bde4834", answerFile: nil, answerHash: nil)
  ]
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw MathQuestionStoreError.database(reason) }
  }
  private static func matchingFields(_ lhs: [String: Any], _ rhs: [String: Any]) throws -> [String] {
    try Set(lhs.keys).union(rhs.keys).filter { key in
      try JSONSerialization.data(withJSONObject: [lhs[key] ?? NSNull()], options: [.sortedKeys]) !=
        JSONSerialization.data(withJSONObject: [rhs[key] ?? NSNull()], options: [.sortedKeys])
    }.sorted()
  }

  func testEvidenceComparisonIdentifiesMismatchWithoutChangingInput() throws {
    XCTAssertEqual(try Self.matchingFields(["answer": "原回答", "grade": NSNull()], ["answer": "修改", "grade": 4]), ["answer", "grade"])
    XCTAssertEqual(try Self.matchingFields(["grade": 4], ["grade": 4]), [])
  }

  func testFrozenPreparationSourcesAreDistinctAndOnlyTwoAnswersAreImported() {
    XCTAssertEqual(Self.sources.count, 4)
    XCTAssertEqual(Set(Self.sources.map(\.questionID)).count, 4)
    XCTAssertEqual(Set(Self.sources.map(\.captureID)).count, 4)
    XCTAssertEqual(Set(Self.sources.map(\.hash)).count, 4)
    XCTAssertEqual(Self.sources.compactMap(\.answerFile).count, 2)
    XCTAssertTrue(Self.sources.allSatisfy { $0.hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
  }

  func testArchiveActualCoveredDiscoveryInExplicitLibrary() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["MATH_REAL_DRAFT_PREPARE"] == "1",
      let targetPath = env["MATH_REAL_DRAFT_TARGET"], let reportPath = env["MATH_REAL_DRAFT_REPORT"],
      let answerPath = env["MATH_REAL_DRAFT_ANSWERS"], let photoPath = env["MATH_REAL_DRAFT_ORIGINALS"] else {
      throw XCTSkip("Requires explicit opt-in, existing target library, frozen report, actual answers and original photographs")
    }
    let target = URL(fileURLWithPath: targetPath).standardizedFileURL.resolvingSymlinksInPath()
    let reportData = try Data(contentsOf: URL(fileURLWithPath: reportPath))
    try Self.require(Self.digest(reportData) == "c1e8426ab748b2623a601d34c91346c9a547d51ddd1942e449ceafd50811bcbd", "Actual discovery report hash differs; no preparation performed")
    let report = String(decoding: reportData, as: UTF8.self)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
    try Self.require(object["human_decision"] == nil && object["status"] as? String == "covered" && object["coverage"] as? String == "covered", "Report must preserve the actual covered conclusion")
    let ids = Set(Self.sources.map(\.questionID))
    let result = try MathSkillLearningResult.parse(report, questionIDs: ids)
    try Self.require(result.proposal == nil && result.patternKey == nil, "Covered reports must not manufacture candidate proposals or observations")
    try Self.require(result.evidenceIDs == Set(Self.sources.prefix(3).map(\.questionID)), "Discovery matched source IDs differ")
    let state = try XCTUnwrap((object["workflow_state"] as? [String: Any])?["state"] as? [String: Any])
    let evidence = try XCTUnwrap(state["evidence"] as? [[String: Any]])

    // Verify capture ownership read-only before any public store mutation. Opening a
    // nonexistent library here must fail rather than create an empty database.
    var db: OpaquePointer?
    try Self.require(sqlite3_open_v2(target.appendingPathComponent("questions.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Existing target library unavailable")
    defer { sqlite3_close(db) }
    for source in Self.sources {
      var statement: OpaquePointer?
      try Self.require(sqlite3_prepare_v2(db, "SELECT capture_id,asset_id FROM questions WHERE id=? AND deleted_at IS NULL", -1, &statement, nil) == SQLITE_OK, "Cannot inspect existing capture ownership")
      defer { sqlite3_finalize(statement) }
      _ = source.questionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
      try Self.require(sqlite3_step(statement) == SQLITE_ROW, "Missing existing question \(source.questionID)")
      let capture = String(cString: sqlite3_column_text(statement, 0))
      let hash = String(cString: sqlite3_column_text(statement, 1))
      try Self.require(capture == source.captureID && hash == source.hash, "Existing capture or photo differs: \(source.questionID)")
    }
    let store = MathQuestionStore(directory: target)
    let candidatesBefore = try await store.listSkillCandidates()
    let oldReports = try await store.skillLearningReports(questionID: Self.sources[0].questionID)
    let alreadyArchived = try oldReports.contains { archived in
      guard var previous = try JSONSerialization.jsonObject(with: Data(archived.report.utf8)) as? [String: Any] else { return false }
      previous.removeValue(forKey: "native_learning_sources")
      return try Self.matchingFields(previous, object).isEmpty
    }
    try Self.require(!alreadyArchived, "Report is already archived; refusing duplicate preparation")
    var prepared: [MathSkillLearningSnapshot] = []
    var originals: [String: Data] = [:]
    var additions: [String: MathQuestionSolution] = [:]
    for (index, source) in Self.sources.enumerated() {
      let snapshot = try await store.learningSnapshot(questionID: source.questionID)
      let original = try await store.originalImage(questionID: source.questionID)
      let frozenOriginal = try Data(contentsOf: URL(fileURLWithPath: photoPath).appendingPathComponent("original-\(index + 1).png"))
      try Self.require(Self.digest(original) == source.hash && original == frozenOriginal, "Original photograph mismatch: \(source.questionID)")
      originals[source.questionID] = original
      var solutions = snapshot.solutions
      if let file = source.answerFile, let hash = source.answerHash {
        let data = try Data(contentsOf: URL(fileURLWithPath: answerPath).appendingPathComponent(file))
        try Self.require(Self.digest(data) == hash, "Original answer archive hash differs: \(file)")
        let answers = try JSONDecoder().decode([MathQuestionSolution].self, from: data)
        try Self.require(answers.count == 1 && answers[0].verificationStatus == "unverified" && answers[0].model == "deepseek-flash", "Only actual unverified answer archive is allowed")
        let answer = answers[0]
        if let existing = solutions.first(where: { $0.id == answer.id }) {
          try Self.require(existing == answer, "Existing archived answer differs: \(source.questionID)")
        } else {
          try Self.require(solutions.isEmpty, "Newer existing answers would change frozen discovery binding: \(source.questionID)")
          additions[source.questionID] = answer
          solutions.append(answer)
        }
      }
      let predicted = MathSkillLearningSnapshot(grade: 4, questionID: snapshot.questionID, assetID: snapshot.assetID,
        ocrText: snapshot.ocrText, solutions: solutions, references: snapshot.references, reviews: snapshot.reviews)
      let raw = try XCTUnwrap(evidence.first { $0["question_id"] as? String == source.questionID })
      let changed = try Self.matchingFields(raw, MathSkillLearningValidation.backgroundEvidence(predicted))
      try Self.require(changed.isEmpty, "Frozen discovery source mismatch \(source.questionID): \(changed.joined(separator: ", ")); refusing candidate write")
      prepared.append(predicted)
    }
    let allowed = Set(try await store.automaticMethods().map(\.id))
    try MathSkillLearningValidation.validate(object, sourceSnapshots: prepared, allowedMethodIDs: allowed, allowLegacyWithoutCheckpoint: false)

    // Every frozen input has now passed preflight. Reversible preparation writes
    // use native APIs; no text, original answer, reference or human review is edited.
    for (index, source) in Self.sources.enumerated() {
      if let answer = additions[source.questionID] {
        let saved = try await store.save(.init(captureID: source.captureID, imageData: try XCTUnwrap(originals[source.questionID]), solutions: [answer]))
        try Self.require(saved.id == source.questionID, "Save created a different question")
      }
      if try await store.learningSnapshot(questionID: source.questionID).grade != 4 {
        try await store.updateQuestionGrade(questionID: source.questionID, grade: 4)
      }
      let current = try await store.learningSnapshot(questionID: source.questionID)
      try Self.require(current == prepared[index], "Prepared snapshot differs after native save: \(source.questionID)")
    }
    try await store.enqueueSkillLearning(questionID: Self.sources[0].questionID)
    let claimed = try await store.claimSkillLearning(questionID: Self.sources[0].questionID)
    let attempt = try XCTUnwrap(claimed)
    try await store.finishSkillLearning(attempt: attempt, proposal: nil, report: report, model: "gpt-6.1-sol",
      patternKey: nil, evidenceSnapshots: Array(prepared.dropFirst()))
    let candidatesAfter = try await store.listSkillCandidates()
    try Self.require(candidatesAfter == candidatesBefore, "Covered reports must not create or edit candidate observations")
    let archivedReports = try await store.skillLearningReports(questionID: Self.sources[0].questionID)
    try Self.require(archivedReports.count == oldReports.count + 1, "Actual covered report was not archived")
    let saved = try XCTUnwrap(archivedReports.last)
    let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.report.utf8)) as? [String: Any])
    let nativeSources = try XCTUnwrap(savedObject["native_learning_sources"])
    let sourceData = try JSONSerialization.data(withJSONObject: nativeSources)
    try Self.require(try JSONDecoder().decode([MathSkillLearningSnapshot].self, from: sourceData) == prepared,
      "Archived report source snapshots differ")
    var preserved = savedObject
    preserved.removeValue(forKey: "native_learning_sources")
    try Self.require(try Self.matchingFields(preserved, object).isEmpty, "Actual covered report was changed during archival")
    print("ACTUAL_COVERED_REPORT_ARCHIVED report=\(saved.id) status=covered native_sources=\(prepared.count) added_unverified_answers=\(additions.count) candidate_changes=0 human_decisions_added=0 published=0")
  }
}
