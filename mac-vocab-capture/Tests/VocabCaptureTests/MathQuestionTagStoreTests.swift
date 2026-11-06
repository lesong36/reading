import CSQLite
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import VocabCapture

final class MathQuestionTagStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "math-tag-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func fixture() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 17, height: 13, bitsPerComponent: 8, bytesPerRow: 68,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 17, height: 13))
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func tag(
    _ id: String, axis: String = "curriculum_knowledge", version: String = "primary-v0.1",
    label: String? = nil, origin: String = "user", status: String = "confirmed"
  ) -> MathQuestionTag {
    .init(
      axis: axis, tagID: id, catalogueVersion: version, label: label ?? id,
      origin: origin, status: status)
  }

  private func rawSQL(_ sql: String) throws {
    var connection: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        directory.appendingPathComponent("questions.sqlite").path,
        &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
    let db = try XCTUnwrap(connection)
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db)))
    }
  }

  func testClassificationReopensAndBackupPreservesOriginalAnswerReviewsAndMethod() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let method = try await store.saveMethod(title: "u 法", category: "乘积极值", instructions: "降序填位")
    let solution = MathQuestionSolution(
      question: "解题", answer: "4672", model: "test", method: method)
    let question = try await store.save(
      .init(
        captureID: "one", imageData: bytes,
        ocrText: "数字组数求乘积极值", solutions: [solution]))
    let reference = try await store.addReferenceAnswer(
      questionID: question.id, text: "4672",
      source: "用户参考答案", scope: "最终结果", imageData: bytes)
    let review = try await store.reviewSolution(
      questionID: question.id, solutionID: solution.id,
      status: "confirmed", scope: "最终结果", note: "已核对", correction: "", referenceID: reference.id)
    let tags = [
      tag("form.fill", axis: "question_form", label: "填空"),
      tag("knowledge.multiply", label: "整数乘法"),
      tag("family.extreme", axis: "problem_family", label: "乘积极值"),
      tag("personal-1", axis: "custom", version: "local", label: "需要复习"),
    ]
    try await store.updateClassification(questionID: question.id, grade: 4, tags: tags)
    let backupURL = directory.appendingPathComponent("backup")
    try await store.backup(to: backupURL)
    await store.close()

    for location in [directory!, backupURL] {
      let reopened = MathQuestionStore(directory: location)
      let records = try await reopened.list(grade: 4, tags: tags)
      XCTAssertEqual(records.map(\.id), [question.id])
      XCTAssertEqual(records.first?.grade, 4)
      XCTAssertEqual(records.first?.ocrText, question.ocrText)
      let savedTags = try await reopened.tags(questionID: question.id)
      XCTAssertEqual(Set(savedTags), Set(tags))
      let original = try await reopened.originalImage(questionID: question.id)
      XCTAssertEqual(original, bytes)
      let answers = try await reopened.solutions(questionID: question.id)
      XCTAssertEqual(answers.first?.answer, solution.answer)
      XCTAssertEqual(answers.first?.verificationStatus, "confirmed")
      XCTAssertEqual(answers.first?.method, method)
      let references = try await reopened.referenceAnswers(questionID: question.id)
      XCTAssertEqual(references, [reference])
      let reviews = try await reopened.reviews(solutionID: solution.id)
      XCTAssertEqual(reviews, [review])
      let methods = try await reopened.methods()
      XCTAssertEqual(methods, [method])
      let config = try await reopened.storageConfiguration()
      XCTAssertEqual(config.schemaVersion, Int(MathQuestionArchive.supportedVersion))
      await reopened.close()
    }
  }

  func testCombinedFiltersRequireEveryExactConfirmedIdentity() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let knowledge = tag("shared", label: "整数乘法")
    let family = tag("family", axis: "problem_family", label: "乘积极值")
    let cases: [(String, Int, [MathQuestionTag])] = [
      ("target", 4, [knowledge, family]),
      ("missing", 4, [knowledge]),
      ("version", 4, [tag("shared", version: "old-v0"), family]),
      ("axis", 4, [tag("shared", axis: "custom"), family]),
      ("grade", 3, [knowledge, family]),
      ("suggested", 4, [tag("shared", origin: "ai", status: "suggested"), family]),
      ("rejected", 4, [tag("shared", origin: "ai", status: "rejected"), family]),
    ]
    var targetIDs = Set<String>()
    for (capture, grade, tags) in cases {
      let record = try await store.save(
        .init(captureID: capture, imageData: bytes, ocrText: "乘法 5%_"))
      try await store.updateClassification(questionID: record.id, grade: grade, tags: tags)
      if capture == "target" || capture == "suggested" { targetIDs.insert(record.id) }
    }
    for term in ["乘法", "%", "_", "%_"] {
      let found = try await store.list(query: term, grade: 4, tags: [knowledge, family])
      XCTAssertEqual(Set(found.map(\.id)), targetIDs)
    }
    let none = try await store.list(query: "' OR 1=1 --", grade: 4, tags: [knowledge, family])
    XCTAssertTrue(none.isEmpty)
    // The filter's display label and origin do not change its exact catalogue identity.
    let renamedFilter = tag("shared", label: "新名称", origin: "teacher")
    let same = try await store.list(grade: 4, tags: [renamedFilter, family])
    XCTAssertEqual(Set(same.map(\.id)), targetIDs)
    await store.close()
  }

  func testUnknownGradeRemainsNilAndClearingClassificationDoesNotDeleteQuestion() async throws {
    let store = MathQuestionStore(directory: directory)
    let question = try await store.save(.init(captureID: "unknown", imageData: try fixture()))
    XCTAssertNil(question.grade)
    let initiallyAll = try await store.list()
    let initiallyGrade = try await store.list(grade: 4)
    XCTAssertEqual(initiallyAll.map(\.id), [question.id])
    XCTAssertTrue(initiallyGrade.isEmpty)
    try await store.updateClassification(questionID: question.id, grade: 4, tags: [tag("a")])
    try await store.updateClassification(questionID: question.id, grade: nil, tags: [])
    let records = try await store.list()
    let savedTags = try await store.tags(questionID: question.id)
    XCTAssertEqual(records.map(\.id), [question.id])
    XCTAssertNil(records.first?.grade)
    XCTAssertEqual(savedTags.map(\.status), ["rejected"])
    await store.close()
  }

  func testCustomLegacyLabelsAndSuggestedMetadataSurviveManualSnapshotSave() async throws {
    let store = MathQuestionStore(directory: directory)
    let question = try await store.save(.init(captureID: "legacy", imageData: try fixture()))
    let old = tag(
      "unknown-old-id", version: "obsolete-catalogue", label: "旧目录标签", origin: "teacher")
    let rejected = tag(
      "old-rejected", version: "obsolete-catalogue", origin: "ai", status: "rejected")
    let suggested = tag(
      "old-suggestion", version: "obsolete-catalogue", origin: "ai", status: "suggested")
    let custom = tag("%_ ' OR 1=1 --", axis: "custom", version: "local", label: "用户自定义")
    try await store.updateClassification(
      questionID: question.id, grade: nil, tags: [old, rejected, suggested])
    var snapshot = try await store.tags(questionID: question.id)
    snapshot.append(custom)
    try await store.updateClassification(questionID: question.id, grade: 4, tags: snapshot)
    let saved = try await store.tags(questionID: question.id)
    XCTAssertEqual(Set(saved), Set(snapshot))
    let found = try await store.list(tags: [custom, old])
    XCTAssertEqual(found.map(\.id), [question.id])
    let options = try await store.tagOptions()
    XCTAssertEqual(Set(options.map(\.key)), Set([old.key, custom.key, suggested.key]))
    await store.close()
  }

  func testTagOptionsDeduplicateIdentityAndExcludeDeletedSuggestedAndRejected() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let first = try await store.save(.init(captureID: "one", imageData: bytes))
    let second = try await store.save(.init(captureID: "two", imageData: bytes))
    let deleted = try await store.save(.init(captureID: "deleted", imageData: bytes))
    try await store.updateClassification(
      questionID: first.id, grade: 4,
      tags: [
        tag("same", label: "乘法"), tag("suggested", status: "suggested"),
        tag("rejected", status: "rejected"),
      ])
    try await store.updateClassification(
      questionID: second.id, grade: 4,
      tags: [tag("same", label: "整数乘法", origin: "teacher"), tag("same", version: "old")])
    try await store.updateClassification(
      questionID: deleted.id, grade: 4, tags: [tag("deleted-only")])
    try await store.delete(questionID: deleted.id)
    let options = try await store.tagOptions()
    XCTAssertEqual(options.count, 2)
    XCTAssertEqual(
      Set(options.map(\.key)), Set([tag("same").key, tag("same", version: "old").key]))
    let filtered = try await store.list(tags: [tag("deleted-only")])
    XCTAssertTrue(filtered.isEmpty)
    try await store.restore(questionID: deleted.id)
    let restored = try await store.list(tags: [tag("deleted-only")])
    XCTAssertEqual(restored.map(\.id), [deleted.id])
    await store.close()
  }

  func testInvalidClassificationAndDuplicateIdentityLeaveOldSnapshotUntouched() async throws {
    let store = MathQuestionStore(directory: directory)
    let question = try await store.save(.init(captureID: "one", imageData: try fixture()))
    let original = tag("original")
    try await store.updateClassification(questionID: question.id, grade: 4, tags: [original])
    let bad: [(Int?, [MathQuestionTag])] = [
      (0, []), (7, []), (4, [tag("bad", axis: "error_cause")]),
      (4, [tag(" ")]), (4, [tag("bad", version: "")]), (4, [tag("bad", label: " ")]),
      (4, [tag("bad", origin: "model")]), (4, [tag("bad", status: "verified")]),
      (5, [original, tag("original", label: "不同名字")]),
    ]
    for (grade, tags) in bad {
      do {
        try await store.updateClassification(questionID: question.id, grade: grade, tags: tags)
        XCTFail("Invalid classification accepted")
      } catch {}
      let records = try await store.list()
      let saved = try await store.tags(questionID: question.id)
      XCTAssertEqual(records.first?.grade, 4)
      XCTAssertEqual(saved, [original])
    }
    do {
      try await store.updateClassification(questionID: "missing", grade: 4, tags: [original])
      XCTFail("Missing question accepted")
    } catch MathQuestionStoreError.notFound {} catch { XCTFail("Unexpected error \(error)") }
    await store.close()
  }

  func testDatabaseWriteFailureRollsBackGradeAndDeletedTags() async throws {
    let store = MathQuestionStore(directory: directory)
    let question = try await store.save(.init(captureID: "one", imageData: try fixture()))
    let original = tag("original")
    try await store.updateClassification(questionID: question.id, grade: 4, tags: [original])
    try rawSQL(
      """
      CREATE TRIGGER block_test_tag BEFORE INSERT ON question_tags
      WHEN NEW.tag_id = 'blocked' BEGIN SELECT RAISE(ABORT, 'test insertion failed'); END
      """)
    do {
      try await store.updateClassification(
        questionID: question.id, grade: 5, tags: [tag("blocked")])
      XCTFail("Failed insertion accepted")
    } catch {}
    let records = try await store.list()
    let saved = try await store.tags(questionID: question.id)
    XCTAssertEqual(records.first?.grade, 4)
    XCTAssertEqual(saved, [original])
    await store.close()
  }

  func testAxisEditAndGradeChangePreserveOtherDimensionsAndProvenance() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "inline-axis", imageData: fixture()))
    let knowledge = tag("multiply", origin: "ai", status: "suggested")
    let form = tag("fill", axis: "question_form", origin: "teacher")
    let family = tag("extrema", axis: "problem_family")
    try await store.updateClassification(
      questionID: record.id, grade: 4, tags: [knowledge, form, family])
    let replacement = tag("choice", axis: "question_form")
    try await store.updateTagAxis(questionID: record.id, axis: "question_form", tags: [replacement])
    var tags = try await store.tags(questionID: record.id)
    XCTAssertTrue(tags.contains(knowledge))
    XCTAssertTrue(tags.contains(family))
    XCTAssertTrue(tags.contains(replacement))
    XCTAssertTrue(tags.contains { $0.key == form.key && $0.status == "rejected" })
    try await store.updateQuestionGrade(questionID: record.id, grade: 3)
    let afterGrade = try await store.tags(questionID: record.id)
    XCTAssertEqual(Set(afterGrade), Set(tags))
    let other = MathQuestionStore(directory: directory)
    let newKnowledge = tag("divide")
    try await other.updateTagAxis(
      questionID: record.id, axis: "curriculum_knowledge", tags: [newKnowledge])
    try await store.updateTagAxis(questionID: record.id, axis: "problem_family", tags: [])
    tags = try await store.tags(questionID: record.id)
    XCTAssertTrue(tags.contains(newKnowledge))
    XCTAssertTrue(tags.contains(replacement))
    let current = try await store.list()
    XCTAssertEqual(current.first?.grade, 3)
    let bytes = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(bytes, try fixture())
    await other.close()
    await store.close()
  }

  func testAxisEditRejectsCrossDimensionInputWithoutChangingSnapshot() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "inline-invalid", imageData: fixture()))
    let knowledge = tag("multiply", origin: "ai", status: "suggested")
    try await store.updateClassification(questionID: record.id, grade: 4, tags: [knowledge])
    do {
      try await store.updateTagAxis(questionID: record.id, axis: "question_form", tags: [knowledge])
      XCTFail("Cross-dimension edits must fail")
    } catch {}
    let tags = try await store.tags(questionID: record.id)
    XCTAssertEqual(tags, [knowledge])
    await store.close()
  }

  func testTagIdentityUsesAllThreeFieldsWithoutDelimiterCollisions() throws {
    let first = tag("b:c", axis: "custom", version: "d")
    let second = tag("b", axis: "custom", version: "c:d")
    XCTAssertNotEqual(first.key, second.key)
    XCTAssertEqual(first.key, tag("b:c", axis: "custom", version: "d", label: "renamed").key)
    let decoded = try JSONDecoder().decode(MathQuestionTag.self, from: JSONEncoder().encode(first))
    XCTAssertEqual(decoded, first)
  }
}
