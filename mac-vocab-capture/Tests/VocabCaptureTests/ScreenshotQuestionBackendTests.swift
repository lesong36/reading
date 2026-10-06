import Foundation
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionBackendTests: XCTestCase {
  func testSearchPayloadKeepsIndependentKeyAndOfflinePayloadOmitsSearch() throws {
    let configuration = AIConfiguration(
      baseURL: "https://example.test/v1", model: "model", apiKey: "model-test-key")
    let context = ScreenshotQuestionContext(text: "Source", selectedWord: nil, imageData: nil)
    let offline = try ScreenshotQuestionClient.payload(
      question: "Question", context: context, history: [], configuration: configuration,
      api: .chatCompletions)
    let offlineObject = try XCTUnwrap(JSONSerialization.jsonObject(with: offline) as? [String: Any])
    XCTAssertNil(offlineObject["web_search"])
    let online = try ScreenshotQuestionClient.payload(
      question: "Question", context: context, history: [], configuration: configuration,
      api: .chatCompletions,
      webSearch: ScreenshotQuestionWebSearchConfiguration(
        apiKey: " search-test-key ", directConnection: true))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: online) as? [String: Any])
    let search = try XCTUnwrap(object["web_search"] as? [String: Any])
    XCTAssertEqual(search["api_key"] as? String, "search-test-key")
    XCTAssertEqual(search["direct_connection"] as? Bool, true)
    let model = try XCTUnwrap(object["configuration"] as? [String: Any])
    XCTAssertEqual(model["api_key"] as? String, "model-test-key")
    XCTAssertFalse((object["instructions"] as? String ?? "").contains("search-test-key"))
  }

  func testMissingSearchKeyIsRejectedBeforeStartingEngine() {
    XCTAssertThrowsError(
      try ScreenshotQuestionClient.payload(
        question: "Question",
        context: ScreenshotQuestionContext(text: "Source", selectedWord: nil, imageData: nil),
        history: [],
        configuration: AIConfiguration(
          baseURL: "https://example.test/v1", model: "model", apiKey: "model-key"),
        api: .chatCompletions,
        webSearch: ScreenshotQuestionWebSearchConfiguration(apiKey: " \n "))
    ) { error in
      guard case ScreenshotQuestionWebSearchError.notConfigured = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  @MainActor
  func testLangChainBackendForwardsReportedUsageBeforeReturning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vocab-backend-usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fixture.py")
    try #"""
    import json, sys
    print(json.dumps({"type": "ready", "protocol": 1, "langchain_version": "1.4.3"}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get("op") == "answer":
            print(json.dumps({"type": "done", "id": frame["id"], "text": "answer",
                              "usage": {"input_tokens": 6, "output_tokens": 2}}), flush=True)
    """#.write(to: script, atomically: true, encoding: .utf8)
    let transport = LangChainQuestionTransport(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
    let client = ScreenshotQuestionClient(langChain: transport)
    var usages: [ScreenshotQuestionUsage] = []
    let answer = try await client.answer(
      question: "Question",
      context: ScreenshotQuestionContext(text: "Source", selectedWord: nil, imageData: nil),
      history: [],
      configuration: AIConfiguration(
        baseURL: "https://example.test/v1", model: "test-model", apiKey: "fake-key"),
      onUsage: { usages.append($0) }, onPartial: { _ in })
    XCTAssertEqual(answer, "answer")
    XCTAssertEqual(usages, [ScreenshotQuestionUsage(inputTokens: 6, outputTokens: 2)])
    await client.shutdown()
  }

  private func payload(
    question: String = " 这里是什么意思？ ",
    context: ScreenshotQuestionContext = ScreenshotQuestionContext(
      text: "Full OCR context", selectedWord: "context", imageData: nil),
    history: [ScreenshotQuestionTurn] = [],
    model: String = "gpt-6.1-sol", api: ScreenshotQuestionAPI = .automatic
  ) throws -> [String: Any] {
    let data = try ScreenshotQuestionClient.payload(
      question: question, context: context, history: history,
      configuration: AIConfiguration(
        baseURL: "https://api.aicodewith.com/v1", model: model, apiKey: " fake-key "),
      api: api)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testPayloadKeepsPromptContextAndResolvedResponsesGateway() throws {
    let body = try payload()
    XCTAssertEqual(body["question"] as? String, "这里是什么意思？")
    let context = try XCTUnwrap(body["context"] as? [String: Any])
    XCTAssertEqual(context["text"] as? String, "Full OCR context")
    XCTAssertEqual(context["selected_word"] as? String, "context")
    XCTAssertNil(context["image_data"])
    XCTAssertEqual(body["instructions"] as? String, ScreenshotQuestionInstructions.text)
    let config = try XCTUnwrap(body["configuration"] as? [String: Any])
    XCTAssertEqual(config["endpoint"] as? String, "https://api.aicodewith.com/chatgpt/v1/responses")
    XCTAssertEqual(config["api"] as? String, "responses")
    XCTAssertEqual(config["api_key"] as? String, "fake-key")
  }

  func testClaudeAndExplicitChatKeepTheirConfiguredProtocol() throws {
    let claude = try XCTUnwrap(
      try payload(model: "claude-sonnet-5-5")["configuration"] as? [String: Any])
    XCTAssertEqual(claude["endpoint"] as? String, "https://api.aicodewith.com/v1/messages")
    XCTAssertEqual(claude["api"] as? String, "anthropicMessages")
    let chat = try XCTUnwrap(try payload(api: .chatCompletions)["configuration"] as? [String: Any])
    XCTAssertEqual(chat["api"] as? String, "chatCompletions")
    XCTAssertEqual(chat["endpoint"] as? String, "https://api.aicodewith.com/v1/chat/completions")
  }

  func testImageOnlyContextIsKeptAndInvalidImageRejected() throws {
    let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    let context = ScreenshotQuestionContext(text: "", selectedWord: nil, imageData: png)
    let source = try XCTUnwrap(try payload(context: context)["context"] as? [String: Any])
    XCTAssertEqual(source["image_data"] as? String, png.base64EncodedString())
    XCTAssertNil(source["selected_word"])
    XCTAssertThrowsError(
      try payload(
        context: ScreenshotQuestionContext(
          text: "text", selectedWord: nil, imageData: Data("invalid".utf8)))
    ) { error in
      guard case ScreenshotQuestionError.invalidImage = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testHistoryWindowAndContentBoundsArePreserved() throws {
    let history = (0..<9).map {
      ScreenshotQuestionTurn(
        question: "\($0)" + String(repeating: "问", count: 3_000),
        answer: String(repeating: "答", count: 7_000))
    }
    let turns = try XCTUnwrap(try payload(history: history)["history"] as? [[String: String]])
    XCTAssertEqual(turns.count, 6)
    XCTAssertTrue(turns[0]["question"]?.hasPrefix("3") == true)
    XCTAssertEqual(turns[0]["question"]?.count, 2_000)
    XCTAssertEqual(turns[0]["answer"]?.count, 6_000)
  }

  func testInputValidationHappensBeforeStartingRuntime() {
    XCTAssertThrowsError(try payload(question: " \n ")) { error in
      guard case ScreenshotQuestionError.emptyQuestion = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(
      try payload(
        context: ScreenshotQuestionContext(
          text: "", selectedWord: nil, imageData: nil))
    ) { error in
      guard case ScreenshotQuestionError.missingContext = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(try payload(model: "")) { error in
      guard case ScreenshotQuestionError.invalidConfiguration = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }
}
