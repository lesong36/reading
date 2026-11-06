import AppKit
import CryptoKit
import Security

/// Explicit diagnostic entry point. Never initializes the normal application delegate.
struct MathRoutingEvaluationRequest {
  enum Failure: String, Error { case invalid_request, invalid_output_directory, invalid_photo, unknown_case, profile_unavailable, credential_unavailable, setup_failed, selection_failed }
  let outputDirectory: URL
  let model: String?
  let caseIDs: [String]
  let photo: Data?

  static func canonicalDestination(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
      missing.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    return missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
  }

  static func parse(_ data: Data, knownIDs: Set<String>) throws -> Self {
    guard data.count <= 65_536,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: ["output_directory", "model", "cases", "photo_path"]),
      let path = object["output_directory"] as? String, path.hasPrefix("/"),
      let ids = object["cases"] as? [String], !ids.isEmpty, ids.count <= 100,
      Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }),
      object["model"] == nil || (object["model"] as? String).map({ !$0.isEmpty && $0.utf8.count <= 200 }) == true,
      object["photo_path"] == nil || object["photo_path"] is String
    else { throw Failure.invalid_request }
    guard Set(ids).isSubset(of: knownIDs) else { throw Failure.unknown_case }
    let destination = canonicalDestination(URL(fileURLWithPath: path, isDirectory: true))
    let roots = [URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/private/tmp")]
      .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    guard roots.contains(where: { destination.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }),
      destination.path != Bundle.main.bundleURL.resolvingSymlinksInPath().path,
      !FileManager.default.fileExists(atPath: destination.appendingPathComponent("routing-report.json").path),
      !FileManager.default.fileExists(atPath: destination.appendingPathComponent("isolated-methods").path)
    else { throw Failure.invalid_output_directory }
    var photo: Data?
    if let imagePath = object["photo_path"] as? String {
      guard ids.count == 1, imagePath.hasPrefix("/") else { throw Failure.invalid_photo }
      let url = URL(fileURLWithPath: imagePath)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 8_000_000 else { throw Failure.invalid_photo }
      let bytes = try Data(contentsOf: url)
      guard bytes.count <= 8_000_000, NSImage(data: bytes) != nil else { throw Failure.invalid_photo }
      photo = bytes
    }
    return Self(outputDirectory: destination, model: object["model"] as? String, caseIDs: ids, photo: photo)
  }
}

struct MathRoutingEvaluationReport: Encodable {
  struct Row: Encodable {
    let case_id: String
    let method_id: String?
    let method_name: String?
    let visual_method_ids: [String]
    let visual_method_names: [String]
    let reason: String?
    let latency_seconds: Double
    let error: String?
    let input_mode: String
    let input_sha256: String
  }
  let schema_version = 1
  let model: String
  let answer_accuracy_evaluated = false
  let human_approval = false
  let production_data_modified = false
  let selection_protocol = "single_call"
  var warmup_seconds: Double?
  var source_hashes: [String: String] = [:]
  var cases: [Row] = []
  var error: String?

  func write(to directory: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: directory.appendingPathComponent("routing-report.json"), options: .atomic)
  }
}

