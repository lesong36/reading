import Foundation

actor VocabularyStore {
  private let fileURL: URL
  private var entries: [VocabularyEntry]

  init(fileManager: FileManager = .default) {
    let appSupport = try! fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("VocabCapture", isDirectory: true)
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
    try persist()
    return entry
  }

  func all() -> [VocabularyEntry] { entries }

  func replace(with updated: [VocabularyEntry]) throws {
    entries = updated.sorted { $0.timestamp > $1.timestamp }
    try persist()
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
