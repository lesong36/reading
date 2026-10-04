import Foundation

actor VocabularyStore {
  private let fileURL: URL
  private var entries: [VocabularyEntry]

  init(fileManager: FileManager = .default, directory: URL? = nil) {
    let appSupport = directory ?? (try! fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("VocabCapture", isDirectory: true))
    try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
    fileURL = appSupport.appendingPathComponent("vocabulary.json")
    let loaded = (try? JSONDecoder().decode([VocabularyEntry].self, from: Data(contentsOf: fileURL))) ?? []
    entries = loaded.map { entry in
      var migrated = entry
      if migrated.exampleSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        migrated.exampleSentence = migrated.sourceContext
      }
      return migrated
    }
    if entries != loaded {
      let data = try? JSONEncoder.pretty.encode(entries)
      try? data?.write(to: fileURL, options: .atomic)
    }
  }

  func add(word: String, dictionary: DictionaryResult, context: String) throws -> VocabularyEntry {
    let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { throw VocabularyError.invalidSelection }
    if let existing = entries.first(where: { $0.word.lowercased() == normalized }) { return existing }
    let entry = VocabularyEntry(word: word, dictionary: dictionary, context: context)
    entries.insert(entry, at: 0)
    do { try persist() } catch { entries.removeFirst(); throw error }
    return entry
  }

  func all() -> [VocabularyEntry] { entries }

  func replace(with updated: [VocabularyEntry]) throws {
    entries = updated.sorted { $0.timestamp > $1.timestamp }
    try persist()
  }

  /// A lookup can be saved while a cloud request is in flight. Preserve only
  /// those subsequent local changes; cloud deletions of the snapshot still win.
  func applySync(_ updated: [VocabularyEntry], basedOn snapshot: [VocabularyEntry]) throws {
    let changes = entries.filter { entry in
      !snapshot.contains(where: { $0 == entry })
    }
    var merged = updated
    for entry in changes {
      if let index = merged.firstIndex(where: { $0.word.lowercased() == entry.word.lowercased() }) {
        if merged[index].timestamp < entry.timestamp { merged[index] = entry }
      } else {
        merged.append(entry)
      }
    }
    let previous = entries
    entries = merged.sorted { $0.timestamp > $1.timestamp }
    do { try persist() } catch { entries = previous; throw error }
  }

  private func persist() throws {
    let data = try JSONEncoder.pretty.encode(entries)
    try data.write(to: fileURL, options: .atomic)
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
