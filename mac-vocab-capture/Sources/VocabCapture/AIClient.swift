import Foundation

struct AIConfiguration: Codable, Sendable {
  var baseURL: String
  var model: String
  var apiKey: String

  var isComplete: Bool { !baseURL.isEmpty && !model.isEmpty }
}

struct DictionaryClient {
  func lookup(_ selection: SelectedText, configuration: AIConfiguration) async throws -> DictionaryResult {
    guard configuration.isComplete else { throw VocabularyError.missingConfiguration }
    let startedAt = Date()
    let url = URL(string: configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !configuration.apiKey.isEmpty {
      request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    }
    let prompt = """
    你是英汉语境词典。只返回 JSON：
    {"lemma":"词典原形","partOfSpeech":"词性","meaning":"不超过16字的准确中文释义","pronunciation":"IPA或空字符串","note":"必要时的搭配或词形说明"}
    目标词：\(selection.word)
    原文完整句子：\(selection.context)
    """
    let body: [String: Any] = [
      "model": configuration.model,
      "temperature": 0.1,
      "max_tokens": 120,
      "response_format": ["type": "json_object"],
      "messages": [["role": "user", "content": prompt]]
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    ContextDebugLog.write("AI 查询开始", word: selection.word, context: selection.context)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
      throw URLError(.badServerResponse)
    }
    let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = envelope?["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let content = message["content"] as? String,
          let json = normalizedJSON(from: content)?.data(using: .utf8) else { throw VocabularyError.invalidAIResponse }
    let result = try JSONDecoder().decode(DictionaryResult.self, from: json)
    let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
    ContextDebugLog.write("AI 查询完成：\(milliseconds) ms", word: selection.word)
    return result
  }

  private func normalizedJSON(from content: String) -> String? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else { return nil }
    return String(trimmed[first...last])
  }
}
