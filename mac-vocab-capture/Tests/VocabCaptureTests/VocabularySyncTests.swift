import XCTest

@testable import VocabCapture

final class VocabularySyncTests: XCTestCase {
  func testFailedSaveCanBeRetriedWithoutLeavingAnUnsavedEntry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    let file = directory.appendingPathComponent("vocabulary.json")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let dictionary = DictionaryResult(
      lemma: "", meaning: "词义", partOfSpeech: "n.", pronunciation: "", note: "")
    do {
      _ = try await store.add(word: "retry", dictionary: dictionary, context: "Please retry.")
      XCTFail("Expected persistence to fail")
    } catch {}
    let unsaved = await store.all()
    XCTAssertTrue(unsaved.isEmpty)
    try FileManager.default.removeItem(at: file)
    _ = try await store.add(word: "retry", dictionary: dictionary, context: "Please retry.")
    let reopened = VocabularyStore(directory: directory)
    let persisted = await reopened.all()
    XCTAssertEqual(persisted.map(\.word), ["retry"])
  }

  func testSyncPreservesSavesMadeWhileRequestWasInFlight() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    let dictionary = DictionaryResult(
      lemma: "", meaning: "词义", partOfSpeech: "n.", pronunciation: "", note: "")
    _ = try await store.add(word: "old", dictionary: dictionary, context: "An old word.")
    let snapshot = await store.all()
    _ = try await store.add(word: "new", dictionary: dictionary, context: "A new word.")
    // Cloud removed 'old' after the request began; local 'new' must survive.
    try await store.applySync([], basedOn: snapshot)
    let entries = await store.all()
    XCTAssertEqual(entries.map(\.word), ["new"])
    let reopened = VocabularyStore(directory: directory)
    let persisted = await reopened.all()
    XCTAssertEqual(persisted, entries)
  }
}
