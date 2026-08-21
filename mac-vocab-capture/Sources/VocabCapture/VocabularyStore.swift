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
    entries = (try? JSONDecoder().decode([VocabularyEntry].self, from: Data(contentsOf: fileURL))) ?? []
  }

  func add(word: String, dictionary: DictionaryResult, context: String) throws -> VocabularyEntry {
    let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { throw VocabularyError.invalidSelection }
    if let existing = entries.first(where: { $0.word.lowercased() == normalized }) { return existing }
    let entry = VocabularyEntry(word: word, dictionary: dictionary, context: context)
    entries.insert(entry, at: 0)
    let data = try JSONEncoder.pretty.encode(entries)
    try data.write(to: fileURL, options: .atomic)
    return entry
  }

  func all() -> [VocabularyEntry] { entries }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
