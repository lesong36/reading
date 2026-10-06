import Foundation

struct DictionaryResult: Codable, Sendable {
  let lemma: String
  let meaning: String
  let partOfSpeech: String
  let pronunciation: String
  let note: String
}

struct VocabularyEntry: Codable, Identifiable, Sendable, Equatable {
  let id: String
  let word: String
  let meaning: String
  let lemma: String
  let partOfSpeech: String
  let pronunciation: String
  let etymology: String
  var exampleSentence: String
  let sourceContext: String
  let sourceArticleId: String?
  let sourceArticleTitle: String
  let addedAt: String
  let timestamp: Int64
  var cloudVersion: Int64?
  var updatedAt: String?
  var definitionCheckedAt: String?
  var definitionProvider: String?
  var unknownFields: [String: VocabularyJSONValue] = [:]

  static func canonicalWordKey(_ word: String) -> String {
    word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  init(word: String, dictionary: DictionaryResult, context: String) {
    id = UUID().uuidString
    self.word = word
    meaning = dictionary.meaning
    lemma = dictionary.lemma.isEmpty ? word : dictionary.lemma
    partOfSpeech = dictionary.partOfSpeech
    pronunciation = dictionary.pronunciation
    etymology = dictionary.note.isEmpty ? "来自 macOS 拾词助手" : dictionary.note
    // Keep the original sentence in both fields used by the reader's card UI:
    // sourceContext powers the “来自文章语境” panel and exampleSentence is
    // rendered as the card's example sentence.
    exampleSentence = context
    sourceContext = context
    sourceArticleId = nil
    sourceArticleTitle = "macOS 拾词助手"
    addedAt = ISO8601DateFormatter().string(from: .now)
    timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
    cloudVersion = nil
    updatedAt = addedAt
    definitionCheckedAt = nil
    definitionProvider = nil
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, word, meaning, lemma, partOfSpeech, pronunciation, etymology
    case exampleSentence, sourceContext, sourceArticleId, sourceArticleTitle, addedAt, timestamp
    case cloudVersion, updatedAt, definitionCheckedAt, definitionProvider
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    word = try values.decodeIfPresent(String.self, forKey: .word) ?? ""
    meaning = try values.decodeIfPresent(String.self, forKey: .meaning) ?? "暂无释义"
    lemma = try values.decodeIfPresent(String.self, forKey: .lemma) ?? word
    partOfSpeech = try values.decodeIfPresent(String.self, forKey: .partOfSpeech) ?? ""
    pronunciation = try values.decodeIfPresent(String.self, forKey: .pronunciation) ?? ""
    etymology = try values.decodeIfPresent(String.self, forKey: .etymology) ?? ""
    sourceContext = try values.decodeIfPresent(String.self, forKey: .sourceContext) ?? ""
    exampleSentence = try values.decodeIfPresent(String.self, forKey: .exampleSentence) ?? sourceContext
    sourceArticleId = try values.decodeIfPresent(String.self, forKey: .sourceArticleId)
    sourceArticleTitle = try values.decodeIfPresent(String.self, forKey: .sourceArticleTitle) ?? ""
    addedAt = try values.decodeIfPresent(String.self, forKey: .addedAt) ?? ""
    timestamp = try values.decodeIfPresent(Int64.self, forKey: .timestamp) ?? 0
    cloudVersion = try values.decodeIfPresent(Int64.self, forKey: .cloudVersion)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    definitionCheckedAt = try values.decodeIfPresent(String.self, forKey: .definitionCheckedAt)
    definitionProvider = try values.decodeIfPresent(String.self, forKey: .definitionProvider)
    let all = try decoder.container(keyedBy: VocabularyFieldKey.self)
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    for key in all.allKeys where !known.contains(key.stringValue) {
      unknownFields[key.stringValue] = try all.decode(VocabularyJSONValue.self, forKey: key)
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(word, forKey: .word)
    try values.encode(meaning, forKey: .meaning)
    try values.encode(lemma, forKey: .lemma)
    try values.encode(partOfSpeech, forKey: .partOfSpeech)
    try values.encode(pronunciation, forKey: .pronunciation)
    try values.encode(etymology, forKey: .etymology)
    try values.encode(exampleSentence, forKey: .exampleSentence)
    try values.encode(sourceContext, forKey: .sourceContext)
    try values.encodeIfPresent(sourceArticleId, forKey: .sourceArticleId)
    try values.encode(sourceArticleTitle, forKey: .sourceArticleTitle)
    try values.encode(addedAt, forKey: .addedAt)
    try values.encode(timestamp, forKey: .timestamp)
    try values.encodeIfPresent(cloudVersion, forKey: .cloudVersion)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try values.encodeIfPresent(definitionCheckedAt, forKey: .definitionCheckedAt)
    try values.encodeIfPresent(definitionProvider, forKey: .definitionProvider)
    var all = encoder.container(keyedBy: VocabularyFieldKey.self)
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    for (key, value) in unknownFields where !known.contains(key) {
      try all.encode(value, forKey: VocabularyFieldKey(stringValue: key)!)
    }
  }

}

enum VocabularyError: LocalizedError {
  case invalidSelection
  case missingSentenceContext
  case missingConfiguration
  case invalidAIResponse

  var errorDescription: String? {
    switch self {
    case .invalidSelection: "请先选中一个英文单词或短语。"
    case .missingSentenceContext: "当前应用没有提供原句。请使用“截图 OCR 取词”，框选包含原句的区域后再选择词。"
    case .missingConfiguration: "请先在设置中配置 AI 服务。"
    case .invalidAIResponse: "AI 返回的词典数据格式不正确。"
    }
  }
}

// Preserve future browser fields through native decoding and synchronization.
indirect enum VocabularyJSONValue: Codable, Sendable, Equatable {
  case null, string(String), bool(Bool), number(Decimal)
  case array([VocabularyJSONValue]), object([String: VocabularyJSONValue])
  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { self = .null }
    else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
    else if let number = try? value.decode(Decimal.self) { self = .number(number) }
    else if let string = try? value.decode(String.self) { self = .string(string) }
    else if let array = try? value.decode([VocabularyJSONValue].self) { self = .array(array) }
    else { self = .object(try value.decode([String: VocabularyJSONValue].self)) }
  }
  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .string(let item): try value.encode(item)
    case .bool(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .object(let item): try value.encode(item)
    }
  }
}
private struct VocabularyFieldKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
