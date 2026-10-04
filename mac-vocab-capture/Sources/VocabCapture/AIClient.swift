import Foundation

struct AIConfiguration: Codable, Sendable {
  var baseURL: String
  var model: String
  var apiKey: String

  var isComplete: Bool { !baseURL.isEmpty && !model.isEmpty }
}

actor DictionaryClient {
  private struct CacheKey: Hashable {
    let word: String
    let context: String
    let baseURL: String
    let model: String
    let credential: String
  }

  private let session: URLSession
  private let cacheLimit: Int
  private var cache: [CacheKey: DictionaryResult] = [:]
  private var cacheOrder: [CacheKey] = []

  init(session: URLSession = .shared, cacheLimit: Int = 100) {
    self.session = session
    self.cacheLimit = max(0, cacheLimit)
  }

  func lookup(
    _ selection: SelectedText, configuration: AIConfiguration,
    onMeaning: (@MainActor @Sendable (String) -> Void)? = nil
  ) async throws -> DictionaryResult {
    try Task.checkCancellation()
    guard configuration.isComplete else { throw VocabularyError.missingConfiguration }
    let key = CacheKey(
      word: selection.word, context: selection.context,
      baseURL: configuration.baseURL, model: configuration.model, credential: configuration.apiKey)
    if let result = cache[key] {
      ContextDebugLog.write("AI 查询缓存命中", word: selection.word)
      if let onMeaning { await onMeaning(result.meaning) }
      try Task.checkCancellation()
      return result
    }

    let startedAt = Date()
    guard
      let url = URL(
        string: configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          + "/chat/completions")
    else {
      throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !configuration.apiKey.isEmpty {
      request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    }
    let prompt = """
      你是英汉语境词典。只返回紧凑 JSON，按以下顺序输出，meaning 必须最先：
      {"meaning":"不超过16字的准确中文释义","lemma":"词典原形","partOfSpeech":"词性","pronunciation":"IPA或空字符串","note":"必要的搭配或词形说明，无则空字符串"}
      目标词：\(selection.word)
      原文完整句子：\(selection.context)
      """
    let body: [String: Any] = [
      "model": configuration.model, "temperature": 0.1, "max_tokens": 120,
      "stream": true, "response_format": ["type": "json_object"],
      "messages": [["role": "user", "content": prompt]],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    ContextDebugLog.write("AI 查询开始", word: selection.word, context: selection.context)
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
      throw URLError(.badServerResponse)
    }

    var content = ""
    var meaningPublished = false
    if http.mimeType == "text/event-stream" {
      var payload = ""
      var done = false
      var lineBytes = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard byte == 10 else {
          lineBytes.append(byte)
          continue
        }
        if lineBytes.last == 13 { lineBytes.removeLast() }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.isEmpty {
          if !payload.isEmpty {
            done = try await consumeEvent(
              payload, content: &content,
              meaningPublished: &meaningPublished, onMeaning: onMeaning,
              startedAt: startedAt, word: selection.word)
            payload = ""
            if done { break }
          }
        } else if line.hasPrefix("data:") {
          if !payload.isEmpty { payload += "\n" }
          let value = line.dropFirst(5)
          payload += value.first == " " ? String(value.dropFirst()) : String(value)
        }
      }
      if !done, !lineBytes.isEmpty {
        let line = String(decoding: lineBytes, as: UTF8.self)
        if line.hasPrefix("data:") {
          if !payload.isEmpty { payload += "\n" }
          let value = line.dropFirst(5)
          payload += value.first == " " ? String(value.dropFirst()) : String(value)
        }
      }
      if !done && !payload.isEmpty {
        _ = try await consumeEvent(
          payload, content: &content,
          meaningPublished: &meaningPublished, onMeaning: onMeaning,
          startedAt: startedAt, word: selection.word)
      }
    } else {
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        data.append(byte)
      }
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let choices = envelope?["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let value = message["content"] as? String
      else { throw VocabularyError.invalidAIResponse }
      content = value
    }
    try Task.checkCancellation()
    guard let first = content.firstIndex(of: "{"), let last = content.lastIndex(of: "}"),
      first <= last
    else {
      throw VocabularyError.invalidAIResponse
    }
    let result = try JSONDecoder().decode(
      DictionaryResult.self, from: Data(content[first...last].utf8))
    guard !result.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw VocabularyError.invalidAIResponse
    }
    if !meaningPublished, let onMeaning { await onMeaning(result.meaning) }
    try Task.checkCancellation()
    if cacheLimit > 0 {
      if cache[key] == nil { cacheOrder.append(key) }
      cache[key] = result
      if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    ContextDebugLog.write(
      "AI 查询完成：\(Int(Date().timeIntervalSince(startedAt) * 1_000)) ms", word: selection.word)
    return result
  }

  private func consumeEvent(
    _ payload: String, content: inout String, meaningPublished: inout Bool,
    onMeaning: (@MainActor @Sendable (String) -> Void)?, startedAt: Date, word: String
  ) async throws -> Bool {
    if payload == "[DONE]" { return true }
    guard
      let envelope = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
      envelope["error"] == nil
    else { throw VocabularyError.invalidAIResponse }
    if let choices = envelope["choices"] as? [[String: Any]], let choice = choices.first {
      if choice["finish_reason"] as? String == "length" { throw VocabularyError.invalidAIResponse }
      if let delta = choice["delta"] as? [String: Any], let fragment = delta["content"] as? String {
        content += fragment
      }
    }
    if !meaningPublished, let meaning = Self.completedMeaning(in: content), !meaning.isEmpty {
      try Task.checkCancellation()
      meaningPublished = true
      ContextDebugLog.write(
        "AI 释义可见：\(Int(Date().timeIntervalSince(startedAt) * 1_000)) ms", word: word)
      if let onMeaning { await onMeaning(meaning) }
    }
    return false
  }

  // Scan JSON structure, then let JSONDecoder handle escapes and Unicode surrogate pairs.
  // A closing quote is required before a preview can be published.
  static func completedMeaning(in content: String) -> String? {
    let bytes = Array(content.utf8)
    guard let first = bytes.firstIndex(of: 123) else { return nil }
    var depth = 1
    var expectsKey = true
    var index = first + 1
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 34 {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
          if !escaped && bytes[index] == 34 { break }
          if !escaped && bytes[index] == 92 { escaped = true } else { escaped = false }
          index += 1
        }
        guard index < bytes.count else { return nil }
        if depth == 1 && expectsKey {
          guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
          else { return nil }
          expectsKey = false
          index += 1
          while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
          guard index < bytes.count && bytes[index] == 58 else { return nil }
          index += 1
          while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
          if key == "meaning" {
            guard index < bytes.count && bytes[index] == 34 else { return nil }
            let valueStart = index
            index += 1
            escaped = false
            while index < bytes.count {
              if !escaped && bytes[index] == 34 {
                return try? JSONDecoder().decode(String.self, from: Data(bytes[valueStart...index]))
              }
              if !escaped && bytes[index] == 92 { escaped = true } else { escaped = false }
              index += 1
            }
            return nil
          }
          continue
        }
      } else if byte == 123 || byte == 91 {
        depth += 1
      } else if byte == 125 || byte == 93 {
        depth -= 1
        if depth == 0 { return nil }
      } else if byte == 44 && depth == 1 {
        expectsKey = true
      }
      index += 1
    }
    return nil
  }
}
