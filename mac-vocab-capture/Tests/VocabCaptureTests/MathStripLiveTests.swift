import AppKit
import Security
import LocalAuthentication
import XCTest
@testable import VocabCapture

/// Opt-in, one-call test against an isolated store and the original PDF crop.
@MainActor
final class MathStripLiveTests: XCTestCase {
  func testOriginalStripQuestionWithConfiguredModel() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["MATH_STRIP_LIVE_ARTIFACTS"], let image = env["MATH_STRIP_LIVE_IMAGE"] else {
      throw XCTSkip("Set MATH_STRIP_LIVE_ARTIFACTS and MATH_STRIP_LIVE_IMAGE for the opt-in real-model test")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let photo = try Data(contentsOf: URL(fileURLWithPath: image))
    _ = try XCTUnwrap(NSImage(data: photo))
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      let authentication = LAContext()
      authentication.interactionNotAllowed = env["MATH_SYSTEM_LIVE_KEYCHAIN_INTERACTION"] != "1"
      let account = id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)"
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account, kSecReturnData: true, kSecUseAuthenticationContext: authentication]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
      return String(decoding: data, as: UTF8.self)
    })
    let profile = try XCTUnwrap(preferences.profiles.first { $0.name == env["MATH_SYSTEM_LIVE_PROFILE"] }, "Set MATH_SYSTEM_LIVE_PROFILE to an existing profile name")
    let config = preferences.configuration(for: profile.id)
    guard !config.apiKey.isEmpty else { throw XCTSkip("Configured profile credentials unavailable; no request sent") }
    let client: ScreenshotQuestionClient
    if let executable = env["MATH_SYSTEM_LIVE_ENGINE_EXECUTABLE"] {
      client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: executable)))
    } else { client = ScreenshotQuestionClient() }
    let store = MathQuestionStore(directory: destination.appendingPathComponent("isolated-library"))
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let matcher = MathMethodMatcher(client: client)
    let select: MathMethodSelection = { question, context, methods in
      try await matcher.select(question: question, context: context, methods: methods,
        configuration: config, api: profile.api, directConnection: profile.directConnection)
    }
    var calls = 0
    let measured: ScreenshotQuestionMeasuredAnswer = { question, context, history, usage, partial in
      calls += 1
      try question.write(to: destination.appendingPathComponent("submitted-prompt.txt"), atomically: true, encoding: .utf8)
      do {
        return try await client.answer(question: question, context: context, history: history, configuration: config,
          api: profile.api, thinking: .off, directConnection: profile.directConnection, onUsage: usage, onPartial: partial)
      } catch {
        try? error.localizedDescription.write(to: destination.appendingPathComponent("request-error.txt"), atomically: true, encoding: .utf8)
        throw error
      }
    }
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in XCTFail("Measured path required"); return "" }, measuredAnswer: measured,
      originalImageData: photo, saveQuestion: { try await store.save($0) }, solutionModel: { config.model },
      mathStore: store, selectMethodAutomatically: select, singlePassAutomaticMethods: true, programArithmetic: true,
      singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<1800 {
      if !panel.isAnswering { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let answer = panel.history.last?.answer ?? ""
    let triangle = env["MATH_LIVE_TRIANGLE"] == "1"
    let validPresentation = triangle ? ScreenshotQuestionPanel.hasDeferredTrianglePresentation(in: answer)
      : ScreenshotQuestionPanel.hasDeferredGridPresentation(in: answer)
    try answer.write(to: destination.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
    let report: [String: Any] = ["model": config.model, "calls": calls, "completed": !panel.isAnswering,
      "answerPresent": !answer.isEmpty, "validPresentation": validPresentation,
      "preparation": panel.singlePassPreparationDurations,
      "elapsedSeconds": panel.performance?.elapsed as Any? ?? NSNull()]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("report.json"))
    panel.close()
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(answer.isEmpty)
    XCTAssertTrue(validPresentation, "Model did not submit the required valid drawing; inspect the retained answer before evaluating its correctness")
  }
}
