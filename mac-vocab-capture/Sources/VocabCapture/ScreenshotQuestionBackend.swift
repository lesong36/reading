import Foundation

/// Production bundles use the local LangChain runtime. An explicitly injected
/// URLSession keeps the native adapter available for isolated transport tests.
actor ScreenshotQuestionClient {
  private let native: NativeScreenshotQuestionClient?
  private let langChain: LangChainQuestionTransport?

  init() {
    let executable: URL
    if Bundle.main.bundleURL.pathExtension == "app" {
      executable = Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Helpers/QuestionEngine/QuestionEngine")
    } else {
      let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      executable = project.appendingPathComponent(
        "build/langchain/dist/QuestionEngine/QuestionEngine")
    }
    native = nil
    langChain = LangChainQuestionTransport(executableURL: executable)
  }

  init(session: URLSession) {
    native = NativeScreenshotQuestionClient(session: session)
    langChain = nil
  }

  init(langChain: LangChainQuestionTransport) {
    native = nil
    self.langChain = langChain
  }

  func warmUp() async {
    // Preloading imports sends no screenshot, credentials, or model request.
    try? await langChain?.warmUp()
  }

  func shutdown() async { await langChain?.shutdown() }

  func answer(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI = .automatic,
    thinking: ScreenshotQuestionThinking = .off,
    directConnection: Bool = false,
    onUsage: @escaping @MainActor @Sendable (ScreenshotQuestionUsage) -> Void = { _ in },
    onPartial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    if let native {
      return try await native.answer(
        question: question, context: context, history: history, configuration: configuration,
        api: api, onPartial: onPartial)
    }
    guard let langChain else { throw ScreenshotQuestionError.invalidConfiguration }
    let payload = try Self.payload(
      question: question, context: context, history: history, configuration: configuration,
      api: api, thinking: thinking, directConnection: directConnection
    )
    return try await langChain.answer(payload: payload, onUsage: onUsage, onPartial: onPartial)
  }

  static func payload(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI,
    thinking: ScreenshotQuestionThinking = .off, directConnection: Bool = false
  ) throws -> Data {
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
    let endpoint = try api.endpoint(for: configuration)
    let image = try NativeScreenshotQuestionClient.image(context.imageData)
    var source: [String: Any] = ["text": context.text]
    if let word = context.selectedWord { source["selected_word"] = word }
    if let image { source["image_data"] = image.data }
    return try JSONSerialization.data(withJSONObject: [
      "question": question,
      "context": source,
      "history": history.suffix(6).map {
        ["question": String($0.question.prefix(2_000)), "answer": String($0.answer.prefix(6_000))]
      },
      "instructions": ScreenshotQuestionInstructions.text,
      "configuration": [
        "model": configuration.model,
        "api_key": configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
        "endpoint": endpoint.absoluteString,
        "api": api.rawValue,
        "thinking": thinking.rawValue,
        "direct_connection": directConnection,
      ],
    ])
  }
}
