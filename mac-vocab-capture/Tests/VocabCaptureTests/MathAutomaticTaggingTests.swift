import AppKit
import CSQLite
import XCTest

@testable import VocabCapture

@MainActor
final class MathAutomaticTaggingTests: XCTestCase {
  private func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line
  ) { XCTAssertEqual(lhs, rhs, file: file, line: line) }
  private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, file: file, line: line)
  }
  private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, file: file, line: line)
  }
  private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, file: file, line: line)
  }
  private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws
    -> T
  { try XCTUnwrap(value, file: file, line: line) }
  private func fixture() throws -> Data {
    let context = try unwrap(
      CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    return try unwrap(MathQuestionIndexer.originalPNG(try unwrap(context.makeImage())))
  }
  private func store() -> MathQuestionStore {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "auto-tag-tests-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: path) }
    return MathQuestionStore(directory: path)
  }
  private func result() throws -> MathAutomaticTagResult {
    try MathQuestionAutoTagger.parse(
      """
      {"tags":[{"axis":"question_form","id":"qf.fill_blank","evidence":"题面包含填写空格"},{"axis":"curriculum_knowledge","id":"kp.operation.multiply","evidence":"题面有整数乘法"}],"missing":["problem_family"]}
      """, catalogue: MathTagCatalogue.load())
  }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Automatic classification did not settle")
  }
  private func coordinator(
    _ store: MathQuestionStore, enabled: Bool = true,
    classify: @escaping MathAutomaticTagCoordinator.Classify
  ) -> MathAutomaticTagCoordinator {
    .init(
      store: store, enabled: enabled,
      configuration: {
        .init(
          configuration: .init(baseURL: "https://example.com", model: "fixture", apiKey: ""),
          api: .chatCompletions, directConnection: false)
      }, classify: classify)
  }

  func testParserResolvesVersionsLabelsAndPreservesEvidence() throws {
    let output = try result()
    expectEqual(output.tags.count, 2)
    expectTrue(output.tags.allSatisfy { $0.origin == "ai" && $0.status == "suggested" })
    expectTrue(output.tags.contains { $0.label == "整数乘法" })
    expectTrue(output.evidence.contains("题面包含填写空格"))
  }

  func testParserRejectsUnknownWrongAxisDuplicateMissingEvidenceAndTruncation() throws {
    let catalogue = try MathTagCatalogue.load()
    let valid = try result().evidence
    let bad = [
      "", "```json\n" + valid + "\n```", String(valid.dropLast()),
      valid.replacingOccurrences(of: "qf.fill_blank", with: "invented"),
      valid.replacingOccurrences(of: "question_form", with: "error_cause"),
      valid.replacingOccurrences(of: "题面包含填写空格", with: ""),
      "{\"tags\":[],\"missing\":[\"question_form\",\"curriculum_knowledge\",\"problem_family\"]}",
      "{\"tags\":[{\"axis\":\"question_form\",\"id\":\"qf.fill_blank\",\"evidence\":\"空格\"},{\"axis\":\"question_form\",\"id\":\"qf.fill_blank\",\"evidence\":\"重复\"}],\"missing\":[\"curriculum_knowledge\",\"problem_family\"]}",
    ]
    for output in bad {
      XCTAssertThrowsError(try MathQuestionAutoTagger.parse(output, catalogue: catalogue))
    }
  }

  func testTransportUsesDedicatedInstructionsImageAndNoAnswerHistory() throws {
    let bytes = try fixture()
    let config = AIConfiguration(baseURL: "https://example.com", model: "fixture", apiKey: "fake")
    let payload = try ScreenshotQuestionClient.payload(
      question: "按目录分类", context: .init(text: "", selectedWord: nil, imageData: bytes), history: [],
      configuration: config, api: .chatCompletions,
      instructions: MathQuestionAutoTagger.instructions)
    let object = try unwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    expectEqual(object["instructions"] as? String, MathQuestionAutoTagger.instructions)
    expectTrue(try unwrap(object["history"] as? [[String: Any]]).isEmpty)
    expectEqual(
      (object["context"] as? [String: Any])?["image_data"] as? String, bytes.base64EncodedString())
    let normal = try ScreenshotQuestionClient.payload(
      question: "解题", context: .init(text: "内容", selectedWord: nil, imageData: nil), history: [],
      configuration: config, api: .chatCompletions)
    expectEqual(
      (try JSONSerialization.jsonObject(with: normal) as? [String: Any])?["instructions"]
        as? String, ScreenshotQuestionInstructions.text)
  }

  func testAutomaticTagsImmediatelyFilterAndRepeatedSaveDoesNotRunAgain() async throws {
    let db = store()
    let bytes = try fixture()
    let output = try result()
    let calls = Counter()
    let runner = coordinator(db) { image, text, grade, _ in
      XCTAssertEqual(image, bytes)
      XCTAssertEqual(text, "")
      XCTAssertNil(grade)
      await calls.add()
      return output
    }
    defer { runner.stop() }
    let question = try await db.save(.init(captureID: "one", imageData: bytes))
    await runner.enqueue(question.id)
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "ready" }
    let filtered = try await db.list(tags: output.tags)
    expectEqual(filtered.map(\.id), [question.id])
    expectEqual(Set(try await db.tagOptions().map(\.key)), Set(output.tags.map(\.key)))
    _ = try await db.save(
      .init(
        captureID: "one", imageData: bytes,
        solutions: [.init(question: "解题", answer: "完整回答", model: "test")]))
    await runner.enqueue(question.id)
    let count = await calls.value
    expectEqual(count, 1)
    expectEqual(try await db.originalImage(questionID: question.id), bytes)
    let answers = try await db.solutions(questionID: question.id)
    expectEqual(answers.first?.answer, "完整回答")
    expectEqual(answers.first?.verificationStatus, "unverified")
  }

  func testRestoreSuspensionWaitsForCanceledClassificationAndBlocksNewJobs() async throws {
    let db = store()
    let bytes = try fixture()
    let question = try await db.save(.init(captureID: "restore-running", imageData: bytes))
    let other = try await db.save(.init(captureID: "restore-other", imageData: bytes))
    let output = try result()
    let runner = coordinator(db) { _, _, _, _ in
      try await Task.sleep(nanoseconds: 10_000_000_000)
      return output
    }
    await runner.enqueue(question.id)
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "running" }
    await runner.suspendForLibraryRestore()
    let job = try await db.automaticTagJob(questionID: question.id)
    XCTAssertNotEqual(job?.status, "running")
    await runner.enqueue(other.id)
    let otherJob = try await db.automaticTagJob(questionID: other.id)
    XCTAssertNil(otherJob)
    await runner.resumeAfterLibraryRestore(enabled: false)
    await runner.enqueue(other.id)
    let resumedJob = try await db.automaticTagJob(questionID: other.id)
    XCTAssertEqual(resumedJob?.status, "pending")
    runner.stop()
    await db.close()
  }

  func testFailedClassificationKeepsPhotoAndDoesNotAutoRetryOnAppend() async throws {
    let db = store()
    let bytes = try fixture()
    let calls = Counter()
    let runner = coordinator(db) { _, _, _, _ in
      await calls.add()
      throw MathAutomaticTagError.invalidOutput
    }
    defer { runner.stop() }
    let question = try await db.save(.init(captureID: "failed", imageData: bytes))
    await runner.enqueue(question.id)
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "failed" }
    await runner.enqueue(question.id)
    let count = await calls.value
    expectEqual(count, 1)
    expectEqual(try await db.originalImage(questionID: question.id), bytes)
    await runner.enqueue(question.id, force: true)
    try await settle { await calls.value == 2 }
  }

  func testPendingTasksResumeAfterReopenAndRejectStaleAttempt() async throws {
    let db = store()
    let output = try result()
    let question = try await db.save(.init(captureID: "restart", imageData: fixture()))
    _ = try await db.enqueueAutomaticTags(questionID: question.id)
    let stale = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    await db.close()
    let reopened = MathQuestionStore(directory: db.directory)
    try await reopened.recoverAutomaticTagJobs()
    let current = try unwrap(try await reopened.claimAutomaticTags(questionID: question.id))
    XCTAssertNotEqual(stale.token, current.token)
    let ignored = try await reopened.completeAutomaticTags(
      attempt: stale, tags: output.tags, model: "old", promptVersion: "old",
      catalogueVersion: "old", evidence: "old")
    expectFalse(ignored)
    _ = try await reopened.completeAutomaticTags(
      attempt: current, tags: output.tags, model: "new", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    expectEqual(try await reopened.automaticTagJob(questionID: question.id)?.model, "new")
  }

  func testManualEditDuringRequestAndRejectionSurviveReclassification() async throws {
    let db = store()
    let output = try result()
    let question = try await db.save(.init(captureID: "manual", imageData: fixture()))
    _ = try await db.enqueueAutomaticTags(questionID: question.id)
    let attempt = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    let manual = MathQuestionTag(
      axis: "custom", tagID: "user.test", catalogueVersion: "user@1", label: "复习")
    try await db.updateClassification(questionID: question.id, grade: 4, tags: [manual])
    _ = try await db.completeAutomaticTags(
      attempt: attempt, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    expectEqual(try await db.tags(questionID: question.id), [manual])
    _ = try await db.enqueueAutomaticTags(questionID: question.id, force: true)
    let next = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    _ = try await db.completeAutomaticTags(
      attempt: next, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    try await db.updateClassification(questionID: question.id, grade: 4, tags: [manual])
    expectTrue(
      try await db.tags(questionID: question.id).filter { $0.origin == "ai" }.allSatisfy {
        $0.status == "rejected"
      })
    _ = try await db.enqueueAutomaticTags(questionID: question.id, force: true)
    let last = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    _ = try await db.completeAutomaticTags(
      attempt: last, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    expectTrue(try await db.list(tags: output.tags).isEmpty)
    expectEqual(try await db.list().first?.grade, 4)
  }

  func testDeletePreventsLateResultAndBackupKeepsJobMetadata() async throws {
    let db = store()
    let output = try result()
    let bytes = try fixture()
    let question = try await db.save(.init(captureID: "delete", imageData: bytes))
    _ = try await db.enqueueAutomaticTags(questionID: question.id)
    let attempt = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    try await db.delete(questionID: question.id)
    let applied = try await db.completeAutomaticTags(
      attempt: attempt, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    expectFalse(applied)
    try await db.restore(questionID: question.id)
    let current = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    _ = try await db.completeAutomaticTags(
      attempt: current, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    let destination = db.directory.appendingPathComponent("backup")
    try await db.backup(to: destination)
    let backup = MathQuestionStore(directory: destination)
    expectEqual(
      try await backup.automaticTagJob(questionID: question.id)?.evidence, output.evidence)
    expectEqual(try await backup.originalImage(questionID: question.id), bytes)
  }

  func testDisabledQueueAndBackfillRespectManuallyClassifiedQuestions() async throws {
    let db = store()
    let output = try result()
    let one = try await db.save(.init(captureID: "pending", imageData: fixture()))
    let two = try await db.save(.init(captureID: "manual", imageData: fixture()))
    try await db.updateClassification(
      questionID: two.id, grade: 4,
      tags: [
        .init(axis: "question_form", tagID: "qf.fill_blank", catalogueVersion: "1", label: "用户")
      ])
    let calls = Counter()
    let runner = coordinator(db, enabled: false) { _, _, _, _ in
      await calls.add()
      return output
    }
    defer { runner.stop() }
    await runner.backfill()
    expectEqual(try await db.automaticTagJob(questionID: one.id)?.status, "pending")
    expectNil(try await db.automaticTagJob(questionID: two.id))
    expectEqual(await calls.value, 0)
    await runner.setEnabled(true)
    try await settle { try await db.automaticTagJob(questionID: one.id)?.status == "ready" }
    expectEqual(await calls.value, 1)
  }

  func testAppSaveTriggersClassificationWithoutSolving() async throws {
    let db = store()
    let output = try result()
    let bytes = try fixture()
    let suite = "MathAutoApp." + UUID().uuidString
    let defaults = try unwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      try JSONEncoder().encode(
        AIConfiguration(baseURL: "https://example.com", model: "test", apiKey: "")),
      forKey: "VocabCapture.aiConfiguration")
    let app = makeIsolatedAppDelegate(
      defaults: defaults, mathQuestionStore: db,
      mathClassifier: { image, _, _, _ in
        XCTAssertEqual(image, bytes)
        return output
      })
    let question = try await app.saveMathQuestion(.init(captureID: "app", imageData: bytes))
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "ready" }
    expectTrue(try await db.solutions(questionID: question.id).isEmpty)
    expectEqual(try await db.tags(questionID: question.id).count, 2)
  }

  func testDisablingCancelsOnlyClassificationAndReenableResumesPending() async throws {
    let db = store()
    let output = try result()
    let calls = Counter()
    let question = try await db.save(.init(captureID: "cancel", imageData: fixture()))
    let runner = coordinator(db) { _, _, _, _ in
      await calls.add()
      if await calls.value == 1 { try await Task.sleep(nanoseconds: 10_000_000_000) }
      return output
    }
    defer { runner.stop() }
    await runner.enqueue(question.id)
    try await settle { await calls.value == 1 }
    await runner.setEnabled(false)
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "pending" }
    await runner.setEnabled(true)
    try await settle { try await db.automaticTagJob(questionID: question.id)?.status == "ready" }
    expectEqual(await calls.value, 2)
    expectTrue(try await db.solutions(questionID: question.id).isEmpty)
  }

  func testAutomaticMergeRespectsExistingManuallyOwnedDimension() async throws {
    let db = store()
    let output = try result()
    let question = try await db.save(.init(captureID: "owned", imageData: fixture()))
    let manual = MathQuestionTag(
      axis: "question_form", tagID: "manual.other", catalogueVersion: "legacy", label: "人工形式")
    try await db.updateClassification(questionID: question.id, grade: 4, tags: [manual])
    _ = try await db.enqueueAutomaticTags(questionID: question.id)
    let attempt = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    _ = try await db.completeAutomaticTags(
      attempt: attempt, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    let tags = try await db.tags(questionID: question.id)
    expectEqual(tags.filter { $0.axis == "question_form" }, [manual])
    expectTrue(tags.contains { $0.axis == "curriculum_knowledge" && $0.origin == "ai" })
  }

  func testV2MigrationAndBackupPreserveClassificationAnswersAndOriginal() async throws {
    let db = store()
    let bytes = try fixture()
    let question = try await db.save(
      .init(
        captureID: "v2", imageData: bytes,
        solutions: [.init(question: "自定提示词", answer: "原回答", model: "test")]))
    let manual = MathQuestionTag(axis: "custom", tagID: "old", catalogueVersion: "1", label: "原标签")
    try await db.updateClassification(questionID: question.id, grade: 4, tags: [manual])
    let answers = try await db.solutions(questionID: question.id)
    await db.close()
    var connection: OpaquePointer?
    expectEqual(
      sqlite3_open(db.directory.appendingPathComponent("questions.sqlite").path, &connection),
      SQLITE_OK)
    let handle = try unwrap(connection)
    defer { sqlite3_close(handle) }
    expectEqual(
      sqlite3_exec(
        handle,
        "DROP TABLE method_candidate_evidence; DROP TABLE method_candidates; DROP TABLE skill_learning_reports; DROP TABLE skill_learning_jobs; DROP TABLE skill_lifecycle_events; DROP TABLE skill_profiles; DROP TABLE solution_diagrams; ALTER TABLE question_solutions DROP COLUMN diagram_failure; DROP TABLE teaching_method_imports; DROP TABLE question_auto_tag_jobs; ALTER TABLE questions DROP COLUMN classification_revision; PRAGMA user_version = 2",
        nil, nil, nil), SQLITE_OK)
    let reopened = MathQuestionStore(directory: db.directory)
    expectEqual(try await reopened.list().first?.grade, 4)
    expectEqual(try await reopened.tags(questionID: question.id), [manual])
    expectEqual(try await reopened.originalImage(questionID: question.id), bytes)
    expectEqual(try await reopened.solutions(questionID: question.id), answers)
    expectEqual(try await reopened.storageConfiguration().schemaVersion, Int(MathQuestionArchive.supportedVersion))
  }

  func testNativeLibraryShowsAutomaticLabelsAndRetryWithoutRequiringConfirmation() async throws {
    let db = store()
    let output = try result()
    let previewImage = ProcessInfo.processInfo.environment["MATH_AUTO_TAG_UI_IMAGE"]
    let bytes = try previewImage.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? fixture()
    let question = try await db.save(
      .init(captureID: "ui", imageData: bytes, ocrText: "按要求组成乘法算式，并计算。"))
    _ = try await db.enqueueAutomaticTags(questionID: question.id)
    let attempt = try unwrap(try await db.claimAutomaticTags(questionID: question.id))
    _ = try await db.completeAutomaticTags(
      attempt: attempt, tags: output.tags, model: "test", promptVersion: "1", catalogueVersion: "1",
      evidence: output.evidence)
    var enabled = true
    var retried: String?
    let library = MathQuestionLibrary(
      store: db, reindex: { _ in }, autoTaggingEnabled: true, autoTaggingModel: "测试模型",
      onAutoTaggingChanged: { enabled = $0 }, retag: { retried = $0 }, backfillTags: {})
    defer { library.close() }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    library.present(questionID: question.id)
    try await settle {
      views(library.contentView!).compactMap { $0 as? NSButton }.contains {
        $0.title.contains("（AI 自动）")
      }
    }
    let buttons = views(library.contentView!).compactMap { $0 as? NSButton }
    let retry = try unwrap(buttons.first { $0.title == "重新分类" })
    expectTrue(retry.isEnabled)
    if let path = ProcessInfo.processInfo.environment["MATH_AUTO_TAG_UI_SNAPSHOT"],
      let view = library.contentView
    {
      view.layoutSubtreeIfNeeded()
      let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try unwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: path))
    }
    retry.performClick(nil)
    expectEqual(retried, question.id)
    try unwrap(buttons.first { $0.title == "自动分类" }).performClick(nil)
    expectFalse(enabled)
    let tags = try await db.tags(questionID: question.id)
    expectTrue(tags.allSatisfy { $0.origin == "ai" && $0.status == "suggested" })
  }
}

/// Opt-in real requests use only explicitly supplied public sample paths and an isolated store.
@MainActor
final class MathAutomaticTagLiveTests: XCTestCase {
  func testConfiguredModelClassifiesPublicSamples() async throws {
    guard let paths = ProcessInfo.processInfo.environment["MATH_AUTO_TAG_LIVE_SAMPLES"],
      !paths.isEmpty
    else {
      throw XCTSkip("Set public sample paths to enable real classification requests")
    }
    let appDefaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: appDefaults)
    let fallback = appDefaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
    var dictionary = fallback ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    dictionary.apiKey = KeychainStore.readAPIKey()
    let configuration = preferences.configuration(fallingBackTo: dictionary)
    guard configuration.isComplete else { throw XCTSkip("No configured screenshot model") }
    let client = ScreenshotQuestionClient()
    let tagger = MathQuestionAutoTagger(client: client)
    for path in paths.split(separator: ":") {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: String(path)))
      let output = try await tagger.classify(
        imageData: bytes, ocrText: "", grade: 4, configuration: configuration,
        api: preferences.selectedAPI, directConnection: preferences.selectedDirectConnection)
      XCTAssertFalse(output.tags.isEmpty)
      print(
        "Public sample classification: "
          + output.tags.map { $0.axis + "=" + $0.label }.joined(separator: "; "))
    }
    await client.shutdown()
  }
}

private actor Counter {
  private(set) var value = 0
  func add() { value += 1 }
}
