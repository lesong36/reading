import Foundation

/// Stores only a profile identity. Credentials remain owned by screenshot model preferences.
final class MathResearchModelPreferences {
  static let profileIDKey = "VocabCapture.mathResearchProfileID"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var selectedProfileID: String? { defaults.string(forKey: Self.profileIDKey) }

  func select(profileID: String?, available: [ScreenshotQuestionModelProfile]) throws {
    guard let profileID else {
      defaults.removeObject(forKey: Self.profileIDKey)
      return
    }
    guard available.contains(where: { $0.id == profileID }) else {
      throw ScreenshotQuestionPreferencesError.missingProfile
    }
    defaults.set(profileID, forKey: Self.profileIDKey)
  }

  func resolve(preferences: ScreenshotQuestionPreferences,
    fallback: AIConfiguration) -> MathTagModelConfiguration {
    guard let id = selectedProfileID else {
      return .init(configuration: preferences.configuration(fallingBackTo: fallback),
        api: preferences.selectedAPI, directConnection: preferences.selectedDirectConnection)
    }
    // A removed explicit selection is an error state, not permission to switch providers.
    guard let profile = preferences.profiles.first(where: { $0.id == id }) else {
      return .init(configuration: .init(baseURL: "", model: "", apiKey: ""),
        api: .automatic, directConnection: false)
    }
    return .init(configuration: preferences.configuration(for: id),
      api: profile.api, directConnection: profile.directConnection)
  }
}
