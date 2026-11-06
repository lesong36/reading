import Foundation

/// Opens the existing application UI with fresh stores and no credentials or
/// automatic external services. This is deliberately not normal startup acceptance.
enum MathIsolatedReview {
  enum Failure: Error { case invalidDirectory, credentialsReadOnly }

  static func directory(path: String) throws -> URL {
    let fm = FileManager.default
    let destination = MathRoutingEvaluationRequest.canonicalDestination(URL(fileURLWithPath: path))
    let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    guard path.hasPrefix("/"), destination.path.hasPrefix(temporary + "/"),
      !fm.fileExists(atPath: destination.path),
      fm.fileExists(atPath: destination.deletingLastPathComponent().path)
    else { throw Failure.invalidDirectory }
    return destination
  }

  @MainActor
  static func makeDelegate(path: String) throws -> AppDelegate {
    guard Bundle.main.bundleURL.pathExtension != "app"
      || Bundle.main.bundleIdentifier?.hasSuffix(".math-review") == true
    else { throw Failure.invalidDirectory }
    let root = try directory(path: path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let suite = "VocabCapture.IsolatedMathReview." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.invalidDirectory }
    defaults.set(false, forKey: "VocabCapture.mathAutomaticTaggingEnabled")
    defaults.set(false, forKey: "VocabCapture.mathSkillLearningEnabled")
    let scope: [String: Any] = ["mode": "isolated-math-review", "directory": root.path,
      "defaultsSuite": suite, "credentialsAvailable": false,
      "automaticServicesEnabled": false, "normalStartupAcceptance": false]
    try JSONSerialization.data(withJSONObject: scope, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("launch-scope.json"), options: .atomic)
    return AppDelegate(
      cloudSync: SupabaseVocabularySync(readSession: { nil }, saveSession: { _ in }),
      store: VocabularyStore(directory: root.appendingPathComponent("vocabulary")),
      shortcutPreferences: ShortcutPreferences(defaults: defaults),
      questionPreferences: ScreenshotQuestionPreferences(defaults: defaults,
        readAPIKey: { "" }, saveAPIKey: { _ in throw Failure.credentialsReadOnly },
        readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in throw Failure.credentialsReadOnly }),
      searchPreferences: ScreenshotQuestionWebSearchPreferences(defaults: defaults,
        readAPIKey: { "" }, saveAPIKey: { _ in throw Failure.credentialsReadOnly }),
      defaults: defaults, readDictionaryKey: { "" },
      saveDictionaryKey: { _ in throw Failure.credentialsReadOnly },
      browserBridge: BrowserContextBridge(defaults: defaults, port: 0),
      regionCapture: ScreenshotRegionCapture(permission: { false }),
      mathQuestionStore: MathQuestionStore(directory: root.appendingPathComponent("math")),
      isolatedMathReview: true)
  }
}
