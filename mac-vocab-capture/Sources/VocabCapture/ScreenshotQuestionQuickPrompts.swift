import Foundation

struct ScreenshotQuestionQuickPrompt: Codable, Equatable, Identifiable {
  let id: String
  let title: String
  let prompt: String

  init(id: String = UUID().uuidString, title: String, prompt: String) {
    self.id = id
    self.title = title
    self.prompt = prompt
  }
}

enum ScreenshotQuestionQuickPromptsError: LocalizedError, Equatable {
  case tooMany, missingTitle, missingPrompt, invalidTitle, invalidID

  var errorDescription: String? {
    switch self {
    case .tooMany: return "最多保存 5 个快捷问题。"
    case .missingTitle: return "请填写每个快捷问题的按钮名称。"
    case .missingPrompt: return "请填写每个快捷问题的提问内容。"
    case .invalidTitle: return "按钮名称须为单行，且不超过 20 个字符。"
    case .invalidID: return "快捷问题编号无效，请重新打开设置。"
    }
  }
}

final class ScreenshotQuestionQuickPrompts {
  static let storageKey = "VocabCapture.questionQuickPrompts"
  static let maximumCount = 5
  static let maximumTitleLength = 20
  static let defaultPrompts = [
    ScreenshotQuestionQuickPrompt(id: "explain", title: "解释这段话", prompt: "解释这段话"),
    ScreenshotQuestionQuickPrompt(id: "structure", title: "分析句子结构", prompt: "分析句子结构"),
    ScreenshotQuestionQuickPrompt(id: "summarize", title: "总结要点", prompt: "总结要点"),
  ]

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var prompts: [ScreenshotQuestionQuickPrompt] {
    guard let data = defaults.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode([ScreenshotQuestionQuickPrompt].self, from: data),
      let normalized = try? normalize(decoded)
    else { return Self.defaultPrompts }
    return normalized
  }

  func save(_ prompts: [ScreenshotQuestionQuickPrompt]) throws {
    defaults.set(try JSONEncoder().encode(normalize(prompts)), forKey: Self.storageKey)
  }

  private func normalize(_ prompts: [ScreenshotQuestionQuickPrompt]) throws
    -> [ScreenshotQuestionQuickPrompt]
  {
    guard prompts.count <= Self.maximumCount else {
      throw ScreenshotQuestionQuickPromptsError.tooMany
    }
    guard Set(prompts.map(\.id)).count == prompts.count,
      prompts.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw ScreenshotQuestionQuickPromptsError.invalidID }
    return try prompts.map { entry in
      let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw ScreenshotQuestionQuickPromptsError.missingTitle }
      guard !prompt.isEmpty else { throw ScreenshotQuestionQuickPromptsError.missingPrompt }
      guard title.count <= Self.maximumTitleLength,
        title.rangeOfCharacter(from: .newlines) == nil
      else { throw ScreenshotQuestionQuickPromptsError.invalidTitle }
      return ScreenshotQuestionQuickPrompt(id: entry.id, title: title, prompt: prompt)
    }
  }
}
