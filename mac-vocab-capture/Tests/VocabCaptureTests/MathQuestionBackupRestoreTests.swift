import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

final class MathQuestionBackupRestoreTests: XCTestCase {
  func testOptInReadOnlyArchiveAndIsolatedRestore() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["MATH_READONLY_ARCHIVE_SOURCE"],
      let destinationPath = environment["MATH_READONLY_ARCHIVE_DESTINATION"] else {
      throw XCTSkip("Explicit read-only real-library archive; never migrate or restore the source")
    }
    let source = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
    let destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
    guard source != destination, !destination.path.hasPrefix(source.path + "/"),
      !source.path.hasPrefix(destination.path + "/") else {
      throw MathQuestionStoreError.incompatibleDatabase
    }
    // This helper opens the source SQLITE_OPEN_READONLY, before any Store can
    // migrate it, and verifies every original and diagram asset by its hash.
    try MathQuestionPreMigrationBackup.create(directory: source, to: destination)
    let questionCount = try sql("SELECT COUNT(*) FROM questions WHERE deleted_at IS NULL", in: destination)
    let assetCount = try sql("SELECT COUNT(*) FROM image_assets", in: destination)
    XCTAssertEqual(try sql("PRAGMA quick_check", in: destination), ["ok"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("questions.sqlite-wal").path))
    let restored = MathQuestionStore(directory: root.appendingPathComponent("restored-copy"))
    _ = try await restored.restoreBackup(from: destination)
    let records = try await restored.list()
    XCTAssertEqual(String(records.count), questionCount.first)
    for record in records {
      let original = try await restored.originalImage(questionID: record.id)
      XCTAssertFalse(original.isEmpty)
    }
    await restored.close()
    print("Read-only archive verified; active questions \(questionCount.first ?? "?"); registered assets \(assetCount.first ?? "?"); restore confined to temporary directory")
  }

  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("math-backup-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func sql(_ text: String, in directory: URL) throws -> [String] {
    var pointer: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("questions.sqlite").path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let db = pointer else { throw MathQuestionStoreError.incompatibleDatabase }
    defer { sqlite3_close_v2(db) }
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(db, text, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
      throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db))) }
    return rows
  }

  private func legacy(_ version: Int, in directory: URL) throws {
    var commands = ["DROP TABLE method_candidate_evidence", "DROP TABLE method_candidates", "DROP TABLE skill_learning_reports", "DROP TABLE skill_learning_jobs", "DROP TABLE skill_lifecycle_events", "DROP TABLE skill_profiles"]
    if version < 5 { commands += ["DROP TABLE solution_diagrams", "ALTER TABLE question_solutions DROP COLUMN diagram_failure"] }
    if version < 4 { commands += ["DROP TABLE teaching_method_imports"] }
    if version < 3 { commands += ["DROP TABLE question_auto_tag_jobs", "ALTER TABLE questions DROP COLUMN classification_revision"] }
    if version < 2 { commands += ["DROP TABLE solution_reviews", "DROP TABLE question_reference_answers", "DROP TABLE teaching_methods", "DROP TABLE teaching_method_versions", "ALTER TABLE question_solutions DROP COLUMN method_snapshot"] }
    for command in commands + ["PRAGMA user_version = \(version)"] { _ = try sql(command, in: directory) }
  }

  func testEveryLegacyVersionIsSnapshottedBeforeMigrationWithoutChangingOriginal() async throws {
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    for version in 1...5 {
      let directory = root.appendingPathComponent("legacy-\(version)")
      let store = MathQuestionStore(directory: directory)
      let method = version >= 2 ? try await store.saveMethod(title: "旧方法", category: "和差", instructions: "保留用户方法正文") : nil
      let question = try await store.save(.init(captureID: "old", imageData: image, solutions: [.init(id: "old-answer", question: "q", answer: "old", model: "test", method: method)]))
      if version >= 2 {
        let reference = try await store.addReferenceAnswer(questionID: question.id, text: "参考答案", source: "教师", scope: "最终答案")
        _ = try await store.reviewSolution(questionID: question.id, solutionID: "old-answer", status: "rejected", scope: "答案", note: "旧核验", correction: "更正", referenceID: reference.id)
      }
      await store.close()
      try legacy(version, in: directory)
      let migrated = MathQuestionStore(directory: directory)
      let result = try await migrated.list()
      XCTAssertEqual(result, [question])
      let snapshots = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("pre-migration-backups"), includingPropertiesForKeys: nil)
      XCTAssertEqual(snapshots.count, 1)
      XCTAssertEqual(try sql("PRAGMA user_version", in: snapshots[0]), ["\(version)"])
      XCTAssertEqual(try sql("SELECT answer FROM question_solutions", in: snapshots[0]), ["old"])
      let original = try await migrated.originalImage(questionID: question.id)
      XCTAssertEqual(original, image)
      XCTAssertEqual(try sql("PRAGMA user_version", in: directory), [String(MathQuestionArchive.supportedVersion)])
      let answers = try await migrated.solutions(questionID: question.id)
      XCTAssertEqual(answers.first?.method, method)
      if version >= 2 {
        let reviews = try await migrated.reviews(solutionID: "old-answer")
        XCTAssertEqual(reviews.first?.correction, "更正")
        let methods = try await migrated.methods()
        XCTAssertEqual(methods, [method!])
        XCTAssertEqual(answers.first?.verificationStatus, "rejected")
      }
      await migrated.close()
    }
  }

  func testIndependentPreMigrationSnapshotIncludesLiveWALAndDoesNotUpgrade() async throws {
    let directory = root.appendingPathComponent("old")
    let store = MathQuestionStore(directory: directory)
    _ = try await store.list()
    await store.close()
    try legacy(4, in: directory)
    var pointer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("questions.sqlite").path, &pointer), SQLITE_OK)
    let writer = try XCTUnwrap(pointer)
    defer { sqlite3_close_v2(writer) }
    XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE wal_evidence(value TEXT); INSERT INTO wal_evidence VALUES ('committed in WAL');", nil, nil, nil), SQLITE_OK)
    let snapshot = root.appendingPathComponent("independent")
    try MathQuestionPreMigrationBackup.create(directory: directory, to: snapshot)
    XCTAssertEqual(try sql("PRAGMA user_version", in: snapshot), ["4"])
    XCTAssertEqual(try sql("PRAGMA user_version", in: directory), ["4"])
    XCTAssertEqual(try sql("SELECT value FROM wal_evidence", in: snapshot), ["committed in WAL"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("questions.sqlite-wal").path))
  }

  func testMissingLegacyAssetStopsMigrationAndNewerBackupCannotReplaceCurrent() async throws {
    let directory = root.appendingPathComponent("missing")
    let store = MathQuestionStore(directory: directory)
    _ = try await store.save(.init(captureID: "old", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)))
    await store.close()
    try legacy(4, in: directory)
    let assets = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: assets[0])
    let failed = MathQuestionStore(directory: directory)
    do { _ = try await failed.list(); XCTFail("Migration requires complete old assets") }
    catch MathQuestionStoreError.damagedImage { }
    XCTAssertEqual(try sql("PRAGMA user_version", in: directory), ["4"])
    await failed.close()

    let currentDirectory = root.appendingPathComponent("current")
    let current = MathQuestionStore(directory: currentDirectory)
    let q = try await current.save(.init(captureID: "current", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)))
    let newer = root.appendingPathComponent("newer")
    try await current.backup(to: newer)
    _ = try sql("PRAGMA user_version=99", in: newer)
    do { _ = try await current.restoreBackup(from: newer); XCTFail("Newer backup must fail before switching") }
    catch MathQuestionStoreError.newerDatabase(let version) { XCTAssertEqual(version, 99) }
    let list = try await current.list()
    XCTAssertEqual(list, [q])
    await current.close()
  }

  func testCorruptDiagramJSONIsRejectedBeforeReplacingCurrentLibrary() async throws {
    let directory = root.appendingPathComponent("current-json")
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "current", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar),
      solutions: [.init(question: "q", answer: "a", model: "fixture", diagrams: [MathDiagramFixtures.bar])]))
    let backup = root.appendingPathComponent("corrupt-json")
    try await store.backup(to: backup)
    _ = try sql("UPDATE solution_diagrams SET diagram_json='{}'", in: backup)
    do { _ = try await store.restoreBackup(from: backup); XCTFail("Invalid diagram JSON must be rejected") }
    catch MathQuestionStoreError.database { }
    let records = try await store.list()
    XCTAssertEqual(records, [record])
    let solutions = try await store.solutions(questionID: record.id)
    XCTAssertEqual(solutions.first?.diagrams, [MathDiagramFixtures.bar])
    await store.close()
  }

  func testRestoreIncludesDiagramsAndRetainsRecoveryOfPreviousLibrary() async throws {
    let directory = root.appendingPathComponent("current")
    let store = MathQuestionStore(directory: directory)
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.area)
    let answer = MathQuestionSolution(id: "original-answer", question: "q", answer: "a", model: "test", diagrams: [MathDiagramFixtures.area])
    let original = try await store.save(.init(captureID: "original", imageData: image, solutions: [answer]))
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    let later = try await store.save(.init(captureID: "later", imageData: image))
    let recovery = try await store.restoreBackup(from: backup)
    let restored = try await store.list()
    XCTAssertEqual(restored, [original])
    let diagrams = try await store.solutions(questionID: original.id)
    XCTAssertEqual(diagrams, [answer])
    let png = try await store.diagramImage(solutionID: answer.id, ordinal: 0)
    XCTAssertEqual(png, image)
    let old = MathQuestionStore(directory: recovery)
    let previous = try await old.list()
    XCTAssertEqual(Set(previous.map(\.id)), [original.id, later.id])
    await old.close()
    await store.close()
  }

  func testCorruptPrerequisiteRefusalIsRejectedBeforeReplacingCurrentLibrary() async throws {
    let directory = root.appendingPathComponent("current-blocked")
    let store = MathQuestionStore(directory: directory)
    let solution = MathQuestionSolution(id: "blocked-answer", question: "q", answer: "正常回答", model: "fixture", selectionFailure: "前提不成立")
    let record = try await store.save(.init(captureID: "current", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), solutions: [solution]))
    let backup = root.appendingPathComponent("corrupt-blocked")
    try await store.backup(to: backup)
    for failure in ["   ", String(repeating: "错", count: 513)] {
      let invalid = try JSONSerialization.data(withJSONObject: ["visualMethods": [], "selectionFailure": failure])
      let quoted = String(decoding: invalid, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
      _ = try sql("UPDATE question_solutions SET method_snapshot='\(quoted)'", in: backup)
      do { _ = try await store.restoreBackup(from: backup); XCTFail("Invalid method refusal must be rejected") }
      catch MathQuestionStoreError.database { }
      let records = try await store.list()
      XCTAssertEqual(records, [record])
      let answers = try await store.solutions(questionID: record.id)
      XCTAssertEqual(answers, [solution])
    }
    await store.close()
  }

  func testActivationFailureAtomicallyRollsBackOriginalDirectory() async throws {
    let directory = root.appendingPathComponent("current")
    let store = MathQuestionStore(directory: directory)
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let original = try await store.save(.init(captureID: "original", imageData: image))
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    let later = try await store.save(.init(captureID: "later", imageData: image))
    await store.close()
    enum Injected: Error { case failure }
    do {
      _ = try MathQuestionBackupRestore.replace(directory: directory, from: backup, close: {}, activate: { throw Injected.failure })
      XCTFail("Activation failure must roll back")
    } catch Injected.failure { }
    let reopened = MathQuestionStore(directory: directory)
    let records = try await reopened.list()
    XCTAssertEqual(Set(records.map(\.id)), [original.id, later.id])
    await reopened.close()
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".math-restore-stage-") })
  }
}
