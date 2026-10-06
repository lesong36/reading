import Foundation

final class ScreenshotQuestionWebSearchPreferences {
  static let directConnectionKey = "VocabCapture.questionWebSearchDirectConnection"
  private let defaults: UserDefaults
  private let readAPIKey: () -> String
  private let saveAPIKey: (String) throws -> Void

  init(
    defaults: UserDefaults = .standard,
    readAPIKey: @escaping () -> String = KeychainStore.readWebSearchAPIKey,
    saveAPIKey: @escaping (String) throws -> Void = KeychainStore.saveWebSearchAPIKey
  ) {
    self.defaults = defaults
    self.readAPIKey = readAPIKey
    self.saveAPIKey = saveAPIKey
  }

  var apiKey: String { readAPIKey() }
  var directConnection: Bool { defaults.bool(forKey: Self.directConnectionKey) }

  func configuration() throws -> ScreenshotQuestionWebSearchConfiguration {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw ScreenshotQuestionWebSearchError.notConfigured }
    return ScreenshotQuestionWebSearchConfiguration(apiKey: key, directConnection: directConnection)
  }

  func save(apiKey: String, directConnection: Bool) throws {
    try saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    defaults.set(directConnection, forKey: Self.directConnectionKey)
  }
}
