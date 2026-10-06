import Foundation

actor VocabularyStore {
  private let directory: URL
  private let fileManager: FileManager
  private var fileURL: URL
  private var envelope = VocabularyEnvelope()
  private var legacyEntries: [VocabularyEntry] = []
  private var issue: VocabularyPersistenceError?
  private var accountGeneration: UInt64 = 0

  init(fileManager: FileManager = .default, directory: URL? = nil) {
    self.fileManager = fileManager
    self.directory = directory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true))
      .appendingPathComponent("VocabCapture", isDirectory: true)
    fileURL = Self.unsignedFileURL(directory: self.directory, fileManager: fileManager)
    // Never rewrite a legacy array merely because the app was launched.
    do {
      let loaded = try Self.loadUnsigned(directory: self.directory, fileManager: fileManager)
      fileURL = loaded.url
      envelope = loaded.envelope
      legacyEntries = loaded.legacy
    } catch {
      issue = Self.persistenceError(error)
    }
  }

  func activateAccount(userID: String?) throws {
    accountGeneration &+= 1
    // Switch even when loading fails: an unreadable B store cannot expose A's words.
    envelope = VocabularyEnvelope(userID: userID)
    legacyEntries = []
    issue = nil
    // A failed activation must not retain the previous account's export/recovery path.
    fileURL = Self.unsignedFileURL(directory: directory, fileManager: fileManager)
    do {
      if let userID {
        fileURL = try accountURL(userID)
        envelope = try Self.readEnvelope(at: fileURL, expectedUserID: userID, fileManager: fileManager)
      } else {
        let loaded = try Self.loadUnsigned(directory: directory, fileManager: fileManager)
        fileURL = loaded.url
        envelope = loaded.envelope
        legacyEntries = loaded.legacy
      }
    } catch {
      let failure = Self.persistenceError(error)
      issue = failure
      throw failure
    }
  }

  func writeScope() -> VocabularyWriteScope {
    VocabularyWriteScope(userID: envelope.userID, accountGeneration: accountGeneration)
  }

  func add(word: String, dictionary: DictionaryResult, context: String,
    scope: VocabularyWriteScope? = nil) throws -> VocabularyEntry {
    if let scope, scope != writeScope() { throw VocabularyPersistenceError.accountChanged }
    try requireWritable()
    let display = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = VocabularyEntry.canonicalWordKey(display)
    guard !key.isEmpty else { throw VocabularyError.invalidSelection }
    if let existing = all().first(where: { VocabularyEntry.canonicalWordKey($0.word) == key }) { return existing }
    let entry = VocabularyEntry(word: display, dictionary: dictionary, context: context)
    var next = envelope
    next.entries.insert(entry, at: 0)
    let deleted = next.tombstones.first(where: { $0.wordKey == key })
    next.pending.append(VocabularyMutation(operationID: UUID().uuidString,
      kind: deleted == nil ? .upsert : .restore, wordKey: key, entry: entry, baseVersion: deleted?.version))
    next.localRevision = try Self.incrementRevision(next.localRevision)
    try commit(next)
    return entry
  }

  func all() -> [VocabularyEntry] {
    // Unknown legacy ownership remains visible locally, never part of an account batch.
    let keys = Set(envelope.entries.map { VocabularyEntry.canonicalWordKey($0.word) })
    return (envelope.entries + legacyEntries.filter { !keys.contains(VocabularyEntry.canonicalWordKey($0.word)) })
      .sorted { $0.timestamp > $1.timestamp }
  }

  func pendingCount() -> Int { envelope.pending.count }

  func syncBatch() -> VocabularySyncBatch? {
    guard issue == nil, let userID = envelope.userID else { return nil }
    return VocabularySyncBatch(userID: userID, baseRevision: envelope.cloudRevision,
      operations: Array(envelope.pending.prefix(500)), accountGeneration: accountGeneration)
  }

  func status() -> VocabularyPersistenceStatus {
    VocabularyPersistenceStatus(userID: envelope.userID, pendingCount: envelope.pending.count,
      unassignedCount: envelope.userID == nil ? all().count : unassignedCount(),
      issue: issue?.localizedDescription ?? (envelope.adoption == nil ? nil : VocabularyPersistenceError.bindingInProgress.localizedDescription), fileURL: fileURL,
      backupURLs: (1...3).map { Self.backupURL(fileURL, number: $0) }.filter { fileManager.fileExists(atPath: $0.path) })
  }

  /// Compatibility for callers still using a snapshot. Pending operations remain durable.
  func applySync(_ updated: [VocabularyEntry], basedOn snapshot: [VocabularyEntry]) throws {
    try requireWritable()
    let previous = Set(snapshot.map(\.id))
    let changes = envelope.entries.filter { !previous.contains($0.id) || !snapshot.contains($0) }
    var next = envelope
    next.entries = Self.merge(updated, additions: changes)
    next.localRevision = try Self.incrementRevision(next.localRevision)
    try commit(next)
  }

  func acknowledgeSync(vocabulary: [VocabularyEntry], revision: Int64,
    acknowledgedOperationIDs: [String], basedOn batch: VocabularySyncBatch,
    tombstones: [VocabularyTombstone] = []) throws {
    try requireWritable()
    guard envelope.userID == batch.userID, accountGeneration == batch.accountGeneration else {
      throw VocabularyPersistenceError.accountChanged
    }
    let submitted = Set(batch.operations.map(\.operationID))
    let acknowledged = Set(acknowledgedOperationIDs)
    guard acknowledged.isSubset(of: submitted), revision >= envelope.cloudRevision else {
      throw VocabularyPersistenceError.unknownOperations
    }
    var next = envelope
    next.pending.removeAll { acknowledged.contains($0.operationID) }
    next.entries = vocabulary
    // Replay everything not acknowledged, including saves performed during this request.
    for operation in next.pending {
      next.entries.removeAll { VocabularyEntry.canonicalWordKey($0.word) == operation.wordKey }
      if let entry = operation.entry, operation.kind != .delete { next.entries.append(entry) }
    }
    next.entries.sort { $0.timestamp > $1.timestamp }
    next.cloudRevision = revision
    next.tombstones = tombstones
    next.localRevision = try Self.incrementRevision(next.localRevision)
    try commit(next)
  }

  /// Called only after an explicit user choice against a fresh cloud snapshot.
  func resolveConflicts(wordKeys: [String], cloudVocabulary: [VocabularyEntry], cloudRevision: Int64,
    tombstones: [VocabularyTombstone], strategy: VocabularyConflictStrategy, basedOn batch: VocabularySyncBatch) throws {
    try requireWritable()
    guard envelope.userID == batch.userID, accountGeneration == batch.accountGeneration else {
      throw VocabularyPersistenceError.accountChanged
    }
    let keys = Set(wordKeys.map(VocabularyEntry.canonicalWordKey))
    let submittedIDs = Set(batch.operations.map(\.operationID))
    let stillSubmittedKeys = Set(envelope.pending.filter { submittedIDs.contains($0.operationID) }.map(\.wordKey))
    guard !keys.isEmpty, !keys.contains(""), keys.isSubset(of: stillSubmittedKeys), cloudRevision >= envelope.cloudRevision else {
      throw VocabularyPersistenceError.unknownOperations
    }
    for key in keys {
      let remote = cloudVocabulary.first { VocabularyEntry.canonicalWordKey($0.word) == key }
      let deletion = tombstones.first { VocabularyEntry.canonicalWordKey($0.wordKey) == key }
      guard remote == nil || deletion == nil,
        remote == nil || (remote?.cloudVersion.map { $0 > 0 && $0 <= cloudRevision } ?? false),
        deletion == nil || (deletion?.version ?? 0) > 0 && (deletion?.version ?? 0) <= cloudRevision else {
        throw VocabularyPersistenceError.unknownOperations
      }
    }
    var next = envelope
    next.pending.removeAll { keys.contains($0.wordKey) }
    if strategy == .resubmitLocal {
      for key in keys.sorted() {
        guard let original = envelope.pending.first(where: { $0.wordKey == key }) else {
          throw VocabularyPersistenceError.unknownOperations
        }
        let remote = cloudVocabulary.first { VocabularyEntry.canonicalWordKey($0.word) == key }
        let deletion = tombstones.first { VocabularyEntry.canonicalWordKey($0.wordKey) == key }
        if original.kind == .delete {
          next.pending.append(VocabularyMutation(operationID: UUID().uuidString, kind: .delete,
            wordKey: key, entry: nil, baseVersion: remote?.cloudVersion ?? deletion?.version))
        } else {
          guard var local = envelope.entries.first(where: { VocabularyEntry.canonicalWordKey($0.word) == key }) ?? original.entry else {
            throw VocabularyPersistenceError.unknownOperations
          }
          local.cloudVersion = remote?.cloudVersion
          next.pending.append(VocabularyMutation(operationID: UUID().uuidString,
            kind: deletion == nil ? .upsert : .restore, wordKey: key, entry: local,
            baseVersion: remote?.cloudVersion ?? deletion?.version))
        }
      }
    }
    next.entries = cloudVocabulary
    for operation in next.pending {
      next.entries.removeAll { VocabularyEntry.canonicalWordKey($0.word) == operation.wordKey }
      if operation.kind != .delete, let entry = operation.entry { next.entries.append(entry) }
    }
    next.entries.sort { $0.timestamp > $1.timestamp }
    next.cloudRevision = cloudRevision
    next.tombstones = tombstones
    next.localRevision = try Self.incrementRevision(next.localRevision)
    // Preserve the exact old envelope even after normal rolling backups have rotated.
    try fileManager.copyItem(at: fileURL, to: fileURL.appendingPathExtension("before-conflict-\(UUID().uuidString)"))
    try commit(next)
  }

  /// Explicit application action only. A durable prepare/commit/receipt makes binding resumable.
  func adoptUnassignedEntries(into userID: String) throws {
    if let issue { throw issue }
    let unsigned = try Self.loadUnsigned(directory: directory, fileManager: fileManager)
    let targetURL = try accountURL(userID)
    var target = try Self.readEnvelope(at: targetURL, expectedUserID: userID, fileManager: fileManager)
    var prepared = unsigned.envelope
    if let record = prepared.adoption, record.userID != userID {
      throw VocabularyPersistenceError.bindingInProgress
    }
    if prepared.adoption == nil {
      let source = Self.merge(prepared.entries, additions: unsigned.legacy)
      let existing = Set(target.entries.map { VocabularyEntry.canonicalWordKey($0.word) })
      let operations = source.filter { !existing.contains(VocabularyEntry.canonicalWordKey($0.word)) }.map { entry in
        let key = VocabularyEntry.canonicalWordKey(entry.word)
        let deletion = target.tombstones.first { $0.wordKey == key }
        return VocabularyMutation(operationID: UUID().uuidString,
          kind: deletion == nil ? .upsert : .restore, wordKey: key, entry: entry, baseVersion: deletion?.version)
      }
      let bindingID = UUID().uuidString
      prepared.adoption = VocabularyAdoptionRecord(bindingID: bindingID, userID: userID, operations: operations)
      prepared.localRevision = try Self.incrementRevision(prepared.localRevision)
      // Keep exact pre-binding bytes outside rotating backups, including canonical collisions.
      if fileManager.fileExists(atPath: unsigned.url.path) {
        try fileManager.copyItem(at: unsigned.url,
          to: unsigned.url.appendingPathExtension("before-binding-\(bindingID)"))
      }
      // Prepare before touching the target. Operation IDs and the exact snapshot survive interruption.
      try persist(prepared, at: unsigned.url)
      if envelope.userID == nil { envelope = prepared; fileURL = unsigned.url }
    }
    guard let record = prepared.adoption else { throw VocabularyPersistenceError.bindingInProgress }
    if !(target.completedAdoptionIDs ?? []).contains(record.bindingID) {
      var keys = Set(target.entries.map { VocabularyEntry.canonicalWordKey($0.word) })
      for operation in record.operations where keys.insert(operation.wordKey).inserted {
        guard let entry = operation.entry else { throw VocabularyPersistenceError.unknownOperations }
        target.entries.append(entry)
        target.pending.append(operation)
      }
      target.completedAdoptionIDs = (target.completedAdoptionIDs ?? []) + [record.bindingID]
      target.localRevision = try Self.incrementRevision(target.localRevision)
      // Entries, pending IDs and the binding receipt share one atomic target write.
      try persist(target, at: targetURL)
    }
    if envelope.userID == userID { envelope = target; fileURL = targetURL }
    var receipt = prepared
    receipt.entries = []
    receipt.pending = []
    receipt.adoption = nil
    receipt.localRevision = try Self.incrementRevision(receipt.localRevision)
    receipt.legacyAdoptedBy = userID
    try persist(receipt, at: unsigned.url)
    if envelope.userID == nil { envelope = receipt; fileURL = unsigned.url; legacyEntries = [] }
  }

  func exportOriginal(to destination: URL) throws {
    let root = directory.appendingPathComponent("vocabulary.json")
    let source = fileManager.fileExists(atPath: fileURL.path) ? fileURL : root
    guard destination.standardizedFileURL != source.standardizedFileURL else {
      throw VocabularyPersistenceError.unreadableStore("same destination")
    }
    try fileManager.copyItem(at: source, to: destination)
  }

  /// Kept separate from the account file so legacy ownership cannot be inferred during recovery.
  func exportUnassignedOriginal(to destination: URL) throws {
    let root = directory.appendingPathComponent("vocabulary.json")
    guard destination.standardizedFileURL != root.standardizedFileURL else {
      throw VocabularyPersistenceError.unreadableStore("same destination")
    }
    try fileManager.copyItem(at: root, to: destination)
  }

  func restoreBackup(number: Int) throws {
    guard (1...3).contains(number) else { throw VocabularyPersistenceError.unreadableStore("invalid backup") }
    let backup = Self.backupURL(fileURL, number: number)
    guard fileManager.fileExists(atPath: backup.path) else { throw VocabularyPersistenceError.unreadableStore("missing backup") }
    let data = try Data(contentsOf: backup)
    let root = directory.appendingPathComponent("vocabulary.json")
    let legacy = try? JSONDecoder().decode([VocabularyEntry].self, from: data)
    let recovered: VocabularyEnvelope?
    if let legacy, envelope.userID == nil, fileURL == root {
      guard legacy.allSatisfy({ !VocabularyEntry.canonicalWordKey($0.word).isEmpty }) else {
        throw VocabularyPersistenceError.unreadableStore("invalid legacy backup")
      }
      recovered = nil
    } else {
      recovered = try Self.decodeEnvelope(data, expectedUserID: envelope.userID)
    }
    // Preserve unreadable original bytes before replacing them, rather than rotating into valid backups.
    if fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.copyItem(at: fileURL, to: fileURL.appendingPathExtension("recovery-\(UUID().uuidString)"))
    }
    try data.write(to: fileURL, options: .atomic)
    if let recovered { envelope = recovered; issue = nil }
    else {
      do {
        let unsigned = try Self.loadUnsigned(directory: directory, fileManager: fileManager)
        fileURL = unsigned.url
        envelope = unsigned.envelope
        legacyEntries = unsigned.legacy
        issue = nil
      } catch {
        let failure = Self.persistenceError(error)
        issue = failure
        throw failure
      }
    }
  }

  private func unassignedCount() -> Int {
    guard let unsigned = try? Self.loadUnsigned(directory: directory, fileManager: fileManager) else { return 0 }
    return Self.merge(unsigned.envelope.entries, additions: unsigned.legacy).count
  }

  private func accountURL(_ userID: String) throws -> URL {
    guard !userID.isEmpty, userID.utf8.count <= 100 else { throw VocabularyPersistenceError.accountChanged }
    let encoded = userID.utf8.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("accounts", isDirectory: true)
      .appendingPathComponent(encoded, isDirectory: true).appendingPathComponent("vocabulary.json")
  }

  private func requireWritable() throws {
    if let issue { throw issue }
    if envelope.adoption != nil { throw VocabularyPersistenceError.bindingInProgress }
  }

  private func commit(_ next: VocabularyEnvelope) throws {
    try persist(next, at: fileURL)
    envelope = next
  }

  private func persist(_ next: VocabularyEnvelope, at url: URL) throws {
    let data = try JSONEncoder.pretty.encode(next)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: url.path) {
      // A failed backup must fail the write; never replace the only recoverable copy.
      for number in stride(from: 3, through: 2, by: -1) {
        let prior = Self.backupURL(url, number: number - 1)
        let destination = Self.backupURL(url, number: number)
        if fileManager.fileExists(atPath: prior.path) {
          if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
          try fileManager.copyItem(at: prior, to: destination)
        }
      }
      let destination = Self.backupURL(url, number: 1)
      if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
      try fileManager.copyItem(at: url, to: destination)
    }
    try data.write(to: url, options: .atomic)
  }

  private static func incrementRevision(_ revision: Int64) throws -> Int64 {
    let (next, overflow) = revision.addingReportingOverflow(1)
    guard !overflow else { throw VocabularyPersistenceError.unreadableStore("revision exhausted") }
    return next
  }

  private static func backupURL(_ url: URL, number: Int) -> URL { url.appendingPathExtension("backup\(number)") }

  private static func unsignedFileURL(directory: URL, fileManager: FileManager) -> URL {
    let root = directory.appendingPathComponent("vocabulary.json")
    let unsigned = directory.appendingPathComponent("unsigned", isDirectory: true).appendingPathComponent("vocabulary.json")
    if let data = try? Data(contentsOf: root), (try? JSONSerialization.jsonObject(with: data)) is [Any] {
      return unsigned
    }
    return !fileManager.fileExists(atPath: root.path) && fileManager.fileExists(atPath: unsigned.path) ? unsigned : root
  }

  private static func readEnvelope(at url: URL, expectedUserID: String?, fileManager: FileManager) throws -> VocabularyEnvelope {
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      return VocabularyEnvelope(userID: expectedUserID)
    }
    return try decodeEnvelope(data, expectedUserID: expectedUserID)
  }

  private static func decodeEnvelope(_ data: Data, expectedUserID: String?) throws -> VocabularyEnvelope {
    struct Header: Decodable { let schemaVersion: Int }
    let header = try JSONDecoder().decode(Header.self, from: data)
    guard header.schemaVersion == 1 else { throw VocabularyPersistenceError.unsupportedVersion(header.schemaVersion) }
    let value = try JSONDecoder().decode(VocabularyEnvelope.self, from: data)
    guard value.userID == expectedUserID else { throw VocabularyPersistenceError.accountChanged }
    guard value.localRevision >= 0, value.cloudRevision >= 0,
      value.entries.allSatisfy({ !VocabularyEntry.canonicalWordKey($0.word).isEmpty }),
      Set(value.pending.map(\.operationID)).count == value.pending.count,
      Set(value.pending.map(\.wordKey)).count == value.pending.count,
      value.pending.allSatisfy({ !$0.operationID.isEmpty && !$0.wordKey.isEmpty && ($0.kind == .delete || $0.entry != nil) }) else {
      throw VocabularyPersistenceError.unreadableStore("invalid envelope")
    }
    return value
  }

  private static func loadUnsigned(directory: URL, fileManager: FileManager) throws -> (url: URL, envelope: VocabularyEnvelope, legacy: [VocabularyEntry]) {
    let root = directory.appendingPathComponent("vocabulary.json")
    let unsigned = directory.appendingPathComponent("unsigned", isDirectory: true).appendingPathComponent("vocabulary.json")
    guard fileManager.fileExists(atPath: root.path) else {
      let selected = fileManager.fileExists(atPath: unsigned.path) ? unsigned : root
      return (selected, try readEnvelope(at: selected, expectedUserID: nil, fileManager: fileManager), [])
    }
    let data = try Data(contentsOf: root)
    if let old = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
      guard old.allSatisfy({ !VocabularyEntry.canonicalWordKey($0.word).isEmpty }) else {
        throw VocabularyPersistenceError.unreadableStore("invalid legacy entries")
      }
      let value = try readEnvelope(at: unsigned, expectedUserID: nil, fileManager: fileManager)
      let display = old.map { entry in
        var migrated = entry
        if migrated.exampleSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          migrated.exampleSentence = migrated.sourceContext
        }
        return migrated
      }
      return (unsigned, value, value.legacyAdoptedBy == nil ? display : [])
    }
    return (root, try readEnvelope(at: root, expectedUserID: nil, fileManager: fileManager), [])
  }

  private static func persistenceError(_ error: Error) -> VocabularyPersistenceError {
    (error as? VocabularyPersistenceError) ?? .unreadableStore(String(describing: type(of: error)))
  }

  private static func merge(_ entries: [VocabularyEntry], additions: [VocabularyEntry]) -> [VocabularyEntry] {
    var result = entries
    var keys = Set(entries.map { VocabularyEntry.canonicalWordKey($0.word) })
    for entry in additions where keys.insert(VocabularyEntry.canonicalWordKey(entry.word)).inserted { result.append(entry) }
    return result.sorted { $0.timestamp > $1.timestamp }
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
