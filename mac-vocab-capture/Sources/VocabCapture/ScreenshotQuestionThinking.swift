enum ScreenshotQuestionThinking: String, Codable, CaseIterable, Sendable {
  case automatic, off, low, medium, high

  var title: String {
    switch self {
    case .automatic: return "自动（服务默认）"
    case .off: return "关闭／最少思考（优先速度）"
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    }
  }

  static let help =
    "优先速度会尽量关闭思考；不支持关闭的模型使用最低强度。可用强度取决于模型，DeepSeek 的中档使用高档；Kimi K2.6 支持关闭或开启思考，低／中／高均为开启。自动模式及无法识别的模型不发送控制参数，沿用服务默认。"
}
