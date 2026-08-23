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
  }

  enum CodingKeys: String, CodingKey {
    case id, word, meaning, lemma, partOfSpeech, pronunciation, etymology
    case exampleSentence, sourceContext, sourceArticleId, sourceArticleTitle, addedAt, timestamp
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
