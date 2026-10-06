import Foundation
import Network

struct VocabularySyncSummary: Sendable {
  let uploadedCount: Int
  let totalCount: Int
}

struct VocabularySyncStatus: Sendable {
  let userID: String?
  let pendingCount: Int
  let message: String
  var conflictingWordKeys: [String] = []
}

/// One queue serves ordinary capture, OCR, manual sync, startup and network recovery.
actor VocabularySyncCoordinator {
  private let store: VocabularyStore
  private let currentUserID: @Sendable () async -> String?
  private let synchronize: @Sendable (VocabularySyncBatch) async throws -> VocabularySyncResult
  private let onStatus: @MainActor @Sendable (VocabularySyncStatus) -> Void
  private let debounce: TimeInterval
  private var flight: (id: UUID, task: Task<VocabularySyncSummary, Error>)?
  private var scheduled: Task<Void, Never>?
  private var firstQueuedAt: TimeInterval?
  private var retryAttempt = 0
  private var conflictWordKeys: [String] = []
  private var monitor: NWPathMonitor?
  private var generation: UInt64 = 0
  private var preparedUserID: String?
  private var prepared = false

  init(store: VocabularyStore,
    currentUserID: @escaping @Sendable () async -> String?,
    synchronize: @escaping @Sendable (VocabularySyncBatch) async throws -> VocabularySyncResult,
    debounce: TimeInterval = 0.5,
    onStatus: @escaping @MainActor @Sendable (VocabularySyncStatus) -> Void = { _ in }) {
    self.store = store
    self.currentUserID = currentUserID
    self.synchronize = synchronize
    self.debounce = debounce
    self.onStatus = onStatus
  }

  func start() async {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { await self?.networkRecovered() }
    }
    monitor.start(queue: DispatchQueue(label: "VocabCapture.network-recovery"))
    do { try await prepareAccount() }
    catch { await report(error) }
    await queue()
  }

  func stop() {
    generation &+= 1
    monitor?.cancel(); monitor = nil
    scheduled?.cancel(); scheduled = nil
    flight?.task.cancel(); flight = nil
  }

  /// Call before a local save as well as before sending a batch. Never reload the
  /// same account during a request: its store generation guards acknowledgement.
  func prepareAccount() async throws {
    let userID = await currentUserID()
    if !prepared || userID != preparedUserID {
      generation &+= 1
      flight?.task.cancel(); flight = nil
      scheduled?.cancel(); scheduled = nil
      firstQueuedAt = nil
      retryAttempt = 0
      preparedUserID = userID
      prepared = true
      do { try await store.activateAccount(userID: userID) }
      catch { prepared = false; throw error }
    }
    guard await currentUserID() == userID else { throw SupabaseSyncError.accountChanged }
  }

  func accountChanged() async throws {
    // Even A -> B -> A must invalidate the request and the persistence generation.
    generation &+= 1
    flight?.task.cancel(); flight = nil
    scheduled?.cancel(); scheduled = nil
    prepared = false
    try await prepareAccount()
    await publishStatus(message: "账号已切换，本机词库按账号隔离")
    await queue()
  }

  func sync() async throws -> VocabularySyncSummary {
    try await prepareAccount()
    guard await currentUserID() != nil else { throw SupabaseSyncError.notLoggedIn }
    if let flight {
      let expectedGeneration = generation
      let result = try await flight.task.value
      guard generation == expectedGeneration else { throw SupabaseSyncError.accountChanged }
      return result
    }
    let id = UUID()
    let currentGeneration = generation
    let task = Task { try await self.drain(generation: currentGeneration) }
    flight = (id, task)
    do {
      let result = try await task.value
      guard generation == currentGeneration, flight?.id == id else { throw SupabaseSyncError.accountChanged }
      if flight?.id == id { flight = nil }
      retryAttempt = 0
      conflictWordKeys = []
      await publishStatus(message: "已确认同步")
      return result
    } catch {
      guard generation == currentGeneration, flight?.id == id else { throw SupabaseSyncError.accountChanged }
      flight = nil
      await report(error)
      throw error
    }
  }

  func resolveConflicts(wordKeys: [String], strategy: VocabularyConflictStrategy) async throws {
    try await prepareAccount()
    guard let batch = await store.syncBatch(), !wordKeys.isEmpty else { throw SupabaseSyncError.invalidResponse }
    let expectedGeneration = generation
    let readOnly = VocabularySyncBatch(userID: batch.userID, baseRevision: batch.baseRevision,
      operations: [], accountGeneration: batch.accountGeneration)
    let current = try await synchronize(readOnly)
    guard generation == expectedGeneration, await currentUserID() == batch.userID,
      current.userID == batch.userID else { throw SupabaseSyncError.accountChanged }
    try await store.resolveConflicts(wordKeys: wordKeys, cloudVocabulary: current.vocabulary,
      cloudRevision: current.revision, tombstones: current.tombstones,
      strategy: strategy, basedOn: batch)
    conflictWordKeys = []
    await queue()
  }

  func queue() async {
    let status = await store.status()
    await publishStatus(message: status.pendingCount > 0 ? "本机已保存，等待同步" : "本机词库已保留")
    guard status.canSync else { return }
    if firstQueuedAt == nil { firstQueuedAt = ProcessInfo.processInfo.systemUptime }
    let wait = min(debounce, max(0, 2 - (ProcessInfo.processInfo.systemUptime - (firstQueuedAt ?? 0))))
    scheduled?.cancel()
    scheduled = Task {
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
        try Task.checkCancellation()
        await self.runScheduled()
      } catch {}
    }
  }

  private func networkRecovered() async {
    retryAttempt = 0
    await queue()
  }

  private func runScheduled() async {
    firstQueuedAt = nil
    scheduled = nil
    do { _ = try await sync() }
    catch {
      guard isRetryable(error), await store.pendingCount() > 0, retryAttempt < 8 else { return }
      let delays: [TimeInterval] = [1, 2, 5, 10, 20, 30, 60, 60]
      let delay = delays[retryAttempt]
      retryAttempt += 1
      scheduled = Task {
        do {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          try Task.checkCancellation()
          await self.runScheduled()
        } catch {}
      }
    }
  }

  private func drain(generation expectedGeneration: UInt64) async throws -> VocabularySyncSummary {
    var uploaded = 0
    var count = 0
    for _ in 0..<8 {
      try Task.checkCancellation()
      guard generation == expectedGeneration, let batch = await store.syncBatch(),
        await currentUserID() == batch.userID
      else { throw SupabaseSyncError.accountChanged }
      let result = try await synchronize(batch)
      try Task.checkCancellation()
      guard generation == expectedGeneration, await currentUserID() == batch.userID,
        result.userID == batch.userID
      else { throw SupabaseSyncError.accountChanged }
      try await store.acknowledgeSync(vocabulary: result.vocabulary, revision: result.revision,
        acknowledgedOperationIDs: result.acknowledgedOperationIDs, basedOn: batch,
        tombstones: result.tombstones)
      uploaded += result.uploadedCount
      count = result.vocabulary.count
      if await store.pendingCount() == 0 { return VocabularySyncSummary(uploadedCount: uploaded, totalCount: count) }
      guard !batch.operations.isEmpty, !result.acknowledgedOperationIDs.isEmpty else {
        throw SupabaseSyncError.invalidResponse
      }
    }
    // A busy collector cannot hold one network loop forever. The durable queue
    // remains pending and the next batch is scheduled normally.
    await queue()
    return VocabularySyncSummary(uploadedCount: uploaded, totalCount: count)
  }

  private func report(_ error: Error) async {
    if case SupabaseSyncError.conflict(let keys) = error { conflictWordKeys = keys }
    await publishStatus(message: error.localizedDescription)
  }

  private func publishStatus(message: String) async {
    let status = await store.status()
    await onStatus(VocabularySyncStatus(userID: status.userID, pendingCount: status.pendingCount,
      message: status.issue ?? message, conflictingWordKeys: conflictWordKeys))
  }

  private func isRetryable(_ error: Error) -> Bool {
    if let error = error as? URLError { return error.code != .cancelled && error.code != .userAuthenticationRequired }
    if case SupabaseSyncError.http(let status) = error { return status == 429 || (500...599).contains(status) }
    return false
  }
}
