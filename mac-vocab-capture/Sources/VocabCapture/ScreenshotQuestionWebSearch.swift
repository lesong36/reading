import Foundation

struct ScreenshotQuestionWebSearchConfiguration: Sendable {
  let apiKey: String
  let directConnection: Bool

  init(apiKey: String, directConnection: Bool = false) {
    self.apiKey = apiKey
    self.directConnection = directConnection
  }
}

enum ScreenshotQuestionSearchStage: String, Sendable {
  case query, search, answer

  var title: String {
    switch self {
    case .query: return "正在整理检索词…"
    case .search: return "正在联网检索…"
    case .answer: return "正在根据检索资料回答…"
    }
  }
}

enum ScreenshotQuestionWebSearchError: LocalizedError {
  case notConfigured, authentication, limit, timeout, connection
  case invalidResponse, emptyResults, missingQuery, unsupportedBackend

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "请在“检索设置”中填写 Tavily API Key。"
    case .authentication: return "联网检索认证失败，请检查 Tavily API Key。"
    case .limit: return "联网检索额度不足或请求受限，请检查 Tavily 账户额度后重试。"
    case .timeout: return "联网检索超时，请检查网络后重试。"
    case .connection: return "无法连接搜索服务，请检查网络或检索设置中的直连选项。"
    case .invalidResponse: return "搜索服务返回的数据无法识别，请重试。"
    case .emptyResults: return "没有找到可用的网页资料，请补充具体名称或来源后重试。"
    case .missingQuery: return "未能形成有效检索词，请补充截图中的名称、页面标题或来源链接。"
    case .unsupportedBackend: return "当前问答引擎不支持联网检索，请使用 App 内置引擎。"
    }
  }
}
