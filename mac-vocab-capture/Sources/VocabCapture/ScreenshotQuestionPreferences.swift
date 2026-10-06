import Foundation

struct ScreenshotQuestionModelProfile: Codable, Equatable, Identifiable {
  let id: String
  let name: String
  let baseURL: String
  let model: String
  let api: ScreenshotQuestionAPI
  let thinking: ScreenshotQuestionThinking
  let directConnection: Bool

  init(
    id: String, name: String, baseURL: String, model: String,
    api: ScreenshotQuestionAPI = .automatic, thinking: ScreenshotQuestionThinking = .off,
    directConnection: Bool = false
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.model = model
    self.api = api
    self.thinking = thinking
    self.directConnection = directConnection
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, baseURL, model, api, thinking, directConnection
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    baseURL = try values.decode(String.self, forKey: .baseURL)
    model = try values.decode(String.self, forKey: .model)
    api = try values.decodeIfPresent(ScreenshotQuestionAPI.self, forKey: .api) ?? .automatic
    thinking =
      try values.decodeIfPresent(ScreenshotQuestionThinking.self, forKey: .thinking) ?? .off
    directConnection = try values.decodeIfPresent(Bool.self, forKey: .directConnection) ?? false
  }
}

enum ScreenshotQuestionPreferencesError: LocalizedError {
  case missingProfile, missingName

  var errorDescription: String? {
    switch self {
    case .missingProfile: return "这个问答模型已不存在，请重新选择。"
    case .missingName: return "请给问答模型起一个名称。"
    }
  }
}

final class ScreenshotQuestionPreferences {
  static let configurationKey = "VocabCapture.questionAIConfiguration"
  static let enabledKey = "VocabCapture.questionAIConfigurationEnabled"
  static let profilesKey = "VocabCapture.questionModelProfiles"
  static let fallbackThinkingKey = "VocabCapture.questionFallbackThinking"
  static let fallbackDirectConnectionKey = "VocabCapture.questionFallbackDirectConnection"
  static let legacyProfileID = "legacy"

  static let defaultProfile = ScreenshotQuestionModelProfile(
    id: "default-deepseek-flash", name: "DeepSeek Flash", baseURL: "https://api.deepseek.com",
    model: "deepseek-flash")

  /// Only seed an untouched installation. Saved choices and legacy profiles win.
  func prepareDefaultModel() {
    guard defaults.object(forKey: Self.profilesKey) == nil,
      defaults.object(forKey: Self.configurationKey) == nil,
      defaults.object(forKey: Self.enabledKey) == nil
    else { return }
    try? persist(State(profiles: [Self.defaultProfile], selectedProfileID: Self.defaultProfile.id))
  }

  private struct State: Codable {
    var profiles: [ScreenshotQuestionModelProfile]
    var selectedProfileID: String?
  }

  private let defaults: UserDefaults
  private let readProfileAPIKey: (String) -> String
  private let saveProfileAPIKey: (String, String) throws -> Void

  init(
    defaults: UserDefaults = .standard,
    readAPIKey: @escaping () -> String = { KeychainStore.readQuestionAPIKey() },
    saveAPIKey: @escaping (String) throws -> Void = { try KeychainStore.saveQuestionAPIKey($0) },
    readProfileAPIKey: ((String) -> String)? = nil,
    saveProfileAPIKey: ((String, String) throws -> Void)? = nil
  ) {
    self.defaults = defaults
    self.readProfileAPIKey =
      readProfileAPIKey ?? { id in
        id == Self.legacyProfileID ? readAPIKey() : KeychainStore.readQuestionProfileAPIKey(id: id)
      }
    self.saveProfileAPIKey =
      saveProfileAPIKey ?? { id, key in
        if id == Self.legacyProfileID {
          try saveAPIKey(key)
        } else {
          try KeychainStore.saveQuestionProfileAPIKey(key, id: id)
        }
      }
  }

  var profiles: [ScreenshotQuestionModelProfile] { state.profiles }
  var selectedProfileID: String? { state.selectedProfileID }
  var isEnabled: Bool { selectedProfileID != nil }
  var selectedAPI: ScreenshotQuestionAPI {
    profiles.first { $0.id == selectedProfileID }?.api ?? .automatic
  }
  var fallbackThinking: ScreenshotQuestionThinking {
    defaults.string(forKey: Self.fallbackThinkingKey)
      .flatMap(ScreenshotQuestionThinking.init(rawValue:)) ?? .off
  }
  var selectedThinking: ScreenshotQuestionThinking {
    guard let selectedProfileID else { return fallbackThinking }
    return profiles.first { $0.id == selectedProfileID }?.thinking ?? .off
  }

  var fallbackDirectConnection: Bool { defaults.bool(forKey: Self.fallbackDirectConnectionKey) }
  var selectedDirectConnection: Bool {
    guard let selectedProfileID else { return fallbackDirectConnection }
    return profiles.first { $0.id == selectedProfileID }?.directConnection ?? false
  }