@MainActor
final class MathRoutingEvaluationDelegate: NSObject, NSApplicationDelegate {
  private let requestPath: String
  init(requestPath: String) { self.requestPath = requestPath }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { await run(); NSApplication.shared.terminate(nil) }
  }

  /// Reads only an existing item; prevents diagnostic launches from showing a grant dialog.
  static func credential(profileID: String) -> String {
    var previous: DarwinBoolean = true
    guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return "" }
    defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    let account = profileID == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(profileID)"
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
      kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account,
      kSecReturnData: true, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
      let bytes = value as? Data else { return "" }
    return String(decoding: bytes, as: UTF8.self)
  }

  static func profile(_ preferences: ScreenshotQuestionPreferences, model: String?) throws -> ScreenshotQuestionModelProfile {
    let matches = model.map { target in preferences.profiles.filter { $0.model == target } }
      ?? preferences.profiles.filter { $0.id == preferences.selectedProfileID }
    guard matches.count == 1, let profile = matches.first else { throw MathRoutingEvaluationRequest.Failure.profile_unavailable }
    return profile
  }

  private func run() async {
    var destination: URL?
    var activeClient: ScreenshotQuestionClient?
    var report = MathRoutingEvaluationReport(model: "")
    do {
      let source = URL(fileURLWithPath: requestPath)
      guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536 else { throw MathRoutingEvaluationRequest.Failure.invalid_request }
      let catalogue = try MathTeachingReviewCatalogue.load()
      let request = try MathRoutingEvaluationRequest.parse(Data(contentsOf: source), knownIDs: Set(catalogue.cases.map(\.id)))
      try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
      destination = request.outputDirectory
      let defaults = UserDefaults(suiteName: "com.coty.vocab-capture") ?? .standard
      let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { Self.credential(profileID: $0) })
      let profile = try Self.profile(preferences, model: request.model)
      report = MathRoutingEvaluationReport(model: profile.model)
      let configuration = preferences.configuration(for: profile.id)
      guard !configuration.apiKey.isEmpty else { throw MathRoutingEvaluationRequest.Failure.credential_unavailable }
      let store = MathQuestionStore(directory: request.outputDirectory.appendingPathComponent("isolated-methods"))
      _ = try await store.importBundledMathSkills(catalogue.catalogue)
      let methods = try await store.automaticMethods()
      await store.close()
      report.source_hashes = Dictionary(uniqueKeysWithValues: methods.map { ($0.versionID, Self.digest(Data($0.instructions.utf8))) })
      if let executable = Bundle.main.executableURL,
        let bytes = try? Data(contentsOf: executable, options: .mappedIfSafe) {
        report.source_hashes["native_executable"] = Self.digest(bytes)
      }
      let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/QuestionEngine/QuestionEngine")
      if let bytes = try? Data(contentsOf: engine, options: .mappedIfSafe) {
        report.source_hashes["engine_executable"] = Self.digest(bytes)
      }
      let client = ScreenshotQuestionClient()
      activeClient = client
      let warmup = Date(); await client.warmUp(); report.warmup_seconds = Date().timeIntervalSince(warmup)
      try report.write(to: request.outputDirectory)
      let matcher = MathMethodMatcher(client: client)
      for id in request.caseIDs {
        guard let item = catalogue.cases.first(where: { $0.id == id }) else { continue }
        let photo = request.photo
        let context = ScreenshotQuestionContext(text: photo == nil ? item.stem : "", selectedWord: nil, imageData: photo)
        let question = "小学\(item.grade ?? 4)年级。\(item.user_constraint)"
        let input = photo ?? Data(item.stem.utf8)
        let started = Date()
        do {
          let match = try await matcher.select(question: question, context: context, methods: methods,
            configuration: configuration, api: profile.api, directConnection: profile.directConnection, mode: .singleCall)
          report.cases.append(.init(case_id: id, method_id: match.method?.id,
            method_name: match.method.flatMap { catalogue.catalogue.discoveryMetadata(for: $0)?.name },
            visual_method_ids: match.visualMethods.map(\.id), visual_method_names: match.visualMethods.compactMap { catalogue.catalogue.discoveryMetadata(for: $0)?.name },
            reason: match.reason, latency_seconds: Date().timeIntervalSince(started), error: nil,
            input_mode: photo == nil ? "text" : "original_photo", input_sha256: Self.digest(input)))
        } catch {
          report.cases.append(.init(case_id: id, method_id: nil, method_name: nil, visual_method_ids: [], visual_method_names: [],
            reason: nil, latency_seconds: Date().timeIntervalSince(started), error: Self.errorCode(error),
            input_mode: photo == nil ? "text" : "original_photo", input_sha256: Self.digest(input)))
        }
        try report.write(to: request.outputDirectory)
      }
    } catch {
      report.error = (error as? MathRoutingEvaluationRequest.Failure)?.rawValue ?? "setup_failed"
      if let destination { try? report.write(to: destination) }
      // No raw exception, endpoint, credential, or request contents leave this boundary.
      FileHandle.standardError.write(Data("Math routing diagnostic: \(report.error ?? "setup_failed")\n".utf8))
    }
    await activeClient?.shutdown()
  }

  static func errorCode(_ error: Error) -> String {
    if let transport = error as? LangChainTransportError {
      switch transport {
      case .requestTimeout: return "timeout"
      case .startupTimeout: return "startup_timeout"
      case .unavailable, .incompatibleRuntime: return "engine_unavailable"
      case .connection, .disconnected: return "connection"
      }
    }
    if let response = error as? ScreenshotQuestionError {
      switch response {
      case .server(let status): return "http_\(status)"
      case .invalidResponse, .emptyResponse, .truncatedResponse: return "invalid_output"
      case .unsupportedThinking: return "thinking_unsupported"
      case .invalidConfiguration: return "invalid_configuration"
      case .invalidImage: return "invalid_image"
      default: return "selection_failed"
      }
    }
    if error is MathMethodMatchError { return "invalid_output" }
    if error is CancellationError { return "cancelled" }
    return "selection_failed"
  }

  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
