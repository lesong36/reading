import CSQLite
import Foundation
import XCTest

@testable import VocabCapture

final class MathMethodImportTests: XCTestCase {
  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
  }
  private func write(_ text: String, _ name: String, in folder: URL) throws {
    try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  @discardableResult
  private func sql(_ text: String, in directory: URL) throws -> [[String]] {
    var connection: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(directory.appendingPathComponent("questions.sqlite").path, &connection),
      SQLITE_OK)
    let db = try XCTUnwrap(connection)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db))) }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      rows.append(
        (0..<sqlite3_column_count(statement)).map {
          sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
        })
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else {
      throw MathQuestionStoreError.database(String(cString: sqlite3_errmsg(db)))
    }
    return rows
  }

  func testReadsCompleteMarkdownAndUsesDirectoryCategoriesWithoutImportingDirectory() throws {
    let path = try folder()
    let body = "# 盈亏问题\n\n$$份数 = 总差 \\div 单差$$\n1. 先求差。\n[[鸡兔同笼]]\n"
    try write(body, "盈亏问题.md", in: path)
    try write("# 方法\n# 两个未知数\n- [[盈亏问题]]：总差除以单差。", "目录.md", in: path)
    try write("ignored", "other.txt", in: path)
    let entries = try MathMethodImporter.read(directory: path)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.instructions, body)
    XCTAssertEqual(entries.first?.category, "两个未知数")
    XCTAssertEqual(entries.first?.title, "盈亏问题")
    XCTAssertEqual(
      entries.first?.sourceID, try MathMethodImporter.read(directory: path).first?.sourceID)
  }

  func testRepeatImportsPreserveEditsAndArchivedEntries() async throws {
    let path = try folder()
    let database = try folder()
    try write("# 和差问题\n原始步骤", "和差问题.md", in: path)
    let entries = try MathMethodImporter.read(directory: path)
    let store = MathQuestionStore(directory: database)
    let first = try await store.importMethods(entries)
    XCTAssertEqual(first.imported, 1)
    let original = try await store.methods().first!
    let edited = try await store.saveMethod(
      id: original.id, title: "我的和差", category: "四年级", instructions: "用户新步骤")
    try write("# 和差问题\n外部新步骤", "和差问题.md", in: path)
    let again = try await store.importMethods(MathMethodImporter.read(directory: path))
    XCTAssertEqual(again.imported, 0)
    XCTAssertEqual(again.skipped, 0)
    XCTAssertEqual(again.conflicts, 1)
    let methods = try await store.methods()
    XCTAssertEqual(methods, [edited])
    try await store.archiveMethod(id: edited.id)
    let archived = try await store.importMethods(entries)
    XCTAssertEqual(archived.skipped, 1)
    let active = try await store.methods()
    XCTAssertTrue(active.isEmpty)
    await store.close()
  }

  func testAllLinksInDirectoryListReceiveCategory() throws {
    let path = try folder()
    for name in ["数形结合", "线段图", "列表法"] {
      try write("# \(name)\n步骤", "\(name).md", in: path)
    }
    try write("# 计数和图形\n- [[数形结合]]：[[线段图]]、[[列表法|表格]]。", "目录.md", in: path)
    let entries = try MathMethodImporter.read(directory: path)
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(Set(entries.map(\.category)), ["计数和图形"])
  }

  func testChangedSourceCreatesImmutableVersionAndUnchangedReimportIsIdempotent() async throws {
    let path = try folder()
    let database = try folder()
    let initial = "# 和差问题\n\n原始步骤\n"
    let revised = "# 和差问题\n\n新步骤：$$大数=(和+差)\\div 2$$\n"
    try write(initial, "和差问题.md", in: path)
    let store = MathQuestionStore(directory: database)
    _ = try await store.importMethods(MathMethodImporter.read(directory: path))
    let original = try await store.methods().first!
    try write(revised, "和差问题.md", in: path)
    let result = try await store.importMethods(MathMethodImporter.read(directory: path))
    XCTAssertEqual(result.imported, 0)
    XCTAssertEqual(result.updated, 1)
    XCTAssertEqual(result.skipped, 0)
    XCTAssertEqual(result.conflicts, 0)
    let current = try await store.methods().first!
    XCTAssertEqual(current.id, original.id)
    XCTAssertNotEqual(current.versionID, original.versionID)
    XCTAssertEqual(current.instructions, revised)
    XCTAssertEqual(
      try sql("SELECT instructions FROM teaching_method_versions ORDER BY rowid", in: database),
      [[initial], [revised]])
    let unchanged = try await store.importMethods(MathMethodImporter.read(directory: path))
    XCTAssertEqual(unchanged.updated, 0)
    XCTAssertEqual(unchanged.skipped, 1)
    XCTAssertEqual(try sql("SELECT count(*) FROM teaching_method_versions", in: database), [["2"]])
    await store.close()
    let reopened = MathQuestionStore(directory: database)
    let persisted = try await reopened.methods()
    XCTAssertEqual(persisted, [current])
    try write("# 和差问题\n再次更新\n", "和差问题.md", in: path)
    let next = try await reopened.importMethods(MathMethodImporter.read(directory: path))
    XCTAssertEqual(next.updated, 1)
    await reopened.close()
  }

  func testV3MigrationUsesEarliestImportedVersionAndProtectsManualEdits() async throws {
    let database = try folder()
    let clean = MathMethodImportEntry(
      sourceID: "markdown-clean", title: "干净方法", category: "", instructions: "原始步骤\n")
    let edited = MathMethodImportEntry(
      sourceID: "markdown-edited", title: "编辑方法", category: "", instructions: "原始内容\n")
    let archived = MathMethodImportEntry(
      sourceID: "markdown-archived", title: "归档方法", category: "", instructions: "归档内容\n")
    let store = MathQuestionStore(directory: database)
    _ = try await store.importMethods([clean, edited, archived])
    let local = try await store.saveMethod(
      id: edited.sourceID, title: edited.title, category: "", instructions: "用户编辑")
    let custom = try await store.saveMethod(title: "手工方法", category: "", instructions: "用户步骤")
    try await store.archiveMethod(id: archived.sourceID)
    await store.close()
    for table in ["method_candidate_evidence", "method_candidates", "skill_learning_reports", "skill_learning_jobs", "skill_lifecycle_events", "skill_profiles"] { try sql("DROP TABLE \(table)", in: database) }
    try sql("DROP TABLE solution_diagrams", in: database)
    try sql("ALTER TABLE question_solutions DROP COLUMN diagram_failure", in: database)
    try sql("DROP TABLE teaching_method_imports", in: database)
    try sql("PRAGMA user_version = 3", in: database)
    let reopened = MathQuestionStore(directory: database)
    let result = try await reopened.importMethods([
      .init(sourceID: clean.sourceID, title: clean.title, category: "新分类", instructions: "外部更新\n"),
      .init(sourceID: edited.sourceID, title: edited.title, category: "", instructions: "外部更新\n"),
      archived,
    ])
    XCTAssertEqual(result.updated, 1)
    XCTAssertEqual(result.conflicts, 1)
    XCTAssertEqual(result.skipped, 1)
    let active = try await reopened.methods()
    XCTAssertTrue(active.contains(local))
    XCTAssertTrue(active.contains(custom))
    XCTAssertFalse(active.contains { $0.id == archived.sourceID })
    XCTAssertEqual(try sql("SELECT count(*) FROM teaching_method_imports", in: database), [["3"]])
    XCTAssertEqual(try sql("SELECT count(*) FROM teaching_method_versions", in: database), [["6"]])
    XCTAssertEqual(try sql("PRAGMA user_version", in: database), [[String(MathQuestionArchive.supportedVersion)]])
    XCTAssertEqual(try sql("PRAGMA foreign_key_check", in: database), [])
    await reopened.close()
  }

  func testDatabaseFailureRollsBackUpdatesAndNewImportsTogether() async throws {
    let database = try folder()
    let store = MathQuestionStore(directory: database)
    let initial = MathMethodImportEntry(
      sourceID: "markdown-initial", title: "原方法", category: "", instructions: "原始步骤")
    _ = try await store.importMethods([initial])
    let original = try await store.methods()
    try sql(
      "CREATE TRIGGER fail_second_method BEFORE INSERT ON teaching_methods WHEN NEW.id = 'markdown-fail' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
      in: database)
    do {
      _ = try await store.importMethods([
        .init(sourceID: initial.sourceID, title: initial.title, category: "", instructions: "更新步骤"),
        .init(sourceID: "markdown-fail", title: "后一个方法", category: "", instructions: "新步骤"),
      ])
      XCTFail("Trigger should fail the complete import")
    } catch {}
    let after = try await store.methods()
    XCTAssertEqual(after, original)
    XCTAssertEqual(try sql("SELECT count(*) FROM teaching_method_versions", in: database), [["1"]])
    XCTAssertEqual(
      try sql("SELECT last_imported_version_id FROM teaching_method_imports", in: database),
      [[original.first!.versionID]])
    await store.close()
  }

  func testConcurrentReimportsCreateOnlyOneUpdatedVersion() async throws {
    let database = try folder()
    let one = MathQuestionStore(directory: database)
    let two = MathQuestionStore(directory: database)
    let original = MathMethodImportEntry(
      sourceID: "markdown-concurrent", title: "方法", category: "", instructions: "旧步骤")
    _ = try await one.importMethods([original])
    _ = try await two.methods()
    let revised = MathMethodImportEntry(
      sourceID: original.sourceID, title: original.title, category: "", instructions: "新步骤")
    async let first = one.importMethods([revised])
    async let second = two.importMethods([revised])
    let results = try await [first, second]
    XCTAssertEqual(results.map(\.updated).reduce(0, +), 1)
    XCTAssertEqual(results.map(\.skipped).reduce(0, +), 1)
    XCTAssertEqual(try sql("SELECT count(*) FROM teaching_method_versions", in: database), [["2"]])
    await one.close()
    await two.close()
  }

  func testInvalidEntryDoesNotLeavePartialImport() async throws {
    let store = MathQuestionStore(directory: try folder())
    let entries = [
      MathMethodImportEntry(sourceID: "valid", title: "有效", category: "", instructions: "步骤"),
      MathMethodImportEntry(sourceID: "invalid", title: "无效", category: "", instructions: " "),
    ]
    do {
      _ = try await store.importMethods(entries)
      XCTFail("Must reject")
    } catch {}
    let methods = try await store.methods()
    XCTAssertTrue(methods.isEmpty)
    await store.close()
  }

  func testRejectsInvalidUTF8EmptyAndOversizeFilesAndSymlinks() throws {
    let path = try folder()
    let file = path.appendingPathComponent("方法.md")
    for bytes in [Data([0xff]), Data(), Data(repeating: 65, count: 1_000_001)] {
      try bytes.write(to: file)
      XCTAssertThrowsError(try MathMethodImporter.read(directory: path))
    }
    try FileManager.default.removeItem(at: file)
    let external = try folder().appendingPathComponent("源.md")
    try Data("步骤".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
    XCTAssertThrowsError(try MathMethodImporter.read(directory: path))
  }

  func testEmptyFolderDoesNotImportDirectoryAsMethod() throws {
    let path = try folder()
    try write("# 方法\n- [[缺少的文件]]", "目录.md", in: path)
    XCTAssertThrowsError(try MathMethodImporter.read(directory: path))
  }
}
