import CSQLite
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum MathQuestionStoreError: LocalizedError {
  case invalidImage, invalidCapture, notFound, conflictingCapture, damagedImage
  case incompatibleDatabase
  case newerDatabase(Int)
  case backupDestinationExists
  case database(String)

  var errorDescription: String? {
    switch self {
    case .invalidImage: return "原图不是完整可读取的 PNG 或 JPEG，未保存题目。"
    case .invalidCapture: return "截图标识为空，未保存题目。"
    case .notFound: return "找不到这道题目。"
    case .conflictingCapture: return "同一截图标识对应不同原图，未覆盖已保存题目。"
    case .damagedImage: return "题目原图缺失或校验不一致，请从备份恢复。"
    case .incompatibleDatabase: return "题库数据库损坏或格式不兼容，未重建或覆盖。"
    case .newerDatabase(let version): return "题库版本 \(version) 高于当前应用支持的版本，请升级应用。"
    case .backupDestinationExists: return "请选择尚不存在的备份目录，避免覆盖已有文件。"
    case .database(let message): return "本机题库操作失败：\(message)"
    }
  }
}

/// A separate, local photo archive. OCR is replaceable search text; it never owns the original.
actor MathQuestionStore {
  nonisolated let directory: URL
  // The owner alone closes the connection. Its handle never leaves this actor's synchronous
  // methods; @unchecked Sendable covers only transfer of ownership into deinitialization.
  private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close_v2(handle) }
  }
  private var connection: Connection?
  private static let applicationID: Int64 = 0x4D41_5448
  private static let schemaVersion: Int64 = 1
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/VocabCapture/math-questions", isDirectory: true)
  }

  func save(_ request: MathQuestionSaveRequest) throws -> MathQuestionRecord {
    guard !request.captureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MathQuestionStoreError.invalidCapture
    }
    let image = try Self.inspectImage(request.imageData)
    let db = try database()
    let hash = Self.digest(request.imageData)
    let filename = "\(hash).\(image.extensionName)"
    // The byte-identical, synced original must exist before a committed record can reference it.
    try persistOriginal(request.imageData, filename: filename)
    let id = try transaction(db) {
      if let existing = try query(
        db,
        "SELECT id, asset_id FROM questions WHERE capture_id = ?", [.text(request.captureID)],
        map: { (Self.text($0, 0), Self.text($0, 1)) }
      ).first {
        guard existing.1 == hash else { throw MathQuestionStoreError.conflictingCapture }
        try execute(
          db, "UPDATE questions SET updated_at = ? WHERE id = ?",
          [.real(Date().timeIntervalSinceReferenceDate), .text(existing.0)])
        try appendSolutions(request.solutions, questionID: existing.0, db: db)
        // A later OCR result can fill an empty index without overwriting user-reviewed text.
        if !request.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          try execute(
            db,
            """
            UPDATE question_ocr SET text = ?, status = 'ready', updated_at = ?
            WHERE question_id = ? AND status != 'ready'
            """,
            [
              .text(request.ocrText), .real(Date().timeIntervalSinceReferenceDate),
              .text(existing.0),
            ])
        }
        let indexed = try record(existing.0, db: db)
        if indexed.ocrStatus == "ready" {
          try nameUnnamedQuestion(existing.0, text: indexed.ocrText, db: db)
        }
        return existing.0
      }
      let now = Date().timeIntervalSinceReferenceDate
      let id = UUID().uuidString
      try execute(
        db,
        """
        INSERT INTO image_assets(id, filename, media_type, byte_count, width, height, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """,
        [
          .text(hash), .text(filename), .text(image.mediaType),
          .integer(Int64(request.imageData.count)),
          .integer(Int64(image.width)), .integer(Int64(image.height)), .real(now),
        ])
      try execute(
        db,
        """
        INSERT INTO questions(id, capture_id, asset_id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          .text(id), .text(request.captureID), .text(hash),
          .text(Self.suggestedTitle(from: request.ocrText) ?? "未命名题目"), .real(now), .real(now),
        ])
      let status =
        request.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "pending" : "ready"
      try execute(
        db, "INSERT INTO question_ocr(question_id, text, status, updated_at) VALUES (?, ?, ?, ?)",
        [.text(id), .text(request.ocrText), .text(status), .real(now)])
      try appendSolutions(request.solutions, questionID: id, db: db)
      return id
    }
    return try record(id, db: db)
  }

  func list(query search: String = "") throws -> [MathQuestionRecord] {
    let db = try database()
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return try query(
      db,
      Self.recordSelect + " " + """
        WHERE q.deleted_at IS NULL AND (? = '' OR instr(lower(q.title), lower(?)) > 0
          OR instr(lower(o.text), lower(?)) > 0)
        ORDER BY q.created_at DESC, q.id
        """, [.text(term), .text(term), .text(term)], map: Self.readRecord)
  }

  func originalImage(questionID: String) throws -> Data {
    let db = try database()
    guard
      let asset = try query(
        db,
        """
        SELECT a.id, a.filename FROM questions q JOIN image_assets a ON a.id = q.asset_id WHERE q.id = ?
        """, [.text(questionID)], map: { (Self.text($0, 0), Self.text($0, 1)) }
      ).first
    else {
      throw MathQuestionStoreError.notFound
    }
    return try verifiedOriginal(hash: asset.0, filename: asset.1)
  }

  func solutions(questionID: String) throws -> [MathQuestionSolution] {
    let db = try database()
    _ = try record(questionID, db: db)
    return try query(
      db,
      """
      SELECT id, question, answer, model, created_at FROM question_solutions
      WHERE question_id = ? ORDER BY created_at, id
      """, [.text(questionID)],
      map: {
        MathQuestionSolution(
          id: Self.text($0, 0), question: Self.text($0, 1),
          answer: Self.text($0, 2), model: Self.text($0, 3),
          createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 4)))
      })
  }

  func updateOCR(questionID: String, text: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    // An empty completed recognition is distinct from an unstarted job.
    try transaction(db) {
      try execute(
        db,
        "UPDATE question_ocr SET text = ?, status = 'ready', updated_at = ? WHERE question_id = ?",
        [.text(text), .real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
      try nameUnnamedQuestion(questionID, text: text, db: db)
    }
  }

  /// Titles are navigation metadata; the original image and complete OCR index stay intact.
  private static func suggestedTitle(from text: String) -> String? {
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"^\d+\s*[.．、:：)）]\s*"#, with: "", options: .regularExpression)
    }.filter { $0.count > 1 && $0.rangeOfCharacter(from: .letters) != nil }
    let line =
      lines.first { $0.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil }
      ?? lines.first
    guard let line else { return nil }
    return line.count > 32 ? String(line.prefix(32)) + "…" : line
  }

  private func nameUnnamedQuestion(_ id: String, text: String, db: OpaquePointer) throws {
    guard let title = Self.suggestedTitle(from: text) else { return }
    try execute(
      db, "UPDATE questions SET title = ? WHERE id = ? AND title = '未命名题目'",
      [.text(title), .text(id)])
  }

  func markOCRFailure(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    try execute(
      db, "UPDATE question_ocr SET status = 'failed', updated_at = ? WHERE question_id = ?",
      [.real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
  }

  func rename(questionID: String, title: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    try execute(
      db, "UPDATE questions SET title = ?, updated_at = ? WHERE id = ?",
      [
        .text(normalized.isEmpty ? "未命名题目" : normalized),
        .real(Date().timeIntervalSinceReferenceDate), .text(questionID),
      ])
  }

  func delete(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    let now = Date().timeIntervalSinceReferenceDate
    try execute(
      db, "UPDATE questions SET deleted_at = ?, updated_at = ? WHERE id = ?",
      [.real(now), .real(now), .text(questionID)])
  }

  func restore(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    try execute(
      db, "UPDATE questions SET deleted_at = NULL, updated_at = ? WHERE id = ?",
      [.real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
  }

  /// Creates a new directory containing a SQLite snapshot and every referenced original,
  /// including soft-deleted questions. WAL files are never copied as a backup strategy.
  func backup(to destination: URL) throws {
    let db = try database()
    let manager = FileManager.default
    guard !manager.fileExists(atPath: destination.path) else {
      throw MathQuestionStoreError.backupDestinationExists
    }
    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(
      ".math-backup-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var completed = false
    defer { if !completed { try? manager.removeItem(at: staging) } }
    var snapshot: OpaquePointer?
    let snapshotURL = staging.appendingPathComponent("questions.sqlite")
    guard
      sqlite3_open_v2(snapshotURL.path, &snapshot, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        == SQLITE_OK,
      let snapshot
    else {
      if let snapshot { sqlite3_close_v2(snapshot) }
      throw MathQuestionStoreError.database("无法创建备份数据库")
    }
    defer { sqlite3_close_v2(snapshot) }
    guard let copier = sqlite3_backup_init(snapshot, "main", db, "main") else {
      throw databaseError(snapshot)
    }
    // Bounded retries handle a separate process briefly writing to this local database.
    var result: Int32 = SQLITE_OK
    var busyRetries = 0
    repeat {
      result = sqlite3_backup_step(copier, 128)
      if result == SQLITE_BUSY || result == SQLITE_LOCKED {
        busyRetries += 1
        if busyRetries < 50 { sqlite3_sleep(20) }
      }
    } while result == SQLITE_OK
      || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyRetries < 50)
    let finish = sqlite3_backup_finish(copier)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw databaseError(snapshot) }
    let assets = try query(
      snapshot, "SELECT id, filename FROM image_assets",
      map: {
        (Self.text($0, 0), Self.text($0, 1))
      })
    let assetDirectory = staging.appendingPathComponent("assets", isDirectory: true)
    try manager.createDirectory(at: assetDirectory, withIntermediateDirectories: false)
    for asset in assets {
      let bytes = try verifiedOriginal(hash: asset.0, filename: asset.1)
      try Self.writeSynced(bytes, to: assetDirectory.appendingPathComponent(asset.1))
    }
    try Self.syncDirectory(assetDirectory)
    let handle = try FileHandle(forWritingTo: snapshotURL)
    defer { try? handle.close() }
    try handle.synchronize()
    try Self.syncDirectory(staging)
    try manager.moveItem(at: staging, to: destination)
    try Self.syncDirectory(parent)
    completed = true
  }

  // Explicitly closes the actor-owned connection for export/reopen tests and shutdown.
  func close() {
    connection = nil
  }

  func storageConfiguration() throws -> (
    foreignKeys: Bool, journalMode: String, synchronous: Int, schemaVersion: Int
  ) {
    let db = try database()
    return (
      try integerPragma(db, "PRAGMA foreign_keys") == 1,
      try query(db, "PRAGMA journal_mode", map: { Self.text($0, 0) }).first ?? "",
      Int(try integerPragma(db, "PRAGMA synchronous")),
      Int(try integerPragma(db, "PRAGMA user_version"))
    )
  }

  private static let recordSelect = """
    SELECT q.id, q.title, q.created_at, a.width, a.height, o.text, o.status
    FROM questions q JOIN image_assets a ON a.id = q.asset_id
    JOIN question_ocr o ON o.question_id = q.id
    """

  private static func readRecord(_ statement: OpaquePointer) -> MathQuestionRecord {
    MathQuestionRecord(
      id: text(statement, 0), title: text(statement, 1),
      createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
      imageWidth: Int(sqlite3_column_int64(statement, 3)),
      imageHeight: Int(sqlite3_column_int64(statement, 4)),
      ocrText: text(statement, 5), ocrStatus: text(statement, 6))
  }

  private func record(_ id: String, db: OpaquePointer) throws -> MathQuestionRecord {
    guard
      let record = try query(
        db, Self.recordSelect + " WHERE q.id = ?", [.text(id)],
        map: Self.readRecord
      ).first
    else { throw MathQuestionStoreError.notFound }
    return record
  }

  private func appendSolutions(
    _ solutions: [MathQuestionSolution], questionID: String,
    db: OpaquePointer
  ) throws {
    for solution in solutions {
      guard !solution.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      if let owner = try query(
        db, "SELECT question_id FROM question_solutions WHERE id = ?",
        [.text(solution.id)], map: { Self.text($0, 0) }
      ).first,
        owner != questionID
      {
        throw MathQuestionStoreError.database("解答标识已经归属于另一道题目")
      }
      // Store only the model identifier, never endpoint or authentication configuration.
      guard !solution.model.contains("://"), !solution.model.lowercased().contains("bearer "),
        !solution.model.hasPrefix("sk-"), solution.model.utf8.count <= 128
      else {
        throw MathQuestionStoreError.database("解答的模型字段必须为模型名称")
      }
      try execute(
        db,
        """
        INSERT INTO question_solutions(id, question_id, question, answer, model, created_at)
        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """,
        [
          .text(solution.id), .text(questionID), .text(solution.question), .text(solution.answer),
          .text(solution.model), .real(solution.createdAt.timeIntervalSinceReferenceDate),
        ])
    }
  }

  private func database() throws -> OpaquePointer {
    if let connection { return connection.handle }
    let manager = FileManager.default
    let url = directory.appendingPathComponent("questions.sqlite")
    let existed = manager.fileExists(atPath: url.path)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let db
    else {
      if let db { sqlite3_close_v2(db) }
      throw MathQuestionStoreError.incompatibleDatabase
    }
    do {
      sqlite3_busy_timeout(db, 5000)
      try execute(db, "PRAGMA foreign_keys = ON")
      let version = try integerPragma(db, "PRAGMA user_version")
      if version > Self.schemaVersion { throw MathQuestionStoreError.newerDatabase(Int(version)) }
      if existed {
        guard version == Self.schemaVersion,
          try integerPragma(db, "PRAGMA application_id") == Self.applicationID,
          try query(db, "PRAGMA quick_check", map: { Self.text($0, 0) }) == ["ok"],
          try query(db, "PRAGMA foreign_key_check", map: { Self.text($0, 0) }).isEmpty
        else {
          throw MathQuestionStoreError.incompatibleDatabase
        }
        // Verify the complete expected schema before any write pragmas or business mutations.
        _ = try query(db, Self.recordSelect + " LIMIT 0", map: Self.readRecord)
        _ = try query(
          db, "SELECT id, filename, media_type, byte_count FROM image_assets LIMIT 0",
          map: { Self.text($0, 0) })
        _ = try query(
          db,
          "SELECT id, question_id, question, answer, model, created_at FROM question_solutions LIMIT 0",
          map: { Self.text($0, 0) })
        _ = try query(
          db,
          "SELECT question_id, axis, tag_id, catalogue_version, label, origin, status FROM question_tags LIMIT 0",
          map: { Self.text($0, 0) })
        _ = try query(
          db, "SELECT capture_id, grade, updated_at, deleted_at FROM questions LIMIT 0",
          map: { Self.text($0, 0) })
      }
      guard try query(db, "PRAGMA journal_mode = WAL", map: { Self.text($0, 0) }).first == "wal"
      else {
        throw MathQuestionStoreError.database("无法启用题库日志")
      }
      try execute(db, "PRAGMA synchronous = FULL")
      if !existed {
        try transaction(db) {
          try executeScript(db, Self.schema)
          try execute(db, "PRAGMA application_id = \(Self.applicationID)")
          try execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
        }
      }
      try manager.createDirectory(
        at: directory.appendingPathComponent("assets", isDirectory: true),
        withIntermediateDirectories: true)
      // Older photo-only saves already have an index but retained the placeholder title.
      let unnamed = try query(
        db,
        """
        SELECT q.id, o.text FROM questions q JOIN question_ocr o ON o.question_id = q.id
        WHERE q.title = '未命名题目' AND o.status = 'ready'
        """, map: { (Self.text($0, 0), Self.text($0, 1)) })
      if !unnamed.isEmpty {
        try transaction(db) {
          for (id, text) in unnamed { try nameUnnamedQuestion(id, text: text, db: db) }
        }
      }
      connection = Connection(db)
      return db
    } catch {
      sqlite3_close_v2(db)
      throw error
    }
  }

  // Timestamp REAL values use Foundation reference-date seconds (2001-01-01 UTC),
  // preserving Date precision exactly across SQLite and Codable round trips.
  private static let schema = """
    CREATE TABLE image_assets (
      id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE,
      media_type TEXT NOT NULL CHECK(media_type IN ('image/png','image/jpeg')),
      byte_count INTEGER NOT NULL CHECK(byte_count > 0),
      width INTEGER NOT NULL CHECK(width > 0), height INTEGER NOT NULL CHECK(height > 0),
      created_at REAL NOT NULL
    );
    CREATE TABLE questions (
      id TEXT PRIMARY KEY, capture_id TEXT NOT NULL UNIQUE,
      asset_id TEXT NOT NULL REFERENCES image_assets(id), title TEXT NOT NULL,
      grade INTEGER CHECK(grade BETWEEN 1 AND 6),
      created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL
    );
    CREATE INDEX questions_visible ON questions(deleted_at, created_at);
    CREATE TABLE question_ocr (
      question_id TEXT PRIMARY KEY REFERENCES questions(id), text TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','ready','failed')),
      updated_at REAL NOT NULL
    );
    CREATE TABLE question_solutions (
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES questions(id),
      question TEXT NOT NULL, answer TEXT NOT NULL, model TEXT NOT NULL, created_at REAL NOT NULL,
      source TEXT NOT NULL DEFAULT 'ai' CHECK(source = 'ai'),
      verification_status TEXT NOT NULL DEFAULT 'unverified' CHECK(verification_status IN ('unverified','confirmed','rejected'))
    );
    CREATE INDEX solutions_question ON question_solutions(question_id, created_at);
    CREATE TABLE question_tags (
      question_id TEXT NOT NULL REFERENCES questions(id),
      axis TEXT NOT NULL CHECK(axis IN ('question_form','curriculum_knowledge','problem_family','custom')),
      tag_id TEXT NOT NULL, catalogue_version TEXT NOT NULL, label TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN ('user','teacher','ai')),
      status TEXT NOT NULL DEFAULT 'suggested' CHECK(status IN ('suggested','confirmed','rejected')),
      PRIMARY KEY(question_id, axis, tag_id, catalogue_version)
    );
    """

  private func persistOriginal(_ bytes: Data, filename: String) throws {
    let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
    let url = assetDirectory.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == bytes else { throw MathQuestionStoreError.damagedImage }
    } else {
      try Self.writeSynced(bytes, to: url)
      try Self.syncDirectory(assetDirectory)
    }
  }

  private func verifiedOriginal(hash: String, filename: String) throws -> Data {
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
      filename == "\(hash).png" || filename == "\(hash).jpg",
      let bytes = try? Data(
        contentsOf: directory.appendingPathComponent("assets").appendingPathComponent(filename)),
      Self.digest(bytes) == hash
    else { throw MathQuestionStoreError.damagedImage }
    return bytes
  }

  private static func writeSynced(_ bytes: Data, to url: URL) throws {
    try bytes.write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  private static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw MathQuestionStoreError.database("无法打开原图目录") }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw MathQuestionStoreError.database("无法同步原图目录") }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct ImageInfo {
    let width: Int
    let height: Int
    let mediaType: String
    let extensionName: String
  }

  private static func inspectImage(_ data: Data) throws -> ImageInfo {
    guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
      let type = CGImageSourceGetType(source) as String?,
      type == "public.png" || type == "public.jpeg",
      let image = CGImageSourceCreateImageAtIndex(
        source, 0,
        [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
          as CFDictionary),
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      image.width > 0, image.height > 0
    else { throw MathQuestionStoreError.invalidImage }
    if type == "public.png" {
      guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        data.suffix(12) == Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
      else {
        throw MathQuestionStoreError.invalidImage
      }
    } else {
      guard data.starts(with: [255, 216]), data.suffix(2) == Data([255, 217]) else {
        throw MathQuestionStoreError.invalidImage
      }
    }
    return ImageInfo(
      width: image.width, height: image.height,
      mediaType: type == "public.png" ? "image/png" : "image/jpeg",
      extensionName: type == "public.png" ? "png" : "jpg")
  }

  private enum Value {
    case text(String)
    case integer(Int64)
    case real(Double)
  }

  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let bytes = sqlite3_column_text(statement, index) else { return "" }
    return String(
      decoding: UnsafeBufferPointer(
        start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
  }

  private func databaseError(_ db: OpaquePointer) -> MathQuestionStoreError {
    .database(String(cString: sqlite3_errmsg(db)))
  }

  private func statement(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws
    -> OpaquePointer
  {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
      throw databaseError(db)
    }
    do {
      for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        let code: Int32
        switch value {
        case .text(let text):
          code = text.withCString {
            sqlite3_bind_text(result, index, $0, Int32(text.utf8.count), Self.transient)
          }
        case .integer(let number): code = sqlite3_bind_int64(result, index, number)
        case .real(let number): code = sqlite3_bind_double(result, index, number)
        }
        guard code == SQLITE_OK else { throw databaseError(db) }
      }
      return result
    } catch {
      sqlite3_finalize(result)
      throw error
    }
  }

  private func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
    let statement = try statement(db, sql, values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
  }

  private func executeScript(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(db) }
  }

  private func query<T>(
    _ db: OpaquePointer, _ sql: String, _ values: [Value] = [],
    map: (OpaquePointer) throws -> T
  ) throws -> [T] {
    let statement = try statement(db, sql, values)
    defer { sqlite3_finalize(statement) }
    var result: [T] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      result.append(try map(statement))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw databaseError(db) }
    return result
  }

  private func integerPragma(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
    try query(db, sql, map: { sqlite3_column_int64($0, 0) }).first ?? 0
  }

  private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
    try execute(db, "BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute(db, "COMMIT")
      return value
    } catch {
      try? execute(db, "ROLLBACK")
      throw error
    }
  }
}
