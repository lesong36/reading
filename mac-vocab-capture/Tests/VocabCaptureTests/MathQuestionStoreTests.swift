import CSQLite
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import VocabCapture

final class MathQuestionStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "math-store-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func fixture(width: Int = 17, height: Int = 13, jpeg: Bool = false) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let result = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        result, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return result as Data
  }

  private func rawSQL(_ sql: String, foreignKeys: Bool = false) throws -> [String] {
    var connection: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        directory.appendingPathComponent("questions.sqlite").path, &connection,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
    let db = try XCTUnwrap(connection)
    defer { sqlite3_close(db) }
    if foreignKeys {
      XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil), SQLITE_OK)
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db)))
    }
    let prepared = try XCTUnwrap(statement)
    defer { sqlite3_finalize(prepared) }
    var rows: [String] = []
    var status = sqlite3_step(prepared)
    while status == SQLITE_ROW {
      if let text = sqlite3_column_text(prepared, 0) { rows.append(String(cString: text)) }
      status = sqlite3_step(prepared)
    }
    guard status == SQLITE_DONE else {
      throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db)))
    }
    return rows
  }

  func testPhotoOnlyArchiveKeepsBytesDimensionsAndReopens() async throws {
    let data = try fixture(width: 2100, height: 1800)
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "capture-only", imageData: data))
    XCTAssertEqual(record.imageWidth, 2100)
    XCTAssertEqual(record.imageHeight, 1800)
    XCTAssertEqual(record.ocrText, "")
    XCTAssertEqual(record.ocrStatus, "pending")
    let original = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(original, data)
    let answers = try await store.solutions(questionID: record.id)
    XCTAssertTrue(answers.isEmpty)
    await store.close()
    let reopened = MathQuestionStore(directory: directory)
    let records = try await reopened.list()
    XCTAssertEqual(records, [record])
    let restoredImage = try await reopened.originalImage(questionID: record.id)
    XCTAssertEqual(restoredImage, data)
    await reopened.close()
  }

  func testCaptureIsIdempotentAndCompletedSolutionsAppendOnlyOnce() async throws {
    let data = try fixture(jpeg: true)
    let store = MathQuestionStore(directory: directory)
    let first = try await store.save(.init(captureID: "same", imageData: data))
    let solution = MathQuestionSolution(
      id: "turn-1", question: "解题", answer: "完整回答", model: "deepseek-flash")
    let updated = try await store.save(
      .init(
        captureID: "same", imageData: data,
        ocrText: "题目",
        solutions: [
          solution, solution,
          .init(id: "blank", question: "解题", answer: " ", model: "gpt"),
        ]))
    XCTAssertEqual(first.id, updated.id)
    XCTAssertEqual(updated.ocrStatus, "ready")
    let records = try await store.list()
    XCTAssertEqual(records.count, 1)
    let answers = try await store.solutions(questionID: first.id)
    XCTAssertEqual(answers, [solution])
    let original = try await store.originalImage(questionID: first.id)
    XCTAssertEqual(original, data)
    // A new screenshot may intentionally represent the same question: deduplicate the file only.
    _ = try await store.save(.init(captureID: "other", imageData: data))
    XCTAssertEqual(try rawSQL("SELECT count(*) FROM image_assets"), ["1"])
    let two = try await store.list()
    XCTAssertEqual(two.count, 2)
    await store.close()
  }

  func testOCRNamesPhotoOnlyRecordWithoutChangingOriginalOrIndex() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let record = try await store.save(.init(captureID: "title", imageData: bytes))
    let text = "2\n同学们排成方队做操。这一队一共有多少人？\n从左往右数，我排在第4个。"
    try await store.updateOCR(questionID: record.id, text: text)
    let records = try await store.list()
    XCTAssertEqual(records.first?.title, "同学们排成方队做操。这一队一共有多少人？")
    XCTAssertEqual(records.first?.ocrText, text)
    let original = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(original, bytes)
    await store.close()
  }

  func testInitialOCRTitleSkipsNumberAndManualTitleSurvivesReindexAndAnswerSave() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let record = try await store.save(
      .init(captureID: "manual", imageData: bytes, ocrText: "4. 某工厂要生产一批消毒液。"))
    XCTAssertEqual(record.title, "某工厂要生产一批消毒液。")
    try await store.rename(questionID: record.id, title: "四年级 · 工程问题")
    try await store.updateOCR(questionID: record.id, text: "新的题干")
    let updated = try await store.save(
      .init(
        captureID: "manual", imageData: bytes, ocrText: "不能覆盖索引",
        solutions: [.init(question: "解题", answer: "完整回答", model: "test")]))
    XCTAssertEqual(updated.title, "四年级 · 工程问题")
    XCTAssertEqual(updated.ocrText, "新的题干")
    await store.close()
  }

  func testReopenBackfillsLegacyUnnamedTitleAndPreservesOtherData() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let answer = MathQuestionSolution(question: "解题", answer: "参考回答", model: "test")
    let record = try await store.save(
      .init(
        captureID: "legacy", imageData: bytes, ocrText: "2\n超市进货，白糖比食盐多多少千克？",
        solutions: [answer]))
    let manual = try await store.save(.init(captureID: "manual", imageData: bytes, ocrText: "题目"))
    try await store.rename(questionID: manual.id, title: "我的标题")
    await store.close()
    _ = try rawSQL("UPDATE questions SET title = '未命名题目' WHERE capture_id = 'legacy'")
    let reopened = MathQuestionStore(directory: directory)
    let records = try await reopened.list()
    XCTAssertEqual(records.first { $0.id == record.id }?.title, "超市进货，白糖比食盐多多少千克？")
    XCTAssertEqual(records.first { $0.id == manual.id }?.title, "我的标题")
    let answers = try await reopened.solutions(questionID: record.id)
    XCTAssertEqual(answers, [answer])
    let original = try await reopened.originalImage(questionID: record.id)
    XCTAssertEqual(original, bytes)
    await reopened.close()
  }

  func testTitlePrefersChineseOverNoiseAndBoundsLongTitles() async throws {
    let store = MathQuestionStore(directory: directory)
    let text = "OCR\n2\n" + String(repeating: "中文题干", count: 20)
    let record = try await store.save(
      .init(captureID: "long", imageData: try fixture(), ocrText: text))
    XCTAssertEqual(record.title, String(String(repeating: "中文题干", count: 20).prefix(32)) + "…")
    let english = try await store.save(
      .init(captureID: "english", imageData: try fixture(), ocrText: "9. How many rings are there?")
    )
    XCTAssertEqual(english.title, "How many rings are there?")
    await store.close()
  }

  func testChineseShortWordsAndWildcardCharactersAreLiteral() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let one = try await store.save(
      .init(captureID: "one", imageData: bytes, ocrText: "头盔单价 69元，百分比 5%_"))
    _ = try await store.save(.init(captureID: "two", imageData: bytes, ocrText: "普通题目"))
    for term in ["头盔", "%", "_", "%_"] {
      let found = try await store.list(query: term)
      XCTAssertEqual(found.map(\.id), [one.id])
    }
    try await store.rename(questionID: one.id, title: "Apple 小学数学")
    let titleFound = try await store.list(query: "apple")
    XCTAssertEqual(titleFound.map(\.id), [one.id])
    let injectionFound = try await store.list(query: "' OR 1=1 --")
    XCTAssertTrue(injectionFound.isEmpty)
    await store.close()
  }

  func testSoftDeleteRestoreAndOCRFailureNeverRemoveOriginal() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let record = try await store.save(.init(captureID: "one", imageData: bytes))
    try await store.markOCRFailure(questionID: record.id)
    var records = try await store.list()
    XCTAssertEqual(records.first?.ocrStatus, "failed")
    try await store.delete(questionID: record.id)
    records = try await store.list()
    XCTAssertTrue(records.isEmpty)
    let image = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(image, bytes)
    try await store.restore(questionID: record.id)
    try await store.updateOCR(questionID: record.id, text: "")
    records = try await store.list()
    XCTAssertEqual(records.first?.ocrStatus, "ready")
    XCTAssertEqual(records.first?.ocrText, "")
    await store.close()
  }

  func testRejectsMalformedAndTruncatedImagesWithoutCreatingArchiveRecords() async throws {
    let store = MathQuestionStore(directory: directory)
    let png = try fixture()
    let jpeg = try fixture(jpeg: true)
    let bad = [Data(), Data("not a photo".utf8), Data(png.dropLast(12)), Data(jpeg.dropLast(2))]
    for data in bad {
      do {
        _ = try await store.save(.init(captureID: "bad-\(data.count)", imageData: data))
        XCTFail("Malformed image was accepted")
      } catch MathQuestionStoreError.invalidImage {} catch { XCTFail("Unexpected error \(error)") }
    }
    let records = try await store.list()
    XCTAssertTrue(records.isEmpty)
    await store.close()
  }

  func testTransactionFailureCannotLeaveFakeQuestionAndCaptureConflictCannotOverwrite() async throws
  {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let record = try await store.save(.init(captureID: "original", imageData: bytes))
    do {
      _ = try await store.save(
        .init(
          captureID: "bad-model", imageData: bytes,
          solutions: [
            .init(question: "解题", answer: "答案", model: "https://provider.example/api?key=secret")
          ]))
      XCTFail("Endpoint cannot be stored as a model")
    } catch {}
    do {
      _ = try await store.save(.init(captureID: "original", imageData: try fixture(width: 19)))
      XCTFail("Conflicting capture cannot replace original")
    } catch MathQuestionStoreError.conflictingCapture {} catch {
      XCTFail("Unexpected error \(error)")
    }
    let records = try await store.list()
    XCTAssertEqual(records, [record])
    let original = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(original, bytes)
    await store.close()
  }

  func testCorruptDatabaseIsNotRecreatedOrOverwritten() async throws {
    let corrupt = Data("damaged database public fixture".utf8)
    let file = directory.appendingPathComponent("questions.sqlite")
    try corrupt.write(to: file)
    let store = MathQuestionStore(directory: directory)
    do {
      _ = try await store.list()
      XCTFail("Corrupt database must fail")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    await store.close()
  }

  func testNewerDatabaseIsRejectedWithoutResettingVersion() async throws {
    _ = try rawSQL("PRAGMA user_version = 99")
    let before = try Data(contentsOf: directory.appendingPathComponent("questions.sqlite"))
    let store = MathQuestionStore(directory: directory)
    do {
      _ = try await store.list()
      XCTFail("Future database must fail")
    } catch MathQuestionStoreError.newerDatabase(let version) { XCTAssertEqual(version, 99) } catch
    { XCTFail("Unexpected error \(error)") }
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("questions.sqlite")), before)
    await store.close()
  }

  func testBackupIsStandaloneAndIncludesDeletedPhotoAndSolution() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let answer = MathQuestionSolution(question: "解题", answer: "参考回答", model: "gpt")
    let record = try await store.save(
      .init(
        captureID: "backup", imageData: bytes,
        ocrText: "草坪", solutions: [answer]))
    try await store.delete(questionID: record.id)
    let backup = directory.appendingPathComponent("export")
    try await store.backup(to: backup)
    // Open the backup while the source is alive with its own WAL state.
    let copy = MathQuestionStore(directory: backup)
    let hidden = try await copy.list()
    XCTAssertTrue(hidden.isEmpty)
    try await copy.restore(questionID: record.id)
    let records = try await copy.list()
    XCTAssertEqual(records, [record])
    let original = try await copy.originalImage(questionID: record.id)
    XCTAssertEqual(original, bytes)
    let solutions = try await copy.solutions(questionID: record.id)
    XCTAssertEqual(solutions, [answer])
    do {
      try await store.backup(to: backup)
      XCTFail("Backup must not overwrite")
    } catch MathQuestionStoreError.backupDestinationExists {} catch {
      XCTFail("Unexpected error \(error)")
    }
    await copy.close()
    await store.close()
  }

  func testMissingOriginalFailsBackupWithoutPublishingPartialFolder() async throws {
    let store = MathQuestionStore(directory: directory)
    _ = try await store.save(.init(captureID: "missing", imageData: try fixture()))
    let assets = directory.appendingPathComponent("assets")
    for file in try FileManager.default.contentsOfDirectory(
      at: assets, includingPropertiesForKeys: nil)
    {
      try FileManager.default.removeItem(at: file)
    }
    let backup = directory.appendingPathComponent("broken-export")
    do {
      try await store.backup(to: backup)
      XCTFail("Missing photo must fail backup")
    } catch MathQuestionStoreError.damagedImage {} catch { XCTFail("Unexpected error \(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertFalse(files.contains { $0.hasPrefix(".math-backup-") })
    await store.close()
  }

  func testConnectionDurabilityAndSchemaGuardrails() async throws {
    let store = MathQuestionStore(directory: directory)
    _ = try await store.list()
    let settings = try await store.storageConfiguration()
    XCTAssertTrue(settings.foreignKeys)
    XCTAssertEqual(settings.journalMode, "wal")
    XCTAssertEqual(settings.synchronous, 2)
    XCTAssertEqual(settings.schemaVersion, 1)
    do {
      _ = try rawSQL(
        "INSERT INTO questions(id,capture_id,asset_id,title,grade,created_at,updated_at) VALUES ('bad','bad','missing','test',7,0,0)"
      )
      XCTFail("Grade must be within 1 through 6")
    } catch {}
    do {
      _ = try rawSQL(
        "INSERT INTO questions(id,capture_id,asset_id,title,grade,created_at,updated_at) VALUES ('orphan','orphan','missing','test',4,0,0)",
        foreignKeys: true)
      XCTFail("Question must reference a real asset")
    } catch {}
    do {
      _ = try rawSQL(
        "INSERT INTO question_tags(question_id,axis,tag_id,catalogue_version,label,origin) VALUES ('x','error_cause','cause','1','test','ai')"
      )
      XCTFail("Attempt-level causes must not be permanent question tags")
    } catch {}
    XCTAssertEqual(try rawSQL("SELECT count(*) FROM questions"), ["0"])
    await store.close()
  }

  func testRefusesUnversionedExistingDatabaseInsteadOfTreatingItAsEmpty() async throws {
    _ = try rawSQL("CREATE TABLE unrelated (value TEXT)")
    let before = try Data(contentsOf: directory.appendingPathComponent("questions.sqlite"))
    let store = MathQuestionStore(directory: directory)
    do {
      _ = try await store.list()
      XCTFail("Unversioned existing database must fail")
    } catch MathQuestionStoreError.incompatibleDatabase {} catch {
      XCTFail("Unexpected error \(error)")
    }
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent("questions.sqlite")), before)
    await store.close()
  }

  func testSolutionIdentifiersCannotBeReassignedToAnotherQuestion() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let solution = MathQuestionSolution(
      id: "stable-answer", question: "解题", answer: "回答", model: "kimi")
    let first = try await store.save(
      .init(captureID: "first", imageData: bytes, solutions: [solution]))
    do {
      _ = try await store.save(.init(captureID: "second", imageData: bytes, solutions: [solution]))
      XCTFail("Another question cannot adopt a solution identifier")
    } catch {}
    let records = try await store.list()
    XCTAssertEqual(records, [first])
    let answers = try await store.solutions(questionID: first.id)
    XCTAssertEqual(answers, [solution])
    await store.close()
  }

  func testConcurrentSeparateActorsRespectCaptureUniqueness() async throws {
    let one = MathQuestionStore(directory: directory)
    // Initialize the new schema before simulating independently opened clients.
    _ = try await one.list()
    let two = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    async let first = one.save(.init(captureID: "race", imageData: bytes))
    async let second = two.save(.init(captureID: "race", imageData: bytes))
    let (a, b) = try await (first, second)
    XCTAssertEqual(a.id, b.id)
    let records = try await one.list()
    XCTAssertEqual(records.count, 1)
    let original = try await two.originalImage(questionID: a.id)
    XCTAssertEqual(original, bytes)
    await one.close()
    await two.close()
  }

  func testLateAnswerAppendCannotResurrectSoftDeletedQuestion() async throws {
    let store = MathQuestionStore(directory: directory)
    let bytes = try fixture()
    let record = try await store.save(.init(captureID: "deleted", imageData: bytes))
    try await store.delete(questionID: record.id)
    let solution = MathQuestionSolution(question: "解题", answer: "刚完成的回答", model: "deepseek-flash")
    let appended = try await store.save(
      .init(captureID: "deleted", imageData: bytes, solutions: [solution]))
    XCTAssertEqual(appended.id, record.id)
    let hidden = try await store.list()
    XCTAssertTrue(hidden.isEmpty)
    let answers = try await store.solutions(questionID: record.id)
    XCTAssertEqual(answers, [solution])
    try await store.restore(questionID: record.id)
    let visible = try await store.list()
    XCTAssertEqual(visible.count, 1)
    await store.close()
  }
}
