import Foundation

struct MathTagModelConfiguration: Sendable {
  let configuration: AIConfiguration
  let api: ScreenshotQuestionAPI
  let directConnection: Bool
}

@MainActor
final class MathAutomaticTagCoordinator {
  typealias Classify =
    @Sendable (Data, String, Int?, MathTagModelConfiguration) async throws -> MathAutomaticTagResult
  private let store: MathQuestionStore
  private let configuration: () -> MathTagModelConfiguration
  private let classify: Classify
  private let onChange: () -> Void
  private var runner: Task<Void, Never>?
  private var recovered = false
  private var suspended = false
  private var operationRevision = UUID()
  private(set) var enabled: Bool

  init(
    store: MathQuestionStore, enabled: Bool,
    configuration: @escaping () -> MathTagModelConfiguration,
    classify: @escaping Classify, onChange: @escaping () -> Void = {}
  ) {
    self.store = store
    self.enabled = enabled
    self.configuration = configuration
    self.classify = classify
    self.onChange = onChange
  }

  func start() async {
    guard !suspended else { return }
    let revision = operationRevision
    if !recovered {
      recovered = true
      do { try await store.recoverAutomaticTagJobs() } catch { return }
    }
    guard revision == operationRevision, !suspended else { return }
    runIfNeeded()
  }

  func setEnabled(_ value: Bool) async {
    enabled = value
    if value { await start() } else { runner?.cancel() }
    onChange()
  }

  func enqueue(_ id: String, force: Bool = false) async {
    guard !suspended else { return }
    let revision = operationRevision
    // Even when disabled, keep a durable pending job for later enablement.
    do {
      _ = try await store.enqueueAutomaticTags(questionID: id, force: force)
      guard revision == operationRevision, !suspended else { return }
      await start()
      onChange()
    } catch { onChange() }
  }

  func backfill() async {
    guard !suspended else { return }
    let revision = operationRevision
    do {
      for record in try await store.list() where record.automaticTagStatus == "unclassified" {
        guard revision == operationRevision, !suspended else { return }
        // Existing manually classified questions already have an owner.
        let tags = try await store.tags(questionID: record.id)
        guard revision == operationRevision, !suspended else { return }
        if !tags.contains(where: { $0.axis != "custom" }) {
          _ = try await store.enqueueAutomaticTags(questionID: record.id)
        }
      }
      guard revision == operationRevision, !suspended else { return }
      await start()
      onChange()
    } catch { onChange() }
  }

  func stop() {
    enabled = false
    runner?.cancel()
  }

  func suspendForLibraryRestore() async {
    suspended = true
    operationRevision = UUID()
    enabled = false
    let pending = runner
    pending?.cancel()
    await pending?.value
    recovered = false
  }

  func resumeAfterLibraryRestore(enabled value: Bool) async {
    suspended = false
    await setEnabled(value)
  }

  private func runIfNeeded() {
    guard enabled, !suspended, runner == nil else { return }
    runner = Task { [weak self] in
      guard let self else { return }
      await self.drain()
      self.runner = nil
      // An enqueue can arrive while the last empty-queue read is suspended.
      if self.enabled, let pending = try? await self.store.pendingAutomaticTagQuestionIDs(),
        !pending.isEmpty
      {
        self.runIfNeeded()
      }
    }
  }

  private func drain() async {
    while enabled && !Task.isCancelled {
      guard let ids = try? await store.pendingAutomaticTagQuestionIDs(), let id = ids.first,
        let attempt = try? await store.claimAutomaticTags(questionID: id)
      else { return }
      onChange()
      do {
        try Task.checkCancellation()
        let model = configuration()
        guard model.configuration.isComplete else {
          throw ScreenshotQuestionError.invalidConfiguration
        }
        guard let record = try await store.list().first(where: { $0.id == id }) else {
          throw CancellationError()
        }
        let image = try await store.originalImage(questionID: id)
        let result = try await classify(image, record.ocrText, record.grade, model)
        try Task.checkCancellation()
        let versions = Set(result.tags.map(\.catalogueVersion)).sorted().joined(separator: ",")
        _ = try await store.completeAutomaticTags(
          attempt: attempt, tags: result.tags,
          model: model.configuration.model, promptVersion: MathQuestionAutoTagger.promptVersion,
          catalogueVersion: versions, evidence: result.evidence)
      } catch is CancellationError {
        try? await store.cancelAutomaticTags(attempt: attempt)
      } catch {
        if Task.isCancelled {
          try? await store.cancelAutomaticTags(attempt: attempt)
          onChange()
          return
        }
        let message: String
        if case ScreenshotQuestionError.invalidConfiguration = error {
          message = "请在截图问答模型设置中填写服务地址、模型和 Key，再重试。"
        } else {
          message = "自动分类未完成，请重试或手动修改标签。原图已保存。"
        }
        try? await store.markAutomaticTagFailure(attempt: attempt, message: message)
      }
      onChange()
    }
  }
}