  func setDirectConnection(_ direct: Bool) {
    var updated = state
    guard let selectedProfileID = updated.selectedProfileID else {
      defaults.set(direct, forKey: Self.fallbackDirectConnectionKey)
      return
    }
    guard let index = updated.profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
      return
    }
    let previous = updated.profiles[index]
    updated.profiles[index] = ScreenshotQuestionModelProfile(
      id: previous.id, name: previous.name, baseURL: previous.baseURL, model: previous.model,
      api: previous.api, thinking: previous.thinking, directConnection: direct)
    try? persist(updated)
  }

  func setThinking(_ thinking: ScreenshotQuestionThinking) {
    var updated = state
    guard let selectedProfileID = updated.selectedProfileID else {
      defaults.set(thinking.rawValue, forKey: Self.fallbackThinkingKey)
      return
    }
    guard let index = updated.profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
      return
    }
    let previous = updated.profiles[index]
    updated.profiles[index] = ScreenshotQuestionModelProfile(
      id: previous.id, name: previous.name, baseURL: previous.baseURL, model: previous.model,
      api: previous.api, thinking: thinking, directConnection: previous.directConnection)
    try? persist(updated)
  }

  func configuration(for profileID: String) -> AIConfiguration {
    guard let profile = profiles.first(where: { $0.id == profileID }) else {
      return AIConfiguration(baseURL: "", model: "", apiKey: "")
    }
    return AIConfiguration(
      baseURL: profile.baseURL, model: profile.model, apiKey: readProfileAPIKey(profileID))
  }

  func configuration(
    fallingBackTo dictionaryConfiguration: @autoclosure () -> AIConfiguration
  ) -> AIConfiguration {
    guard let id = selectedProfileID else { return dictionaryConfiguration() }
    return configuration(for: id)
  }

  func selectProfile(_ id: String?) {
    var updated = state
    guard id == nil || updated.profiles.contains(where: { $0.id == id }) else { return }
    updated.selectedProfileID = id
    try? persist(updated)
  }

  @discardableResult
  func saveProfile(
    id: String? = nil, name: String, configuration: AIConfiguration,
    api: ScreenshotQuestionAPI = .automatic, thinking: ScreenshotQuestionThinking = .off,
    directConnection: Bool = false
  ) throws -> String {
    if let id, !profiles.contains(where: { $0.id == id }) {
      throw ScreenshotQuestionPreferencesError.missingProfile
    }
    let profileID = id ?? UUID().uuidString
    try persistProfile(
      id: profileID, name: name, configuration: configuration, api: api, thinking: thinking,
      directConnection: directConnection)
    return profileID
  }

  func removeProfile(id: String) throws {
    var updated = state
    guard updated.profiles.contains(where: { $0.id == id }) else {
      throw ScreenshotQuestionPreferencesError.missingProfile
    }
    updated.profiles.removeAll { $0.id == id }
    if updated.selectedProfileID == id { updated.selectedProfileID = nil }
    let data = try JSONEncoder().encode(updated)
    try saveProfileAPIKey(id, "")
    defaults.set(data, forKey: Self.profilesKey)
  }

  func useDictionaryConfiguration() { selectProfile(nil) }

  private var state: State {
    migrateLegacyConfiguration()
    if defaults.object(forKey: Self.profilesKey) == nil {
      return State(profiles: [], selectedProfileID: nil)
    }
    guard let data = defaults.data(forKey: Self.profilesKey),
      let decoded = try? JSONDecoder().decode(State.self, from: data),
      Set(decoded.profiles.map(\.id)).count == decoded.profiles.count,
      decoded.profiles.allSatisfy({ !$0.id.isEmpty })
    else {
      // Broken active settings must not silently send content through the dictionary service.
      return State(profiles: [], selectedProfileID: Self.legacyProfileID)
    }
    return decoded
  }

  private func persistProfile(
    id: String, name: String, configuration: AIConfiguration, api: ScreenshotQuestionAPI,
    thinking: ScreenshotQuestionThinking, directConnection: Bool
  ) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ScreenshotQuestionPreferencesError.missingName }
    let profile = ScreenshotQuestionModelProfile(
      id: id, name: name, baseURL: configuration.baseURL, model: configuration.model, api: api,
      thinking: thinking, directConnection: directConnection)
    var updated = state
    if let index = updated.profiles.firstIndex(where: { $0.id == id }) {
      updated.profiles[index] = profile
    } else {
      updated.profiles.append(profile)
    }
    let data = try JSONEncoder().encode(updated)
    try saveProfileAPIKey(id, configuration.apiKey)
    defaults.set(data, forKey: Self.profilesKey)
  }

  private func persist(_ state: State) throws {
    defaults.set(try JSONEncoder().encode(state), forKey: Self.profilesKey)
  }

  private func migrateLegacyConfiguration() {
    guard defaults.object(forKey: Self.profilesKey) == nil,
      defaults.object(forKey: Self.configurationKey) != nil
        || defaults.object(forKey: Self.enabledKey) != nil
    else { return }
    let wasEnabled = defaults.bool(forKey: Self.enabledKey)
    var migrated: [ScreenshotQuestionModelProfile] = []
    if let data = defaults.data(forKey: Self.configurationKey),
      let legacy = try? JSONDecoder().decode(AIConfiguration.self, from: data)
    {
      migrated.append(
        ScreenshotQuestionModelProfile(
          id: Self.legacyProfileID, name: "原问答模型", baseURL: legacy.baseURL, model: legacy.model))
    }
    guard
      (try? persist(
        State(profiles: migrated, selectedProfileID: wasEnabled ? Self.legacyProfileID : nil)))
        != nil
    else { return }
    defaults.removeObject(forKey: Self.configurationKey)
    defaults.removeObject(forKey: Self.enabledKey)
  }
}
