import Foundation
import XCTest

@testable import VocabCapture

extension XCTestCase {
  @MainActor
  func makeIsolatedAppDelegate(defaults providedDefaults: UserDefaults? = nil) -> AppDelegate {
    let suite = "VocabCapture.IsolatedAppTests.\(UUID().uuidString)"
    let defaults = providedDefaults ?? UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(suite, isDirectory: true)
    addTeardownBlock {
      if providedDefaults == nil { defaults.removePersistentDomain(forName: suite) }
      try? FileManager.default.removeItem(at: directory)
    }
    return AppDelegate(
      cloudSync: SupabaseVocabularySync(readSession: { nil }, saveSession: { _ in }),
      store: VocabularyStore(directory: directory),
      shortcutPreferences: ShortcutPreferences(defaults: defaults),
      questionPreferences: ScreenshotQuestionPreferences(
        defaults: defaults, readAPIKey: { "" }, saveAPIKey: { _ in },
        readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in }),
      searchPreferences: ScreenshotQuestionWebSearchPreferences(
        defaults: defaults, readAPIKey: { "" }, saveAPIKey: { _ in }),
      defaults: defaults, readDictionaryKey: { "" }, saveDictionaryKey: { _ in },
      browserBridge: BrowserContextBridge(defaults: defaults),
      regionCapture: ScreenshotRegionCapture(permission: { false }))
  }
}
