import Foundation

struct ScreenshotQuestionTurn: Sendable {
  let question: String
  let answer: String
}

struct ScreenshotQuestionContext: Sendable {
  let text: String
  let selectedWord: String?
  let imageData: Data?
}

typealias ScreenshotQuestionAnswer = (
  String, ScreenshotQuestionContext, [ScreenshotQuestionTurn],
  @escaping @MainActor @Sendable (String) -> Void
) async throws -> String

enum ScreenshotQuestionError: LocalizedError {
  case emptyQuestion, missingContext, invalidConfiguration, invalidImage
  case server(Int)
  case invalidResponse, emptyResponse, truncatedResponse, unsupportedThinking

  var errorDescription: String? {
    switch self {
    case .unsupportedThinking: return "当前模型的思考参数无法识别，请选择“自动（服务默认）”，或核对模型名称。"
    case .emptyQuestion: return "请先输入想问的问题。"
    case .missingContext: return "截图中没有可供提问的内容，请重新截图。"
    case .invalidConfiguration: return "请在 AI 设置中填写有效的服务地址和模型。"
    case .invalidImage: return "截图格式或大小不受支持，请重新截图。"
    case .server(400): return "模型不接受当前请求（HTTP 400）。请核对接口协议、模型名称及支持的参数。"
    case .server(401): return "模型认证失败（HTTP 401）。请核对所选接口格式、服务地址和这个模型的 API Key。"
    case .server(403): return "当前 API Key 没有这个模型或渠道的访问权限（HTTP 403），请核对服务端授权。"
    case .server(404): return "模型或接口地址不存在（HTTP 404）。请核对接口格式、地址和模型名称。"
    case .server(429): return "模型服务限流或额度不足（HTTP 429），请稍后重试或检查服务端额度。"
    case .server(let status): return "模型服务暂时无法回答（HTTP \(status)），请稍后重试。"
    case .invalidResponse: return "模型返回的数据无法识别，请重试。"
    case .emptyResponse: return "模型没有返回回答，请重试。"
    case .truncatedResponse: return "回答未完整返回，请重试或缩小问题范围。"
    }
  }
}

