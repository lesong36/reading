import Foundation
import XCTest
@testable import VocabCapture

private actor CoordinatorCloudFixture {
  var userID: String? = "account-a"
  var requests = 0
  var failures = 0
  var httpFailure: Int?
  var vocabulary: [VocabularyEntry] = []
  var revision: Int64 = 0
  func setUser(_ value: String?) { userID = value }
  func failNext() { failures += 1 }
  func failHTTP(_ status: Int) { httpFailure = status }
  func sync(_ batch: VocabularySyncBatch) async throws -> VocabularySyncResult {
    requests += 1
    try await Task.sleep(nanoseconds: 20_000_000)
    if let status = httpFailure { httpFailure = nil; throw SupabaseSyncError.http(status) }
    if failures > 0 { failures -= 1; throw URLError(.notConnectedToInternet) }
    for operation in batch.operations {
      vocabulary.removeAll { VocabularyEntry.canonicalWordKey($0.word) == operation.wordKey }
      if let entry = operation.entry { vocabulary.append(entry) }
    }
    revision += 1
    return VocabularySyncResult(userID: batch.userID, vocabulary: vocabulary,
      uploadedCount: batch.operations.count, revision: revision,
      acknowledgedOperationIDs: batch.operations.map(\.operationID), tombstones: [],
      conflict: false, conflictingWordKeys: [])
  }
}

final class VocabularySyncCoordinatorTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-coordinator-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func add(_ word: String, to store: VocabularyStore) async throws {
    _ = try await store.add(word: word,
      dictionary: DictionaryResult(lemma: word, meaning: "测试", partOfSpeech: "noun", pronunciation: "", note: ""),
      context: "This is a public \(word) fixture.")
  }
  private func coordinator(_ store: VocabularyStore, _ cloud: CoordinatorCloudFixture) -> VocabularySyncCoordinator {
    VocabularySyncCoordinator(store: store,
      currentUserID: { await cloud.userID }, synchronize: { try await cloud.sync($0) }, debounce: 0.01)
  }

  func testManualAndAutomaticSyncShareOneFlight() async throws {
    let store = VocabularyStore(directory: try directory())
    let cloud = CoordinatorCloudFixture()
    let coordinator = coordinator(store, cloud)
    try await coordinator.prepareAccount()
    try await add("alpha", to: store)
    async let first = coordinator.sync()
    async let second = coordinator.sync()
    let results = try await (first, second)
    XCTAssertEqual(results.0.totalCount, 1)
    XCTAssertEqual(results.1.totalCount, 1)
    let requests = await cloud.requests
    let pending = await store.pendingCount()
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(pending, 0)
  }

  func testOfflineSaveSurvivesRestartAndRetriesThroughCoordinator() async throws {
    let path = try directory()
    let store = VocabularyStore(directory: path)
    let cloud = CoordinatorCloudFixture()
    let first = coordinator(store, cloud)
    try await first.prepareAccount()
    try await add("alpha", to: store)
    await cloud.failNext()
    do { _ = try await first.sync(); XCTFail("Offline must not acknowledge") } catch {}
    let pending = await store.pendingCount()
    XCTAssertEqual(pending, 1)
    let reopened = VocabularyStore(directory: path)
    let second = coordinator(reopened, cloud)
    _ = try await second.sync()
    let recoveredPending = await reopened.pendingCount()
    let entries = await reopened.all()
    XCTAssertEqual(recoveredPending, 0)
    XCTAssertEqual(entries.map(\.word), ["alpha"])
  }

  func testAccountSwitchRejectsOldCloudCompletion() async throws {
    let store = VocabularyStore(directory: try directory())
    let cloud = CoordinatorCloudFixture()
    let coordinator = coordinator(store, cloud)
    try await coordinator.prepareAccount()
    try await add("private-a-fixture", to: store)
    let pending = Task { try await coordinator.sync() }
    try await Task.sleep(nanoseconds: 5_000_000)
    await cloud.setUser("account-b")
    try await coordinator.accountChanged()
    do { _ = try await pending.value; XCTFail("Old account completion must fail") } catch {}
    let status = await store.status()
    let entries = await store.all()
    XCTAssertEqual(status.userID, "account-b")
    XCTAssertTrue(entries.isEmpty)
    await coordinator.stop()
  }

  func testSaveDuringUploadRemainsPendingAndIsDrained() async throws {
    let store = VocabularyStore(directory: try directory())
    let cloud = CoordinatorCloudFixture()
    let coordinator = coordinator(store, cloud)
    try await coordinator.prepareAccount()
    try await add("alpha", to: store)
    let task = Task { try await coordinator.sync() }
    try await Task.sleep(nanoseconds: 5_000_000)
    try await add("beta", to: store)
    _ = try await task.value
    let pending = await store.pendingCount()
    let words = await cloud.vocabulary.map(\.word)
    XCTAssertEqual(pending, 0)
    XCTAssertEqual(Set(words), Set(["alpha", "beta"]))
  }

  func testBackgroundQueueRetriesTransientHTTPButStopsPermanentFailure() async throws {
    for status in [403, 503] {
      let store = VocabularyStore(directory: try directory())
      let cloud = CoordinatorCloudFixture()
      let coordinator = coordinator(store, cloud)
      try await coordinator.prepareAccount()
      try await add("alpha", to: store)
      await cloud.failHTTP(status)
      await coordinator.queue()
      for _ in 0..<300 {
        if await cloud.requests >= (status == 403 ? 1 : 2) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try await Task.sleep(nanoseconds: 100_000_000)
      let requests = await cloud.requests
      let pending = await store.pendingCount()
      XCTAssertEqual(requests, status == 403 ? 1 : 2)
      XCTAssertEqual(pending, status == 403 ? 1 : 0)
      await coordinator.stop()
    }
  }
}
