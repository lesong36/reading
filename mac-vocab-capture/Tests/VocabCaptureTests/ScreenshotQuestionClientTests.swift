import Foundation
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotQuestionClientTests: XCTestCase {
  private let configuration = AIConfiguration(
    baseURL: "https://questions.test/v1", model: "reading-model", apiKey: "test-credential")
  private let context = ScreenshotQuestionContext(
    text: "API token prices are separate from subscription usage.\nFull second paragraph.",
    selectedWord: "separate from", imageData: nil)

  override func tearDown() {
    QuestionURLProtocol.handler = nil
    super.tearDown()
  }

  private func client() -> ScreenshotQuestionClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QuestionURLProtocol.self]
    return ScreenshotQuestionClient(session: URLSession(configuration: config))
  }

  private func body(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let bytes = request.httpBody {
      data = bytes
    } else if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      data = bytes
    } else {
      data = Data()
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func event(_ fragment: String, finish: String? = nil) -> Data {
    var choice: [String: Any] = ["delta": ["content": fragment]]
    if let finish { choice["finish_reason"] = finish }
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
    return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
  }

  private func envelope(_ content: String, finish: String = "stop") -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": content], "finish_reason": finish]]
    ])
  }

  func testRequestKeepsFullOCRAndTargetWithoutImageOrDictionaryFormat() async throws {
    QuestionURLProtocol.handler = { request, transport in
      XCTAssertEqual(request.url?.path, "/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
      let body = try! self.body(request)
      XCTAssertEqual(body["stream"] as? Bool, true)
      XCTAssertEqual(body["max_tokens"] as? Int, 900)
      XCTAssertNil(body["response_format"])
      let messages = body["messages"] as! [[String: Any]]
      XCTAssertEqual(messages.count, 3)
      XCTAssertEqual(messages[0]["role"] as? String, "system")
      let source = messages[1]["content"] as! String
      XCTAssertTrue(source.contains(self.context.text))
      XCTAssertTrue(source.contains("separate from"))
      XCTAssertEqual(messages[2]["content"] as? String, "这里是什么意思？")
      transport.respond(mime: "application/json", chunks: [self.envelope("分开计费。")])
    }
    let answer = try await client().answer(
      question: " 这里是什么意思？ ", context: context, history: [], configuration: configuration,
      onPartial: { _ in })
    XCTAssertEqual(answer, "分开计费。")
  }

  func testGrammarJudgmentUsesStandardSyntaxAndAllowsCorrectionOfPriorAnswer() async throws {
    let currentQuestion = "There's a new car in front of my sister and I. 这句话正确吗？"
    let oldAnswer = "截图里的句子完全没有问题。"
    QuestionURLProtocol.handler = { request, transport in
      let messages = try! self.body(request)["messages"] as! [[String: Any]]
      let instructions = messages[0]["content"] as! String
      XCTAssertTrue(instructions.contains("标准书面和考试英语"))
      XCTAssertTrue(instructions.contains("具体修改和结构依据"))
      XCTAssertTrue(instructions.contains("实际句法位置"))
      XCTAssertTrue(instructions.contains("动词或介词的宾语用宾格"))
      XCTAssertTrue(instructions.contains("并列项可拆开检验"))
      XCTAssertTrue(instructions.contains("不改变人称、数或指代"))
      XCTAssertTrue(instructions.contains("区分口语常见与标准正确"))
      XCTAssertTrue(instructions.contains("结论须与原句及所述规则一致"))
      XCTAssertTrue(instructions.contains("新句子或修正是本轮分析对象"))
      XCTAssertTrue(instructions.contains("历史助手回答可能有误"))
      XCTAssertTrue(instructions.contains("发现之前判断错误时明确更正"))
      XCTAssertFalse(
        instructions.contains("his sister"), "Rules must not hardcode reported sentences")
      XCTAssertFalse(
        instructions.contains("my sister"), "Rules must generalize beyond the regression")
      XCTAssertEqual(messages[3]["content"] as? String, oldAnswer)
      XCTAssertEqual(messages.last?["role"] as? String, "user")
      XCTAssertEqual(messages.last?["content"] as? String, currentQuestion)
      transport.respond(mime: "application/json", chunks: [self.envelope("测试传输回答。")])
    }
    _ = try await client().answer(
      question: currentQuestion, context: context,
      history: [ScreenshotQuestionTurn(question: "检查原句。", answer: oldAnswer)],
      configuration: configuration, onPartial: { _ in })
  }

  func testImageRemainsAttachedDuringFollowupsAndHistoryIsBounded() async throws {
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2])
    let history = (0..<10).map {
      ScreenshotQuestionTurn(
        question: "question \($0) " + String(repeating: "Q", count: 2_500),
        answer: "answer \($0) " + String(repeating: "A", count: 6_500))
    }
    QuestionURLProtocol.handler = { request, transport in
      let messages = try! self.body(request)["messages"] as! [[String: Any]]
      XCTAssertEqual(messages.count, 15)
      let parts = messages[1]["content"] as! [[String: Any]]
      let attachment = parts[1]["image_url"] as! [String: String]
      XCTAssertEqual(attachment["url"], "data:image/png;base64," + image.base64EncodedString())
      XCTAssertTrue((messages[2]["content"] as! String).hasPrefix("question 4 "))
      XCTAssertEqual((messages[2]["content"] as! String).count, 2_000)
      XCTAssertEqual((messages[3]["content"] as! String).count, 6_000)
      XCTAssertTrue((messages[13]["content"] as! String).hasPrefix("answer 9 "))
      transport.respond(mime: "application/json", chunks: [self.envelope("图中所示。")])
    }
    _ = try await client().answer(
      question: "为什么？",
      context: ScreenshotQuestionContext(text: context.text, selectedWord: nil, imageData: image),
      history: history, configuration: configuration, onPartial: { _ in })
  }

  func testJPEGAndImageOnlyContextAreSupported() async throws {
    let image = Data([0xff, 0xd8, 0xff, 1])
    QuestionURLProtocol.handler = { request, transport in
      let messages = try! self.body(request)["messages"] as! [[String: Any]]
      let parts = messages[1]["content"] as! [[String: Any]]
      XCTAssertTrue(
        ((parts[1]["image_url"] as! [String: String])["url"]!).hasPrefix("data:image/jpeg;"))
      transport.respond(mime: "application/json", chunks: [self.envelope("图像回答。")])
    }
    _ = try await client().answer(
      question: "图上是什么？",
      context: ScreenshotQuestionContext(text: "", selectedWord: nil, imageData: image),
      history: [], configuration: configuration, onPartial: { _ in })
  }

  func testStreamPublishesAccumulatedChineseBeforeCompletion() async throws {
    let partial = expectation(description: "first answer before completion")
    var values: [String] = []
    var active: QuestionURLProtocol?
    QuestionURLProtocol.handler = { _, transport in
      active = transport
      transport.respond(
        mime: "text/event-stream",
        chunks: [self.event("这表示"), self.event("分开计费。"), Data("data: [DONE]\n\n".utf8)],
        interval: 0.1)
    }
    let task = Task {
      try await client().answer(
        question: "解释", context: context, history: [], configuration: configuration,
        onPartial: { value in
          values.append(value)
          if values.count == 1 {
            XCTAssertEqual(active?.deliveredChunkCount, 1)
            partial.fulfill()
          }
        })
    }
    await fulfillment(of: [partial], timeout: 2)
    let answer = try await task.value
    XCTAssertEqual(answer, "这表示分开计费。")
    XCTAssertEqual(values, ["这表示", "这表示分开计费。"])
  }

  func testCRLFMultilineUnicodeByteSplitsAndStopAtEOF() async throws {
    let json = try JSONSerialization.data(
      withJSONObject: [
        "choices": [["delta": ["content": "中文😀"], "finish_reason": "stop"]]
      ], options: .prettyPrinted)
    let frame =
      ": keep-alive\r\n"
      + String(decoding: json, as: UTF8.self).components(separatedBy: "\n")
      .map { "data: " + $0 }.joined(separator: "\r\n")
    let chunks = frame.utf8.map { Data([$0]) }
    QuestionURLProtocol.handler = { _, transport in
      transport.respond(mime: "text/event-stream", chunks: chunks)
    }
    let answer = try await client().answer(
      question: "解释", context: context, history: [], configuration: configuration,
      onPartial: { _ in })
    XCTAssertEqual(answer, "中文😀")
  }

  func testTruncatedEOFLengthAndContentFilterNeverSucceed() async throws {
    let streams = [
      [event("未完整回答")],
      [event("未完整回答", finish: "length"), Data("data: [DONE]\n\n".utf8)],
      [event("", finish: "content_filter"), Data("data: [DONE]\n\n".utf8)],
    ]
    for chunks in streams {
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "text/event-stream", chunks: chunks)
      }
      do {
        _ = try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration,
          onPartial: { _ in })
        XCTFail("Truncated answer must fail")
      } catch ScreenshotQuestionError.truncatedResponse {}
    }
  }

  func testMalformedStreamAndErrorEnvelopeFail() async throws {
    for payload in ["not JSON", #"{"error":{"message":"failed"}}"#] {
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "text/event-stream", chunks: [Data("data: \(payload)\n\n".utf8)])
      }
      do {
        _ = try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration,
          onPartial: { _ in XCTFail("Malformed frame cannot publish") })
        XCTFail("Invalid response must fail")
      } catch ScreenshotQuestionError.invalidResponse {}
    }
  }

  func testJSONFallbackPublishesOnceAndRejectsEmptyOrTruncatedContent() async throws {
    var values: [String] = []
    QuestionURLProtocol.handler = { _, transport in
      transport.respond(mime: "application/json", chunks: [self.envelope(" 完整回答。 ")])
    }
    let answer = try await client().answer(
      question: "解释", context: context, history: [], configuration: configuration,
      onPartial: { values.append($0) })
    XCTAssertEqual(answer, "完整回答。")
    XCTAssertEqual(values.count, 1)
    for (value, finish) in [("   ", "stop"), ("部分回答", "length")] {
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "application/json", chunks: [self.envelope(value, finish: finish)])
      }
      do {
        _ = try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration,
          onPartial: { _ in XCTFail("Unusable fallback must not publish") })
        XCTFail("Unusable fallback must fail")
      } catch {}
    }
  }

  func testCancellationStopsTransport() async throws {
    let began = expectation(description: "began")
    let stopped = expectation(description: "stopped")
    QuestionURLProtocol.handler = { _, transport in
      transport.onStop = { stopped.fulfill() }
      transport.respond(mime: "text/event-stream", chunks: [self.event("尚在生成")], interval: 5)
      began.fulfill()
    }
    let task = Task {
      try await client().answer(
        question: "解释", context: context, history: [], configuration: configuration,
        onPartial: { _ in XCTFail("Canceled response must not publish") })
    }
    await fulfillment(of: [began], timeout: 2)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled request must fail")
    } catch {}
    await fulfillment(of: [stopped], timeout: 2)
  }

  func testHTTPFailureAndValidationDoNotPublish() async throws {
    QuestionURLProtocol.handler = { _, transport in
      transport.respond(mime: "application/json", chunks: [self.envelope("unused")], status: 503)
    }
    do {
      _ = try await client().answer(
        question: "解释", context: context, history: [], configuration: configuration,
        onPartial: { _ in XCTFail("HTTP failure must not publish") })
      XCTFail("HTTP failure must fail")
    } catch ScreenshotQuestionError.server(let status) { XCTAssertEqual(status, 503) }
    QuestionURLProtocol.handler = { _, _ in XCTFail("Invalid request must not start network") }
    let cases: [(String, ScreenshotQuestionContext, AIConfiguration)] = [
      (" \n ", context, configuration),
      ("解释", ScreenshotQuestionContext(text: "", selectedWord: nil, imageData: nil), configuration),
      ("解释", context, AIConfiguration(baseURL: "file:///tmp", model: "model", apiKey: "")),
      ("解释", context, AIConfiguration(baseURL: "https://questions.test", model: " ", apiKey: "")),
      (
        "解释",
        ScreenshotQuestionContext(text: "source", selectedWord: nil, imageData: Data([1, 2])),
        configuration
      ),
    ]
    for (question, context, configuration) in cases {
      do {
        _ = try await client().answer(
          question: question, context: context, history: [], configuration: configuration,
          onPartial: { _ in XCTFail("Validation failure must not publish") })
        XCTFail("Invalid request must fail")
      } catch {}
    }
  }
  private func jsonData(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value)
  }

  private func nativeFrame(_ value: [String: Any]) -> Data {
    Data("event: \(value["type"] ?? "message")\ndata: ".utf8) + jsonData(value) + Data("\n\n".utf8)
  }

  private func responseObject(_ text: String, status: String = "completed") -> [String: Any] {
    [
      "status": status, "error": NSNull(), "incomplete_details": NSNull(),
      "output": [
        [
          "type": "message", "role": "assistant",
          "content": [["type": "output_text", "text": text]],
        ]
      ],
    ]
  }

  private func messageObject(_ text: String, stop: String = "end_turn") -> [String: Any] {
    ["type": "message", "stop_reason": stop, "content": [["type": "text", "text": text]]]
  }

  private func nativeFrames(_ api: ScreenshotQuestionAPI, text: String) -> [Data] {
    if api == .responses {
      return [
        nativeFrame(["type": "response.created", "response": ["status": "in_progress"]]),
        nativeFrame(["type": "response.output_text.delta", "delta": text]),
        nativeFrame(["type": "response.completed", "response": responseObject(text)]),
      ]
    }
    return [
      nativeFrame(["type": "message_start", "message": ["type": "message", "content": []]]),
      nativeFrame([
        "type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""],
      ]),
      nativeFrame([
        "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text],
      ]),
      nativeFrame(["type": "content_block_stop", "index": 0]),
      nativeFrame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
      nativeFrame(["type": "message_stop"]),
    ]
  }

  func testAutomaticProtocolIsLimitedToExactProviderHostsAndAllowsOverrides() throws {
    for host in ["api.aicodewith.com", "api.aicodewith.ai"] {
      var config = AIConfiguration(baseURL: "https://\(host)/v1", model: " gpt-test ", apiKey: "")
      XCTAssertEqual(ScreenshotQuestionAPI.automatic.resolved(for: config), .responses)
      config.model = "Claude-test"
      XCTAssertEqual(ScreenshotQuestionAPI.automatic.resolved(for: config), .anthropicMessages)
      config.model = "deepseek-chat"
      XCTAssertEqual(ScreenshotQuestionAPI.automatic.resolved(for: config), .chatCompletions)
      XCTAssertEqual(ScreenshotQuestionAPI.responses.resolved(for: config), .responses)
    }
    for host in [
      "questions.test", "api.deepseek.com", "api.aicodewith.com.evil.test", "sub.api.aicodewith.ai",
    ] {
      for model in ["gpt-test", "claude-test"] {
        let config = AIConfiguration(baseURL: "https://\(host)/v1", model: model, apiKey: "")
        XCTAssertEqual(ScreenshotQuestionAPI.automatic.resolved(for: config), .chatCompletions)
      }
    }
    for api in ScreenshotQuestionAPI.allCases {
      XCTAssertFalse(api.title.isEmpty)
      XCTAssertEqual(
        try JSONDecoder().decode(ScreenshotQuestionAPI.self, from: JSONEncoder().encode(api)), api)
    }
  }

  func testNativeEndpointNormalizationPreservesHostAndCustomPath() throws {
    let cases: [(ScreenshotQuestionAPI, String, String)] = [
      (.responses, "https://api.aicodewith.ai", "/chatgpt/v1/responses"),
      (.responses, "https://api.aicodewith.com/v1/", "/chatgpt/v1/responses"),
      (.responses, "https://api.aicodewith.ai/chatgpt/v1", "/chatgpt/v1/responses"),
      (.responses, "https://api.aicodewith.com/chatgpt/v1/responses", "/chatgpt/v1/responses"),
      (.anthropicMessages, "https://api.aicodewith.ai/", "/v1/messages"),
      (.anthropicMessages, "https://api.aicodewith.com/v1", "/v1/messages"),
      (.anthropicMessages, "https://api.aicodewith.ai/v1/messages", "/v1/messages"),
      (.responses, "https://custom.test", "/v1/responses"),
      (.responses, "https://custom.test/v1", "/v1/responses"),
      (.responses, "https://custom.test/proxy/v2", "/proxy/v2/responses"),
      (.anthropicMessages, "https://custom.test", "/v1/messages"),
      (.anthropicMessages, "https://custom.test/proxy/v2", "/proxy/v2/messages"),
    ]
    for (api, base, expectedPath) in cases {
      let config = AIConfiguration(baseURL: base, model: "test", apiKey: "")
      let url = try api.endpoint(for: config)
      XCTAssertEqual(url.host, URL(string: base)?.host)
      XCTAssertEqual(url.path, expectedPath)
    }
    let withPort = AIConfiguration(baseURL: "http://custom.test:5432/v1", model: "test", apiKey: "")
    XCTAssertEqual(try ScreenshotQuestionAPI.responses.endpoint(for: withPort).port, 5432)
  }

  func testProviderGPTAutomaticRequestUsesResponsesAndBearerWithoutTemperature() async throws {
    let config = AIConfiguration(
      baseURL: "https://api.aicodewith.ai/v1", model: "gpt-test", apiKey: " \n gpt-key \r\n")
    QuestionURLProtocol.handler = { request, transport in
      XCTAssertEqual(request.url?.host, "api.aicodewith.ai")
      XCTAssertEqual(request.url?.path, "/chatgpt/v1/responses")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.timeoutInterval, 90)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gpt-key")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
      XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
      let body = try! self.body(request)
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual(body["max_output_tokens"] as? Int, 4_096)
      XCTAssertEqual(body["stream"] as? Bool, true)
      XCTAssertNil(body["temperature"])
      XCTAssertNil(body["messages"])
      XCTAssertNotNil(body["instructions"] as? String)
      transport.respond(
        mime: "application/json", chunks: [self.jsonData(self.responseObject("GPT 回答"))])
    }
    let result = try await client().answer(
      question: "解释", context: context, history: [], configuration: config, onPartial: { _ in })
    XCTAssertEqual(result, "GPT 回答")
    XCTAssertEqual(
      config.apiKey, " \n gpt-key \r\n", "Header trimming must not mutate saved credentials")
  }

  func testProviderClaudeAutomaticRequestUsesMessagesAndOnlyNativeAuthentication() async throws {
    let config = AIConfiguration(
      baseURL: "https://api.aicodewith.com", model: "claude-test", apiKey: " \n claude-key \n")
    QuestionURLProtocol.handler = { request, transport in
      XCTAssertEqual(request.url?.host, "api.aicodewith.com")
      XCTAssertEqual(request.url?.path, "/v1/messages")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let body = try! self.body(request)
      XCTAssertNotNil(body["system"] as? String)
      XCTAssertEqual(body["max_tokens"] as? Int, 900)
      let messages = body["messages"] as! [[String: Any]]
      XCTAssertFalse(messages.contains { $0["role"] as? String == "system" })
      transport.respond(
        mime: "application/json", chunks: [self.jsonData(self.messageObject("Claude 回答"))])
    }
    let result = try await client().answer(
      question: "解释", context: context, history: [], configuration: config, onPartial: { _ in })
    XCTAssertEqual(result, "Claude 回答")
  }

  func testDeepseekChatAndExplicitOverrideRemainIndependent() async throws {
    let cases: [(AIConfiguration, ScreenshotQuestionAPI)] = [
      (
        AIConfiguration(
          baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "deepseek-key"),
        .automatic
      ),
      (
        AIConfiguration(
          baseURL: "https://api.aicodewith.ai/v1", model: "gpt-test", apiKey: "override-key"),
        .chatCompletions
      ),
    ]
    for (config, api) in cases {
      QuestionURLProtocol.handler = { request, transport in
        XCTAssertEqual(request.url?.host, URL(string: config.baseURL)?.host)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"), "Bearer " + config.apiKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try! self.body(request)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["max_tokens"] as? Int, 900)
        XCTAssertNil(body["input"])
        transport.respond(mime: "application/json", chunks: [self.envelope("通用回答")])
      }
      _ = try await client().answer(
        question: "解释", context: context, history: [], configuration: config, api: api,
        onPartial: { _ in })
    }
  }

  func testNativeRequestsPreserveImageTargetAndBoundedHistory() async throws {
    let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1])
    let history = (0..<9).map {
      ScreenshotQuestionTurn(
        question: "Q\($0)" + String(repeating: "q", count: 2_500),
        answer: "A\($0)" + String(repeating: "a", count: 6_500))
    }
    for api in [ScreenshotQuestionAPI.responses, .anthropicMessages] {
      QuestionURLProtocol.handler = { request, transport in
        let body = try! self.body(request)
        let messages = body[api == .responses ? "input" : "messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 14)
        let source = messages[0]["content"] as! [[String: Any]]
        XCTAssertTrue((source[0]["text"] as! String).contains(self.context.text))
        XCTAssertTrue((source[0]["text"] as! String).contains("separate from"))
        if api == .responses {
          XCTAssertEqual(source[0]["type"] as? String, "input_text")
          XCTAssertEqual(source[1]["type"] as? String, "input_image")
          XCTAssertEqual(
            source[1]["image_url"] as? String,
            "data:image/png;base64," + image.base64EncodedString())
        } else {
          XCTAssertEqual(source[1]["type"] as? String, "image")
          let encoded = source[1]["source"] as! [String: String]
          XCTAssertEqual(encoded["type"], "base64")
          XCTAssertEqual(encoded["media_type"], "image/png")
          XCTAssertEqual(encoded["data"], image.base64EncodedString())
        }
        let firstQuestion =
          api == .responses
          ? messages[1]["content"] as! String
          : (messages[1]["content"] as! [[String: Any]])[0]["text"] as! String
        let firstAnswer =
          api == .responses
          ? messages[2]["content"] as! String
          : (messages[2]["content"] as! [[String: Any]])[0]["text"] as! String
        XCTAssertTrue(firstQuestion.hasPrefix("Q3"))
        XCTAssertEqual(firstQuestion.count, 2_000)
        XCTAssertEqual(firstAnswer.count, 6_000)
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        let result = api == .responses ? self.responseObject("图片追问") : self.messageObject("图片追问")
        transport.respond(mime: "application/json", chunks: [self.jsonData(result)])
      }
      _ = try await client().answer(
        question: "为什么？",
        context: ScreenshotQuestionContext(
          text: context.text, selectedWord: context.selectedWord, imageData: image),
        history: history, configuration: configuration, api: api, onPartial: { _ in })
    }
  }

  func testNativeStreamsPublishCumulativeTextBeforeFinalCompletion() async throws {
    for api in [ScreenshotQuestionAPI.responses, .anthropicMessages] {
      let first = expectation(description: "\(api) early text")
      var partials: [String] = []
      var active: QuestionURLProtocol?
      var frames = nativeFrames(api, text: "第一部分")
      if api == .responses {
        frames.replaceSubrange(
          1...1,
          with: [
            nativeFrame(["type": "response.output_text.delta", "delta": "第一"]),
            nativeFrame(["type": "response.output_text.delta", "delta": "部分"]),
          ])
      } else {
        frames.replaceSubrange(
          2...2,
          with: [
            nativeFrame([
              "type": "content_block_delta", "delta": ["type": "text_delta", "text": "第一"],
            ]),
            nativeFrame([
              "type": "content_block_delta", "delta": ["type": "text_delta", "text": "部分"],
            ]),
          ])
      }
      let firstDeltaCount = api == .responses ? 2 : 3
      let initialFrames =
        Array(frames.prefix(firstDeltaCount)) + [
          Data((":" + String(repeating: " ", count: 16_384) + "\n\n").utf8)
        ]
      let remainingFrames = Array(frames.dropFirst(firstDeltaCount))
      QuestionURLProtocol.handler = { _, transport in
        active = transport
        transport.respond(mime: "text/event-stream", chunks: initialFrames, finish: false)
      }
      let task = Task {
        try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration, api: api,
          onPartial: { value in
            partials.append(value)
            if partials.count == 1 {
              XCTAssertEqual(active?.deliveredChunkCount, initialFrames.count)
              first.fulfill()
              active?.finish(chunks: remainingFrames)
            }
          })
      }
      await fulfillment(of: [first], timeout: 2)
      let result = try await task.value
      XCTAssertEqual(result, "第一部分")
      XCTAssertEqual(partials, ["第一", "第一部分"])
    }
  }

  func testResponsesFollowupUsesPlainTextHistoryIncludingAssistant() async throws {
    QuestionURLProtocol.handler = { request, transport in
      let body = try! self.body(request)
      let input = body["input"] as! [[String: Any]]
      XCTAssertEqual(input[1]["content"] as? String, "之前的问题")
      XCTAssertEqual(input[2]["role"] as? String, "assistant")
      XCTAssertEqual(input[2]["content"] as? String, "之前的回答")
      XCTAssertEqual(input[3]["content"] as? String, "继续解释")
      transport.respond(
        mime: "application/json", chunks: [self.jsonData(self.responseObject("追问回答"))])
    }
    _ = try await client().answer(
      question: "继续解释", context: context,
      history: [ScreenshotQuestionTurn(question: "之前的问题", answer: "之前的回答")],
      configuration: configuration, api: .responses, onPartial: { _ in })
  }

  func testNativeSSESupportsCRLFMultilineUnicodeAndProtocolEvents() async throws {
    for api in [ScreenshotQuestionAPI.responses, .anthropicMessages] {
      let frames = nativeFrames(api, text: "中文😀")
      var bytes = Data()
      for frame in frames {
        let line = String(decoding: frame, as: UTF8.self).components(separatedBy: "\n").first {
          $0.hasPrefix("data:")
        }!
        let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
        let pretty = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
        let payload = String(decoding: pretty, as: UTF8.self).components(separatedBy: "\n").map {
          "data: " + $0
        }.joined(separator: "\r\n")
        bytes.append(Data(": ping\r\nevent: ignored-name\r\n\(payload)\r\n\r\n".utf8))
      }
      let chunks = bytes.map { Data([$0]) }
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "text/event-stream", chunks: chunks)
      }
      let result = try await client().answer(
        question: "解释", context: context, history: [], configuration: configuration, api: api,
        onPartial: { _ in })
      XCTAssertEqual(result, "中文😀")
    }
  }

  func testNativeJSONCompletionRejectsFailedTruncatedAndEmptyResponses() async throws {
    let cases: [(ScreenshotQuestionAPI, [String: Any])] = [
      (.responses, responseObject("partial", status: "incomplete")),
      (.responses, responseObject("partial", status: "failed")),
      (.responses, ["status": "completed", "output": [], "error": ["message": "private-error"]]),
      (.responses, responseObject("")),
      (.anthropicMessages, messageObject("partial", stop: "max_tokens")),
      (.anthropicMessages, messageObject("partial", stop: "tool_use")),
      (.anthropicMessages, messageObject("")),
    ]
    for (api, value) in cases {
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "application/json", chunks: [self.jsonData(value)])
      }
      do {
        _ = try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration, api: api,
          onPartial: { _ in XCTFail("Incomplete/error/empty JSON must not publish") })
        XCTFail("Native invalid completion must fail")
      } catch { XCTAssertFalse(error.localizedDescription.contains("private-error")) }
    }
  }

  func testNativeStreamsRejectDONEOnlyErrorsAndMissingLifecycleCompletion() async throws {
    let responseDelta = nativeFrame(["type": "response.output_text.delta", "delta": "部分"])
    let messageStart = nativeFrame([
      "type": "message_start", "message": ["type": "message", "content": []],
    ])
    let messageDelta = nativeFrame([
      "type": "content_block_delta", "delta": ["type": "text_delta", "text": "部分"],
    ])
    let done = Data("data: [DONE]\n\n".utf8)
    let cases: [(ScreenshotQuestionAPI, [Data])] = [
      (.responses, [responseDelta]),
      (.responses, [responseDelta, done]),
      (.responses, [responseDelta, nativeFrame(["type": "response.incomplete"])]),
      (.responses, [responseDelta, nativeFrame(["type": "response.failed"])]),
      (.responses, [responseDelta, nativeFrame(["type": "error", "message": "private-error"])]),
      (
        .responses,
        [
          responseDelta,
          nativeFrame([
            "type": "response.completed", "response": responseObject("部分", status: "incomplete"),
          ]),
        ]
      ),
      (.anthropicMessages, [messageStart, messageDelta]),
      (.anthropicMessages, [messageStart, messageDelta, done]),
      (.anthropicMessages, [messageStart, messageDelta, nativeFrame(["type": "message_stop"])]),
      (
        .anthropicMessages,
        [
          messageDelta,
          nativeFrame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
          nativeFrame(["type": "message_stop"]),
        ]
      ),
      (
        .anthropicMessages,
        [
          messageStart, messageDelta,
          nativeFrame(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]]),
        ]
      ),
      (
        .anthropicMessages,
        [
          messageStart, messageDelta,
          nativeFrame(["type": "error", "error": ["message": "private-error"]]),
        ]
      ),
    ]
    for (api, chunks) in cases {
      QuestionURLProtocol.handler = { _, transport in
        transport.respond(mime: "text/event-stream", chunks: chunks)
      }
      do {
        _ = try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration, api: api,
          onPartial: { _ in })
        XCTFail("Missing or failed native completion must fail")
      } catch { XCTAssertFalse(error.localizedDescription.contains("private-error")) }
    }
  }

  func testCancellationStopsBothNativeProtocolTransports() async throws {
    for api in [ScreenshotQuestionAPI.responses, .anthropicMessages] {
      let began = expectation(description: "\(api) started")
      let stopped = expectation(description: "\(api) stopped")
      QuestionURLProtocol.handler = { _, transport in
        transport.onStop = { stopped.fulfill() }
        transport.respond(
          mime: "text/event-stream", chunks: self.nativeFrames(api, text: "pending"), interval: 5)
        began.fulfill()
      }
      let task = Task {
        try await client().answer(
          question: "解释", context: context, history: [], configuration: configuration, api: api,
          onPartial: { _ in XCTFail("Cancelled response cannot publish") })
      }
      await fulfillment(of: [began], timeout: 2)
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Cancelled native request must fail")
      } catch {}
      await fulfillment(of: [stopped], timeout: 2)
    }
  }

  func testSafeHTTPDiagnosticsNeverEchoResponseOrRetryOtherHosts() async throws {
    for api in [ScreenshotQuestionAPI.chatCompletions, .responses, .anthropicMessages] {
      for status in [401, 403, 404, 429] {
        var requests = 0
        QuestionURLProtocol.handler = { request, transport in
          requests += 1
          XCTAssertEqual(request.url?.host, "questions.test")
          transport.respond(
            mime: "application/json", chunks: [Data("private-error-and-credential".utf8)],
            status: status)
        }
        do {
          _ = try await client().answer(
            question: "解释", context: context, history: [], configuration: configuration, api: api,
            onPartial: { _ in XCTFail("HTTP error cannot publish") })
          XCTFail("HTTP error must fail")
        } catch ScreenshotQuestionError.server(let received) {
          XCTAssertEqual(received, status)
          let message = ScreenshotQuestionError.server(received).localizedDescription
          XCTAssertTrue(message.contains("HTTP \(status)"))
          XCTAssertFalse(message.contains("private-error-and-credential"))
          XCTAssertFalse(message.contains(self.configuration.apiKey))
        }
        XCTAssertEqual(
          requests, 1, "Protocol errors must not reroute or retry credentials elsewhere")
      }
    }
  }

}

private final class QuestionURLProtocol: URLProtocol {
  static var handler: ((URLRequest, QuestionURLProtocol) -> Void)?
  var onStop: (() -> Void)?
  var deliveredChunkCount = 0
  private var work: [DispatchWorkItem] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.handler?(request, self) }
  override func stopLoading() {
    for item in work { item.cancel() }
    onStop?()
    onStop = nil
  }

  func respond(
    mime: String, chunks: [Data], interval: Double = 0, status: Int = 200,
    finish: Bool = true
  ) {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
    for (index, chunk) in chunks.enumerated() {
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.deliveredChunkCount += 1
        self.client?.urlProtocol(self, didLoad: chunk)
        if finish, index == chunks.count - 1 { self.client?.urlProtocolDidFinishLoading(self) }
      }
      work.append(item)
      DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index + 1), execute: item)
    }
  }

  func finish(chunks: [Data]) {
    for chunk in chunks {
      deliveredChunkCount += 1
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}
