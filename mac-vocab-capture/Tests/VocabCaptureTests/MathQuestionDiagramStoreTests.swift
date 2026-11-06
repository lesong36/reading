import CSQLite
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import VocabCapture

/// Fixtures never touch the user's installed library.
final class MathQuestionDiagramStoreTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("math-diagram-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  func testOrderedDiagramSnapshotsAndRenderedAssetsSurviveReopenAndBackup() async throws {
    let directory = root.appendingPathComponent("library")
    let store = MathQuestionStore(directory: directory)
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.area)
    let method = try await store.saveMethod(title: "和差", category: "算术", instructions: "先比较，再合并")
    let answer = MathQuestionSolution(id: "answer", question: "解题", answer: "72 人", model: "test", method: method, diagrams: [MathDiagramFixtures.bar, MathDiagramFixtures.unknown], diagramFailure: "另一个图不适用")
    let question = try await store.save(.init(captureID: "capture", imageData: image, solutions: [answer]))
    let reference = try await store.addReferenceAnswer(questionID: question.id, text: "72", source: "教师", scope: "答案")
    _ = try await store.reviewSolution(questionID: question.id, solutionID: answer.id, status: "confirmed", scope: "答案", note: "", correction: "", referenceID: reference.id)
    let savedBytes = try await store.diagramImage(solutionID: answer.id, ordinal: 0)
    let original = try await store.originalImage(questionID: question.id)
    XCTAssertEqual(original, image)
    // A duplicate capture cannot mutate an earlier answer's frozen diagram version.
    _ = try await store.save(.init(captureID: "capture", imageData: image, solutions: [.init(id: "answer", question: "changed", answer: "changed", model: "test", diagrams: [MathDiagramFixtures.state])]))
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    await store.close()
    let reopened = MathQuestionStore(directory: backup)
    let restored = try await reopened.solutions(questionID: question.id)
    XCTAssertEqual(restored.first?.diagrams, answer.diagrams)
    XCTAssertEqual(restored.first?.diagramFailure, answer.diagramFailure)
    XCTAssertEqual(restored.first?.method, method)
    XCTAssertEqual(restored.first?.answer, answer.answer)
    XCTAssertEqual(restored.first?.verificationStatus, "confirmed")
    let reviews = try await reopened.reviews(solutionID: answer.id)
    XCTAssertEqual(reviews.count, 1)
    let restoredBytes = try await reopened.diagramImage(solutionID: answer.id, ordinal: 0)
    XCTAssertEqual(restoredBytes, savedBytes)
    await reopened.close()
  }

  func testCurrentRendererIsStoredAndOldRendererBackupRemainsRecoverable() async throws {
    let directory = root.appendingPathComponent("renderer-versions")
    let store = MathQuestionStore(directory: directory)
    let question = try await store.save(.init(captureID: "versions", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar),
      solutions: [.init(id: "version-answer", question: "q", answer: "a", model: "test", diagrams: [MathDiagramFixtures.bar])]))
    let image = try await store.diagramImage(solutionID: "version-answer", ordinal: 0)
    await store.close()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("questions.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT renderer_version FROM solution_diagrams", -1, &stmt, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
    XCTAssertEqual(Int(sqlite3_column_int(stmt, 0)), MathDiagramRenderer.rendererVersion)
    sqlite3_finalize(stmt)
    XCTAssertEqual(sqlite3_exec(db, "UPDATE solution_diagrams SET renderer_version=1", nil, nil, nil), SQLITE_OK)
    let backup = root.appendingPathComponent("legacy-renderer-backup")
    try MathQuestionArchive.create(directory: directory, to: backup)
    let restored = MathQuestionStore(directory: backup)
    let solutions = try await restored.solutions(questionID: question.id)
    XCTAssertEqual(solutions.first?.diagrams, [MathDiagramFixtures.bar])
    let restoredImage = try await restored.diagramImage(solutionID: "version-answer", ordinal: 0)
    XCTAssertEqual(restoredImage, image)
    await restored.close()
    XCTAssertEqual(sqlite3_exec(db, "UPDATE solution_diagrams SET renderer_version=999", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.create(directory: directory, to: root.appendingPathComponent("future-renderer")))
  }

  func testLegacyCodableHasNoDiagramsOrFailure() throws {
    let bytes = Data(#"{"id":"old","question":"q","answer":"a","model":"m","createdAt":1}"#.utf8)
    let answer = try JSONDecoder().decode(MathQuestionSolution.self, from: bytes)
    XCTAssertEqual(answer.diagrams, [])
    XCTAssertNil(answer.diagramFailure)
  }

  func testInvalidDiagramPreservesAnswerAndOriginalAndSharedPNGIsNeverDeleted() async throws {
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let good = MathQuestionSolution(id: "good", question: "q", answer: "a", model: "test", diagrams: [MathDiagramFixtures.bar])
    let q = try await store.save(.init(captureID: "one", imageData: image, solutions: [good]))
    var invalid = MathDiagramFixtures.bar
    invalid.facts[2].value = 999
    let bad = try await store.save(.init(captureID: "bad", imageData: image, solutions: [.init(question: "q", answer: "readable steps", model: "test", diagrams: [invalid])]))
    let solutions = try await store.solutions(questionID: bad.id)
    XCTAssertEqual(solutions.first?.answer, "readable steps")
    XCTAssertEqual(solutions.first?.diagrams, [])
    XCTAssertNotNil(solutions.first?.diagramFailure)
    let badOriginal = try await store.originalImage(questionID: bad.id)
    XCTAssertEqual(badOriginal, image)
    let records = try await store.list()
    XCTAssertEqual(records.count, 2)
    let shared = try await store.diagramImage(solutionID: good.id, ordinal: 0)
    XCTAssertEqual(shared, image)
    try await store.delete(questionID: q.id)
    let hiddenOriginal = try await store.originalImage(questionID: q.id)
    XCTAssertEqual(hiddenOriginal, image)
    await store.close()
  }

  func testIllegibleDiagramIsSkippedAndOtherDiagramsRemainOrdered() async throws {
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    var narrow = MathDiagramFixtures.area
    narrow.facts[0].value = 1000; narrow.facts[1].value = 100
    narrow.facts[2].value = 100_000; narrow.parts = [1, 1]
    XCTAssertNoThrow(try narrow.validate())
    let original = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let question = try await store.save(.init(captureID: "narrow", imageData: original,
      solutions: [.init(id: "narrow-answer", question: "q", answer: "保留原解题过程", model: "test",
        diagrams: [narrow, MathDiagramFixtures.bar, MathDiagramFixtures.unknown])]))
    let saved = try await store.solutions(questionID: question.id)
    XCTAssertEqual(saved.first?.answer, "保留原解题过程")
    XCTAssertEqual(saved.first?.diagrams, [MathDiagramFixtures.bar, MathDiagramFixtures.unknown])
    XCTAssertTrue(saved.first?.diagramFailure?.contains("面积分块过窄") == true)
    let first = try await store.diagramImage(solutionID: "narrow-answer", ordinal: 0)
    XCTAssertEqual(first, original)
    _ = try await store.diagramImage(solutionID: "narrow-answer", ordinal: 1)
    await store.close()
  }

  func testDiagramDatabaseFailureStillAbortsSave() async throws {
    let directory = root.appendingPathComponent("library")
    let store = MathQuestionStore(directory: directory)
    _ = try await store.storageConfiguration()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("questions.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_diagram BEFORE INSERT ON solution_diagrams BEGIN SELECT RAISE(ABORT,'diagram write failed'); END", nil, nil, nil), SQLITE_OK)
    do {
      _ = try await store.save(.init(captureID: "db-failure", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar),
        solutions: [.init(question: "q", answer: "a", model: "test", diagrams: [MathDiagramFixtures.bar])]))
      XCTFail("Database failures must propagate")
    } catch let error as MathQuestionStoreError {
      guard case .database = error else { return XCTFail("Unexpected store error: \(error)") }
    }
    let records = try await store.list()
    XCTAssertTrue(records.isEmpty)
    await store.close()
  }
}