actor NativeScreenshotQuestionClient {
  private struct Progress {
    var text = ""
    var completed = false
    var messageStarted = false
    var messageStoppedNormally = false
  }

  private let session: URLSession

  init(session: URLSession = .shared) { self.session = session }

  func answer(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI = .automatic,
    onPartial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    try Task.checkCancellation()
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { throw ScreenshotQuestionError.emptyQuestion }
    guard
      !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || context.imageData != nil
    else { throw ScreenshotQuestionError.missingContext }
    guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ScreenshotQuestionError.invalidConfiguration
    }
    let api = api.resolved(for: configuration)
    let request = try makeRequest(
      question: question, context: context, history: history, configuration: configuration, api: api
    )
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ScreenshotQuestionError.invalidResponse
    }
    guard 200..<300 ~= http.statusCode else {
      throw ScreenshotQuestionError.server(http.statusCode)
    }
    var progress = Progress()
    if http.mimeType == "text/event-stream" {
      var payload = ""
      var lineBytes = Data()
      var done = false
      for try await byte in bytes {
        try Task.checkCancellation()
        if byte != 10 {
          lineBytes.append(byte)
          continue
        }
        if lineBytes.last == 13 { lineBytes.removeLast() }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.isEmpty {
          if !payload.isEmpty {
            done = try await consume(payload, api: api, progress: &progress, onPartial: onPartial)
            payload = ""
            if done { break }
          }
        } else if line.hasPrefix("data:") {
          Self.append(line: line, to: &payload)
        }
      }
      if !done, !lineBytes.isEmpty {
        let line = String(decoding: lineBytes, as: UTF8.self)
        if line.hasPrefix("data:") { Self.append(line: line, to: &payload) }
      }
      if !done, !payload.isEmpty {
        _ = try await consume(payload, api: api, progress: &progress, onPartial: onPartial)
      }
      guard progress.completed else { throw ScreenshotQuestionError.truncatedResponse }
    } else {
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        data.append(byte)
      }
      let envelope = try Self.envelope(data)
      progress.text = try Self.completedText(envelope, api: api)
      if !progress.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try Task.checkCancellation()
        await onPartial(progress.text)
      }
    }
    try Task.checkCancellation()
    let answer = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else { throw ScreenshotQuestionError.emptyResponse }
    return answer
  }

  private func makeRequest(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI
  ) throws -> URLRequest {
    let instructions = ScreenshotQuestionInstructions.text
    let source = """
      以下是本次截图的识别原文：
      \(context.text)
      本次选中内容：\(context.selectedWord ?? "未选中，围绕整张截图回答")
      """
    let image = try Self.image(context.imageData)
    var messages: [[String: Any]] = []
    if api == .chatCompletions { messages.append(["role": "system", "content": instructions]) }
    var sourceBlocks = [Self.textBlock(source, api: api)]
    if let image {
      switch api {
      case .chatCompletions:
        sourceBlocks.append([
          "type": "image_url", "image_url": ["url": "data:\(image.mime);base64,\(image.data)"],
        ])
      case .responses:
        sourceBlocks.append([
          "type": "input_image", "image_url": "data:\(image.mime);base64,\(image.data)",
        ])
      case .anthropicMessages:
        sourceBlocks.append([
          "type": "image",
          "source": ["type": "base64", "media_type": image.mime, "data": image.data],
        ])
      case .automatic: throw ScreenshotQuestionError.invalidConfiguration
      }
    }
    messages.append([
      "role": "user",
      "content": api == .chatCompletions && image == nil ? source as Any : sourceBlocks as Any,
    ])
    for turn in history.suffix(6) {
      messages.append(Self.message("user", text: String(turn.question.prefix(2_000)), api: api))
      messages.append(Self.message("assistant", text: String(turn.answer.prefix(6_000)), api: api))
    }
    messages.append(Self.message("user", text: question, api: api))
    var body: [String: Any] = ["model": configuration.model, "stream": true]
    switch api {
    case .chatCompletions:
      body["messages"] = messages
      body["temperature"] = 0.2
      body["max_tokens"] = 900
    case .responses:
      body["instructions"] = instructions
      body["input"] = messages
      // Responses counts reasoning tokens against this budget as well as visible text.
      body["max_output_tokens"] = 4_096
      body["store"] = false
    case .anthropicMessages:
      body["system"] = instructions
      body["messages"] = messages
      body["max_tokens"] = 900
    case .automatic: throw ScreenshotQuestionError.invalidConfiguration
    }
    var request = URLRequest(url: try api.endpoint(for: configuration))
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if api == .anthropicMessages {
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    } else if !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func message(_ role: String, text: String, api: ScreenshotQuestionAPI) -> [String:
    Any]
  {
    [
      "role": role,
      // Plain text supports both user and assistant history in Responses.
      "content": api == .anthropicMessages ? [textBlock(text, api: api)] as Any : text as Any,
    ]
  }

  private static func textBlock(_ text: String, api: ScreenshotQuestionAPI) -> [String: Any] {
    ["type": api == .responses ? "input_text" : "text", "text": text]
  }

  static func image(_ data: Data?) throws -> (mime: String, data: String)? {
    guard let data else { return nil }
    let mime: String
    if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
      mime = "image/png"
    } else if data.starts(with: [0xff, 0xd8, 0xff]) {
      mime = "image/jpeg"
    } else {
      throw ScreenshotQuestionError.invalidImage
    }
    guard data.count <= 20 * 1_024 * 1_024 else { throw ScreenshotQuestionError.invalidImage }
    return (mime, data.base64EncodedString())
  }

  private static func append(line: String, to payload: inout String) {
    if !payload.isEmpty { payload += "\n" }
    let value = line.dropFirst(5)
    payload += value.first == " " ? String(value.dropFirst()) : String(value)
  }

  private static func hasValue(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }

  private static func envelope(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      !hasValue(value["error"]), value["type"] as? String != "error"
    else { throw ScreenshotQuestionError.invalidResponse }
    return value
  }

  private static func checkChatFinish(_ choice: [String: Any]) throws {
    if let finish = choice["finish_reason"] as? String, finish != "stop" {
      throw ScreenshotQuestionError.truncatedResponse
    }
  }

  private static func checkMessageStop(_ reason: Any?) throws {
    guard let reason = reason as? String, ["end_turn", "stop_sequence"].contains(reason) else {
      throw ScreenshotQuestionError.truncatedResponse
    }
  }

  private static func responseText(_ response: [String: Any]) throws -> String {
    guard response["status"] as? String == "completed", !hasValue(response["error"]),
      !hasValue(response["incomplete_details"])
    else { throw ScreenshotQuestionError.truncatedResponse }
    guard let output = response["output"] as? [[String: Any]] else {
      throw ScreenshotQuestionError.invalidResponse
    }
    var text: [String] = []
    for item in output where item["type"] as? String == "message" {
      guard let blocks = item["content"] as? [[String: Any]] else {
        throw ScreenshotQuestionError.invalidResponse
      }
      for block in blocks {
        if block["type"] as? String == "output_text", let value = block["text"] as? String {
          text.append(value)
        } else if block["type"] as? String == "refusal", let value = block["refusal"] as? String {
          text.append(value)
        }
      }
    }
    return text.joined(separator: "\n")
  }

  private static func messageText(_ message: [String: Any]) throws -> String {
    guard let blocks = message["content"] as? [[String: Any]] else {
      throw ScreenshotQuestionError.invalidResponse
    }
    return blocks.compactMap { block in
      block["type"] as? String == "text" ? block["text"] as? String : nil
    }.joined(separator: "\n")
  }

  private static func completedText(_ envelope: [String: Any], api: ScreenshotQuestionAPI) throws
    -> String
  {
    switch api {
    case .chatCompletions:
      guard let choices = envelope["choices"] as? [[String: Any]], let choice = choices.first,
        let message = choice["message"] as? [String: Any], let text = message["content"] as? String
      else { throw ScreenshotQuestionError.invalidResponse }
      try checkChatFinish(choice)
      return text
    case .responses: return try responseText(envelope)
    case .anthropicMessages:
      guard envelope["type"] as? String == "message" else {
        throw ScreenshotQuestionError.invalidResponse
      }
      try checkMessageStop(envelope["stop_reason"])
      return try messageText(envelope)
    case .automatic: throw ScreenshotQuestionError.invalidConfiguration
    }
  }

  private func consume(
    _ payload: String, api: ScreenshotQuestionAPI, progress: inout Progress,
    onPartial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> Bool {
    if payload == "[DONE]" {
      guard api == .chatCompletions else { throw ScreenshotQuestionError.truncatedResponse }
      progress.completed = true
      return true
    }
    let envelope = try Self.envelope(Data(payload.utf8))
    let previous = progress.text
    var done = false
    switch api {
    case .chatCompletions:
      guard let choices = envelope["choices"] as? [[String: Any]] else {
        throw ScreenshotQuestionError.invalidResponse
      }
      guard let choice = choices.first else { return false }
      try Self.checkChatFinish(choice)
      if choice["finish_reason"] as? String == "stop" { progress.completed = true }
      if let delta = choice["delta"] as? [String: Any], let fragment = delta["content"] as? String {
        progress.text += fragment
      }
    case .responses:
      guard let type = envelope["type"] as? String else {
        throw ScreenshotQuestionError.invalidResponse
      }
      switch type {
      case "response.output_text.delta", "response.refusal.delta":
        guard let fragment = envelope["delta"] as? String else {
          throw ScreenshotQuestionError.invalidResponse
        }
        progress.text += fragment
      case "response.completed":
        guard let response = envelope["response"] as? [String: Any] else {
          throw ScreenshotQuestionError.invalidResponse
        }
        progress.text = try Self.responseText(response)
        progress.completed = true
        done = true
      case "response.incomplete", "response.failed": throw ScreenshotQuestionError.truncatedResponse
      default: break
      }
    case .anthropicMessages:
      guard let type = envelope["type"] as? String else {
        throw ScreenshotQuestionError.invalidResponse
      }
      switch type {
      case "message_start":
        guard let message = envelope["message"] as? [String: Any],
          message["type"] as? String == "message"
        else {
          throw ScreenshotQuestionError.invalidResponse
        }
        progress.messageStarted = true
        progress.text += try Self.messageText(message)
      case "content_block_start":
        if let block = envelope["content_block"] as? [String: Any],
          block["type"] as? String == "text",
          let text = block["text"] as? String
        {
          progress.text += text
        }
      case "content_block_delta":
        guard let delta = envelope["delta"] as? [String: Any] else {
          throw ScreenshotQuestionError.invalidResponse
        }
        if delta["type"] as? String == "text_delta" {
          guard let text = delta["text"] as? String else {
            throw ScreenshotQuestionError.invalidResponse
          }
          progress.text += text
        }
      case "message_delta":
        guard let delta = envelope["delta"] as? [String: Any] else {
          throw ScreenshotQuestionError.invalidResponse
        }
        if Self.hasValue(delta["stop_reason"]) {
          try Self.checkMessageStop(delta["stop_reason"])
          progress.messageStoppedNormally = true
        }
      case "message_stop":
        guard progress.messageStarted && progress.messageStoppedNormally else {
          throw ScreenshotQuestionError.truncatedResponse
        }
        progress.completed = true
        done = true
      default: break
      }
    case .automatic: throw ScreenshotQuestionError.invalidConfiguration
    }
    if progress.text != previous {
      try Task.checkCancellation()
      await onPartial(progress.text)
    }
    return done
  }
}
