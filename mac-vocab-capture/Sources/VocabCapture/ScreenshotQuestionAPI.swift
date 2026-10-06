import Foundation

enum ScreenshotQuestionAPI: String, Codable, CaseIterable, Sendable {
  case automatic, chatCompletions, responses, anthropicMessages

  var title: String {
    switch self {
    case .automatic: return "自动识别"
    case .chatCompletions: return "Chat Completions（通用）"
    case .responses: return "Responses（GPT）"
    case .anthropicMessages: return "Messages（Claude）"
    }
  }

  func resolved(for configuration: AIConfiguration) -> ScreenshotQuestionAPI {
    guard self == .automatic else { return self }
    let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isAICodeWithHost(URL(string: base)?.host) else { return .chatCompletions }
    let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if model.hasPrefix("claude") { return .anthropicMessages }
    if model.hasPrefix("gpt") { return .responses }
    return .chatCompletions
  }

  func endpoint(for configuration: AIConfiguration) throws -> URL {
    let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: base),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { throw ScreenshotQuestionError.invalidConfiguration }
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let prefix = path.isEmpty ? "" : "/" + path
    switch resolved(for: configuration) {
    case .automatic: throw ScreenshotQuestionError.invalidConfiguration
    case .chatCompletions:
      let chatPrefix =
        prefix.isEmpty && ["api.moonshot.cn", "api.moonshot.ai"].contains(host.lowercased())
        ? "/v1" : prefix
      components.path =
        chatPrefix.hasSuffix("/chat/completions") ? chatPrefix : chatPrefix + "/chat/completions"
    case .responses:
      if Self.isAICodeWithHost(host), prefix.isEmpty || prefix == "/v1" {
        components.path = "/chatgpt/v1/responses"
      } else if prefix.hasSuffix("/responses") {
        components.path = prefix
      } else {
        components.path = (prefix.isEmpty ? "/v1" : prefix) + "/responses"
      }
    case .anthropicMessages:
      components.path =
        prefix.hasSuffix("/messages")
        ? prefix : (prefix.isEmpty ? "/v1" : prefix) + "/messages"
    }
    guard let url = components.url else { throw ScreenshotQuestionError.invalidConfiguration }
    return url
  }

  private static func isAICodeWithHost(_ host: String?) -> Bool {
    ["api.aicodewith.com", "api.aicodewith.ai"].contains(host?.lowercased() ?? "")
  }
}
