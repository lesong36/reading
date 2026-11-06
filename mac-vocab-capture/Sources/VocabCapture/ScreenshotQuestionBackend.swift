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

  /// Learning uses the same private pipe and configured model, but a separate graph task.
  /// The caller persists the returned review state in the question database.
  func learnSkills(
    learning: Data, imageData: Data, methods: [MathTeachingMethod],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI = .automatic,
    directConnection: Bool = false
  ) async throws -> String {
    guard let langChain else { throw ScreenshotQuestionError.invalidConfiguration }
    let payload = try Self.learningPayload(learning: learning, imageData: imageData,
      methods: methods, configuration: configuration, api: api, directConnection: directConnection)
    return try await langChain.answer(payload: payload, onPartial: { _ in })
  }

  static func learningPayload(
    learning: Data, imageData: Data, methods: [MathTeachingMethod],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI = .automatic,
    directConnection: Bool = false
  ) throws -> Data {
    guard let snapshot = try JSONSerialization.jsonObject(with: learning)
      as? [String: Any] else { throw ScreenshotQuestionError.invalidConfiguration }
    let data = try Self.payload(
      question: snapshot["profile_review"] == nil
        ? "检查本题与已有方法的覆盖，积累重复结构；只提交待人工审查的候选。"
        : "审校已有方法的精确版本；只报告五项教研意见，等待用户审核。",
      context: ScreenshotQuestionContext(
        text: snapshot["profile_review"] != nil
          ? "方法精确版本与证据列在本次教研资料中。"
          : snapshot["originals"] == nil ? "" : "原图按题号列在本次教研资料中。",
        selectedWord: nil,
        imageData: snapshot["originals"] == nil && !imageData.isEmpty ? imageData : nil), history: [],
      configuration: configuration, api: api, thinking: .off,
      directConnection: directConnection, webSearch: nil, instructions: "题目原图是题意依据，OCR和模型答案不是已核验事实。",
      teachingSkills: nil)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ScreenshotQuestionError.invalidResponse
    }
    object["task"] = "math_skill_learning"
    object["learning"] = snapshot
    // Exact-version profile review already carries the full method and bound evidence.
    // It never performs whole-library coverage, so unrelated inventory must not consume its request budget.
    if snapshot["profile_review"] != nil {
      object["teaching_skills"] = [[String: String]]()
    } else {
      // Complete local inventory; engine pages it before disclosing bodies to a model.
      object["teaching_catalogue"] = Self.skillEntries(methods)
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  func answer(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI = .automatic,
    thinking: ScreenshotQuestionThinking = .off,
    directConnection: Bool = false,
    webSearch: ScreenshotQuestionWebSearchConfiguration? = nil,
    instructions: String = ScreenshotQuestionInstructions.text,
    teachingSkills: [MathTeachingMethod]? = nil,
    selectionProtocol: MathMethodSelectionProtocol? = nil,
    onUsage: @escaping @MainActor @Sendable (ScreenshotQuestionUsage) -> Void = { _ in },
    onProgress: @escaping @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void = { _ in },
    onPartial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    // Recheck at submission if the selected profile changed during retrieval.
    // Never silently drop supplied references and then claim they were sent.
    if !context.mathReferences.isEmpty
      && !MathReviewedExample.supportsAutomaticUse(configuration: configuration, api: api) {
      throw ScreenshotQuestionError.invalidConfiguration
    }
    if let native {
      guard webSearch == nil else { throw ScreenshotQuestionWebSearchError.unsupportedBackend }
      let nativeQuestion: String
      if let teachingSkills {
        let data = try JSONSerialization.data(withJSONObject: Self.skillEntries(teachingSkills, singleCall: selectionProtocol == .singleCall))
        nativeQuestion = question + "\n候选方法 JSON：\n" + String(decoding: data, as: UTF8.self)
      } else {
        nativeQuestion = question
      }
      return try await native.answer(
        question: nativeQuestion, context: context, history: history, configuration: configuration,
        api: api, instructions: teachingSkills == nil && question.contains(MathDiagramAnswer.marker)
          ? ScreenshotQuestionInstructions.forDiagrams(instructions) : instructions,
        mathSelection: teachingSkills != nil, onPartial: onPartial)
    }
    guard let langChain else { throw ScreenshotQuestionError.invalidConfiguration }
    let payload = try Self.payload(
      question: question, context: context, history: history, configuration: configuration,
      api: api, thinking: thinking, directConnection: directConnection, webSearch: webSearch,
      instructions: instructions, teachingSkills: teachingSkills, selectionProtocol: selectionProtocol
    )
    return try await langChain.answer(
      payload: payload, onUsage: onUsage, onProgress: onProgress, onPartial: onPartial)
  }

  static func payload(
    question: String, context: ScreenshotQuestionContext, history: [ScreenshotQuestionTurn],
    configuration: AIConfiguration, api: ScreenshotQuestionAPI,
    thinking: ScreenshotQuestionThinking = .off, directConnection: Bool = false,
    webSearch: ScreenshotQuestionWebSearchConfiguration? = nil,
    instructions: String = ScreenshotQuestionInstructions.text,
    teachingSkills: [MathTeachingMethod]? = nil,
    selectionProtocol: MathMethodSelectionProtocol? = nil
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
    let references = try NativeScreenshotQuestionClient.reviewedReferencePayload(context.mathReferences)
    if !references.isEmpty { source["math_references"] = references }
    let nativeOnly = teachingSkills == nil && question.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix)
    let rendererTools = nativeOnly || (teachingSkills == nil && question.hasPrefix(MathStructuredSolution.rendererRequestPrefix))
    let mathSubmission = rendererTools || (teachingSkills == nil && question.hasPrefix(MathStructuredSolution.submissionRequestPrefix))
    let mathSolution = mathSubmission || (teachingSkills == nil && question.hasPrefix(MathStructuredSolution.requestPrefix))
    var payload: [String: Any] = [
      "question": question,
      "context": source,
      "history": history.suffix(6).map {
        ["question": String($0.question.prefix(2_000)), "answer": String($0.answer.prefix(6_000))]
      },
      "instructions": rendererTools ? ScreenshotQuestionInstructions.forMathRendererTools(instructions)
        : mathSubmission ? ScreenshotQuestionInstructions.forMathSubmission(instructions)
        : mathSolution ? ScreenshotQuestionInstructions.forMathSolution(instructions)
        : teachingSkills == nil && question.contains(MathDiagramAnswer.marker)
          ? ScreenshotQuestionInstructions.forDiagrams(instructions) : instructions,
      "configuration": [
        "model": configuration.model,
        "api_key": configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
        "endpoint": endpoint.absoluteString,
        "api": api.rawValue,
        "thinking": (rendererTools || teachingSkills != nil && selectionProtocol == .singleCall ? ScreenshotQuestionThinking.off : thinking).rawValue,
        "direct_connection": directConnection,
      ],
    ]
    if let webSearch {
      let searchKey = webSearch.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !searchKey.isEmpty else { throw ScreenshotQuestionWebSearchError.notConfigured }
      payload["web_search"] = [
        "api_key": searchKey, "direct_connection": webSearch.directConnection,
      ]
    }
    if let teachingSkills {
      payload["task"] = "math_method_selection"
      if let selectionProtocol { payload["selection_protocol"] = selectionProtocol.rawValue }
      payload["teaching_skills"] = Self.skillEntries(teachingSkills, singleCall: selectionProtocol == .singleCall)
    } else if mathSolution {
      payload["response_mode"] = "math_solution"
      if mathSubmission {
        let strict = api == .chatCompletions && endpoint.host == "api.deepseek.com"
          && endpoint.path == "/beta/chat/completions"
        payload["solution_protocol"] = rendererTools
          ? (strict ? "renderer_tools_strict" : "renderer_tools")
          : (strict ? "single_submission_strict" : "single_submission")
        if nativeOnly { payload["diagram_scope"] = "native_only" }
      }
    } else if question.contains("```math-diagrams") {
      payload["response_mode"] = "math_diagrams"
    }
    return try JSONSerialization.data(withJSONObject: payload)
  }

  // Shared with request budgeting so eligibility and version metadata are counted exactly as sent.
  static func skillEntries(_ methods: [MathTeachingMethod], singleCall: Bool = false) -> [[String: String]] {
    let catalogue = try? MathSkillCatalogue.load()
    let research = try? MathTeachingReviewCatalogue.load()
    return methods.map { method in
      var entry = ["id": method.id, "version_id": method.versionID, "title": method.title,
       "category": method.category, "instructions": method.instructions]
      // A local edit remains its own immutable skill. Never attach stale routing
      // metadata from a bundled version to changed user instructions.
      if let metadata = catalogue?.discoveryMetadata(for: method) {
        entry["skill_name"] = metadata.name
        entry["description"] = metadata.description
      }
      if let policy = MathMethodMatcher.eligibilityPolicy(for: method, catalogue: research),
        let data = try? JSONEncoder().encode(policy), let text = String(data: data, encoding: .utf8) {
        entry["teaching_policy"] = text
      }
      let rolePolicy = singleCall ? MathMethodMatcher.singleCallRolePolicy(for: method, catalogue: research)
        : MathMethodMatcher.selectionRolePolicy(for: method, catalogue: research)
      if let policy = rolePolicy,
        let data = try? JSONEncoder().encode(policy), let text = String(data: data, encoding: .utf8) {
        entry["selection_role_policy"] = text
      }
      return entry
    }
  }
}
