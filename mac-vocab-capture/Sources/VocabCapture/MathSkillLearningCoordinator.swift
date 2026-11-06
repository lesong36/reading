import Foundation

struct MathSkillLearningResult: Sendable {
  let patternKey: String?
  let proposal: MathSkillProposal?
  let evidenceIDs: Set<String>
  let report: String

  static func parse(_ text: String, questionIDs: Set<String>) throws -> Self {
    guard text.utf8.count <= 512_000,
      let data = text.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["version"] as? Int == 1,
      let coverage = object["coverage"] as? String,
      ["covered", "uncovered", "uncertain", "non_math"].contains(coverage),
      let reason = object["reason"] as? String, !reason.isEmpty,
      let status = object["status"] as? String,
      ["observing", "covered", "awaiting_human", "approved", "rejected", "revision_required"].contains(status)
    else { throw ScreenshotQuestionError.invalidResponse }
    // Only uncovered, well-grounded patterns may enter the candidate inventory.
    let key = (object["pattern_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = coverage == "uncovered" && key?.isEmpty == false ? key : nil
    guard let matched = object["pattern_evidence_ids"] as? [String],
      Set(matched).isSubset(of: questionIDs), matched.count <= 24
    else { throw ScreenshotQuestionError.invalidResponse }
    var proposal: MathSkillProposal?
    if let draft = object["proposal"] as? [String: Any] {
      guard let pattern, let title = draft["title"] as? String, !title.isEmpty,
        let body = draft["instructions"] as? String, !body.isEmpty,
        let trigger = draft["trigger"] as? String, !trigger.isEmpty,
        let prerequisites = draft["prerequisites"] as? [String],
        let exclusions = draft["exclusions"] as? [String], !exclusions.isEmpty,
        let diagrams = draft["diagram_templates"] as? [String],
        let evidence = draft["evidence_ids"] as? [String],
        Set(evidence).count >= 3, Set(evidence).isSubset(of: questionIDs),
        body.utf8.count <= 48_000, title.count <= 256,
        diagrams.allSatisfy({ MathDiagram.Kind(rawValue: $0) != nil })
      else { throw ScreenshotQuestionError.invalidResponse }
      proposal = MathSkillProposal(
        signature: pattern, title: title, category: draft["category"] as? String ?? "待验证方法",
        instructions: body, trigger: trigger, constraints: draft["review_notes"] as? String ?? "",
        exclusions: exclusions.joined(separator: "\n"), prerequisites: prerequisites.joined(separator: "\n"),
        supportedDiagrams: diagrams)
    }
    return Self(patternKey: pattern, proposal: proposal, evidenceIDs: Set(matched), report: text)
  }
}

/// Durable per-question jobs are independent of screenshot saving and user approvals.
@MainActor
final class MathSkillLearningCoordinator {
  typealias Analyze = @Sendable (Data, Data, [MathTeachingMethod], MathTagModelConfiguration) async throws -> String
  private let store: MathQuestionStore
  private let configuration: () -> MathTagModelConfiguration
  private let analyze: Analyze
  private let onChange: () -> Void
  private var runner: Task<Void, Never>?
  private var generation = UUID()
  private var suspended = false
  private var recovered = false
  private(set) var enabled: Bool

  init(store: MathQuestionStore, enabled: Bool,
    configuration: @escaping () -> MathTagModelConfiguration,
    analyze: @escaping Analyze, onChange: @escaping () -> Void = {}) {
    self.store = store
    self.enabled = enabled
    self.configuration = configuration
    self.analyze = analyze
    self.onChange = onChange
  }

  func start() async {
    guard !suspended else { return }
    if !recovered { try? await store.recoverSkillLearning(); recovered = true }
    guard enabled, runner == nil else { return }
    let revision = generation
    runner = Task { [weak self] in
      guard let self else { return }
      await self.drain(revision)
      guard self.generation == revision else { return }
      self.runner = nil
      if self.enabled, !self.suspended, self.generation == revision,
        let pending = try? await self.store.pendingSkillLearningJobs(), !pending.isEmpty {
        await self.start()
      }
    }
  }

  func enqueue(_ questionID: String) async {
    guard !suspended else { return }
    do { try await store.enqueueSkillLearning(questionID: questionID); await start() }
    catch { onChange() }
  }

  func backfill() async {
    guard !suspended else { return }
    if let records = try? await store.list() {
      for record in records { try? await store.enqueueSkillLearning(questionID: record.id) }
    }
    await start()
  }

  func setEnabled(_ value: Bool) async {
    enabled = value
    if value { await start() } else {
      generation = UUID()
      let previous = runner
      previous?.cancel()
      await previous?.value
      runner = nil
      if enabled { await start() }
    }
    onChange()
  }

  func suspendForLibraryRestore() async {
    suspended = true
    generation = UUID()
    let task = runner
    task?.cancel()
    await task?.value
    runner = nil
    recovered = false
  }

  func resumeAfterLibraryRestore(enabled: Bool) async {
    suspended = false
    await setEnabled(enabled)
  }

  func stop() { enabled = false; runner?.cancel() }

  func reviewCandidate(id: String, approve: Bool, note: String) async throws {
    guard !suspended else { throw CancellationError() }
    let revision = generation
    let attempt = try await store.candidateResearchAttempt(id: id)
    let model = configuration()
    guard model.configuration.isComplete else { throw ScreenshotQuestionError.invalidConfiguration }
    let image = try await store.originalImage(questionID: attempt.evidence[0].questionID)
    let methods = try await store.automaticMethods()
    let learning: [String: Any]
    if approve {
      guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let text = try await store.candidateResearchReport(attempt: attempt),
        let report = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        report["status"] as? String == "awaiting_human", let checkpoint = report["workflow_state"]
      else { throw MathQuestionStoreError.database("请先完成当前版本的教研审校，并填写批准说明") }
      learning = ["workflow_state": checkpoint, "decision": ["action": "approve", "reviewer": "用户", "note": note]]
    } else {
      var source = attempt.learningObject
      source["originals"] = try await originals(attempt.evidence.map(\.snapshot))
      learning = source
    }
    let data = try JSONSerialization.data(withJSONObject: learning, options: .sortedKeys)
    let output = try await analyze(data, image, methods, model)
    try Task.checkCancellation()
    guard !suspended, generation == revision else { throw CancellationError() }
    try await store.recordCandidateResearch(attempt: attempt, report: output, model: model.configuration.model)
    if approve { _ = try await store.publishSkillCandidate(id: id) }
    onChange()
  }

  private func originals(_ snapshots: [MathSkillLearningSnapshot]) async throws -> [[String: String]] {
    var photos: [[String: String]] = []
    var size = 0
    for snapshot in snapshots {
      let bytes = try await store.originalImage(questionID: snapshot.questionID)
      size += bytes.count
      guard size <= 20 * 1024 * 1024 else {
        throw MathQuestionStoreError.database("本次教研原图合计超过 20 MB，请减少例题数量后重试")
      }
      photos.append(["question_id": snapshot.questionID, "image_data": bytes.base64EncodedString()])
    }
    return photos
  }

  private func input(_ snapshots: [MathSkillLearningSnapshot], patterns: [[String: Any]]) async throws -> Data {
    let evidence = snapshots.map { snapshot -> [String: Any] in
      let solution = snapshot.solutions.first(where: { $0.verificationStatus == "confirmed" }) ?? snapshot.solutions.last
      let review = solution.flatMap { snapshot.confirmedProcessReview(for: $0) }
      let answer = solution.map { snapshot.learningAnswer(for: $0, review: review) } ?? ""
      var value: [String: Any] = ["question_id": snapshot.questionID,
        "text": String(snapshot.ocrText.prefix(2_000)),
        "answer": String(answer.prefix(2_000)),
        "verification": review == nil ? "unverified" : "confirmed",
        "grade": snapshot.grade as Any? ?? NSNull(),
        "user_constraint": String((solution?.question ?? "").prefix(500))]
      if let reference = snapshot.references.last { value["reference_answer"] = String(reference.text.prefix(500)) }
      return value
    }
    let photos = try await originals(snapshots)
    return try JSONSerialization.data(withJSONObject: ["evidence": evidence, "existing_patterns": patterns, "originals": photos], options: [.sortedKeys])
  }

  /// Retrieve current originals for a previously observed structure, regardless of
  /// capture date. The model must compare them again; old observations are not approvals.
  private func historicalSources(for result: MathSkillLearningResult, current: MathSkillLearningSnapshot,
    candidates: [MathSkillCandidate]) async throws -> [MathSkillLearningSnapshot]? {
    guard let key = result.patternKey, result.evidenceIDs.contains(current.questionID),
      let candidate = candidates.first(where: { $0.proposal.signature == key }),
      !["published", "rejected"].contains(candidate.status) else { return nil }
    let linked = try await store.candidateEvidence(id: candidate.id)
    var sources = [current], assets = Set([current.assetID]), questions = Set([current.questionID])
    for entry in linked.reversed() where entry.candidateRevision == candidate.revision {
      guard sources.count < 8 else { break }
      guard questions.insert(entry.questionID).inserted,
        let snapshot = try? await store.learningSnapshot(questionID: entry.questionID),
        assets.insert(snapshot.assetID).inserted else { continue }
      sources.append(snapshot)
    }
    return sources.count > 1 ? sources : nil
  }

  private func drain(_ revision: UUID) async {
    while enabled, !suspended, !Task.isCancelled, generation == revision {
      guard let jobs = try? await store.pendingSkillLearningJobs(), let job = jobs.first,
        let attempt = try? await store.claimSkillLearning(questionID: job.questionID) else { return }
      do {
        let model = configuration()
        guard model.configuration.isComplete else { throw ScreenshotQuestionError.invalidConfiguration }
        let image = try await store.originalImage(questionID: job.questionID)
        let methods = try await store.automaticMethods()
        // Current question first; a bounded history supports comparison without an unbounded prompt.
        let records = try await store.list()
        var snapshots = [attempt.snapshot]
        var assets = Set([attempt.snapshot.assetID])
        for record in records where record.id != job.questionID {
          guard snapshots.count < 8 else { break }
          if let snapshot = try? await store.learningSnapshot(questionID: record.id),
            assets.insert(snapshot.assetID).inserted { snapshots.append(snapshot) }
        }
        let candidates = try await store.listSkillCandidates()
        var patterns: [[String: Any]] = []
        for candidate in candidates.prefix(40) {
          let linked = try await store.candidateEvidence(id: candidate.id)
          patterns.append(["signature": candidate.proposal.signature,
            "evidence_ids": Array(Set(linked.map(\.questionID))), "status": candidate.status])
        }
        var output = try await analyze(try await input(snapshots, patterns: patterns), image, methods, model)
        try Task.checkCancellation()
        guard generation == revision, !suspended else { throw CancellationError() }
        var result = try MathSkillLearningResult.parse(output, questionIDs: Set(snapshots.map(\.questionID)))
        if let history = try await historicalSources(for: result, current: attempt.snapshot, candidates: candidates),
          !Set(history.map(\.questionID)).isSubset(of: Set(snapshots.map(\.questionID))) {
          // At most two graph runs per job (four model calls each), with at most
          // eight original photos per run. Never scan history in an unbounded loop.
          snapshots = history
          output = try await analyze(try await input(snapshots, patterns: patterns), image, methods, model)
          try Task.checkCancellation()
          guard generation == revision, !suspended else { throw CancellationError() }
          result = try MathSkillLearningResult.parse(output, questionIDs: Set(snapshots.map(\.questionID)))
        }
        try await store.finishSkillLearning(attempt: attempt, proposal: result.proposal,
          report: result.report, model: model.configuration.model, patternKey: result.patternKey,
          evidenceSnapshots: snapshots)
      } catch {
        if Task.isCancelled || error is CancellationError {
          try? await store.releaseSkillLearning(attempt: attempt)
        } else {
          try? await store.failSkillLearning(attempt: attempt, error: error.localizedDescription)
        }
      }
      onChange()
    }
  }
}
