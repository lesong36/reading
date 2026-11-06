import AppKit
import XCTest
@testable import VocabCapture

private func profileReport(_ attempt: MathSkillProfileResearchAttempt) throws -> String {
  let object: [String: Any] = ["version": 1, "mode": "profile_review", "method_id": attempt.method.id,
    "version_id": attempt.method.versionID, "binding_digest": try attempt.bindingDigest,
    "source_sha256": MathSkillProfileResearchAttempt.digest(Data(attempt.method.instructions.utf8)),
    "review": ["checks": MathSkillProfileResearchResult.dimensions.map {
      ["dimension": $0, "passed": false, "reason": "协议回归资料：尚缺独立人工证据，不能视为真实模型准确性。"] as [String: Any]
    }, "recommendation": "needs_revision"], "status": "review_required", "model_calls": 1]
  return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

final class MathSkillProfileResearchTests: XCTestCase {
  private func temporaryStore() -> MathQuestionStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-research-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return .init(directory: root)
  }
  func testBundledEvidenceUnverifiedFiveChecksArchivedWithoutApprovalAndBackupRestores() async throws {
    let store = temporaryStore()
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first)
    _ = try await store.importMethods([.init(sourceID: skill.sourceID, title: skill.title, category: skill.category, instructions: skill.instructions)])
    let methods = try await store.methods(), method = try XCTUnwrap(methods.first)
    let attempt = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(attempt.method.instructions, skill.instructions)
    XCTAssertFalse(attempt.evidence.isEmpty)
    XCTAssertTrue(attempt.evidence.allSatisfy { $0.verification == "unverified" && $0.questionID.hasPrefix("teaching-case:") })
    XCTAssertTrue(attempt.questionSnapshots.isEmpty)
    try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "protocol-fixture")
    let profile = try await store.skillProfile(versionID: method.versionID)
    XCTAssertNil(profile, "An AI assessment must not create or approve a profile")
    let reports = try await store.profileResearchArchives(versionID: method.versionID)
    XCTAssertEqual(reports.count, 1); XCTAssertEqual(reports.first?.attempt, attempt)
    XCTAssertEqual(reports.first?.result.review.checks.count, 5)
    let automatic = try await store.automaticMethods(); XCTAssertEqual(automatic, methods)
    let backup = store.directory.deletingLastPathComponent().appendingPathComponent("profile-backup-\(UUID().uuidString)")
    let restored = temporaryStore()
    defer { try? FileManager.default.removeItem(at: backup) }
    try await store.backup(to: backup)
    _ = try await restored.restoreBackup(from: backup)
    let saved = try await restored.profileResearchArchives(versionID: method.versionID)
    XCTAssertEqual(saved, reports)
    await store.close(); await restored.close()
  }
  func testReportsPreserveHumanApprovalButCannotCrossContentOrVersionChanges() async throws {
    let store = temporaryStore()
    let original = try await store.saveMethod(title: "完整用户方法", category: "四年级", instructions: "  不要截断原文。\n使用算术比较不变量。\n ")
    let profile = MathSkillProfile(versionID: original.versionID, trigger: "同量比较", constraints: "不用方程",
      exclusions: "总量不同", prerequisites: "整数四则", supportedDiagrams: ["table"])
    let method = try await store.saveSkillProfileRevision(method: original, profile: profile)
    try await store.reviewCurrentSkillProfile(method: method, approved: true, note: "明确人工审校")
    let attempt = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(attempt.profile.status, "draft")
    try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "fixture")
    let approved = try await store.skillProfile(versionID: method.versionID)
    XCTAssertEqual(approved?.status, "approved", "Advisory AI findings cannot overwrite a human decision")
    var changed = try XCTUnwrap(approved); changed.exclusions += "；人数改变"
    let next = try await store.saveSkillProfileRevision(method: method, profile: changed)
    do { try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "fixture"); XCTFail("Stale method must be rejected") } catch {}
    let previous = try await store.profileResearchArchives(versionID: method.versionID)
    let current = try await store.profileResearchArchives(versionID: next.versionID)
    let pending = try await store.skillProfile(versionID: next.versionID)
    XCTAssertEqual(previous.count, 1); XCTAssertTrue(current.isEmpty); XCTAssertEqual(pending?.status, "draft")
    await store.close()
  }
  func testCurrentActualUsageSnapshotMustNotBecomeVerifiedAndInvalidatesWhenQuestionChanges() async throws {
    let store = temporaryStore()
    let method = try await store.saveMethod(title: "算术", category: "四年级", instructions: "逐条检查条件，用整数加减。")
    let record = try await store.save(.init(captureID: UUID().uuidString, imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.table),
      ocrText: "原题数量条件", solutions: [.init(question: "小学四年级不用方程", answer: "AI 自称验算通过", model: "fixture", method: method)]))
    let attempt = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(attempt.evidence.map(\.questionID), [record.id]); XCTAssertEqual(attempt.evidence.first?.verification, "unverified")
    XCTAssertEqual(attempt.questionSnapshots.first?.solutions.first?.method, method)
    try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "fixture")
    try await store.updateOCR(questionID: record.id, text: "用户修正后的数量条件")
    do { try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "fixture"); XCTFail("Changed evidence invalidates research") } catch {}
    let events = try await store.skillLifecycleEvents(versionID: method.versionID)
    XCTAssertEqual(events.count, 1)
    await store.close()
  }
  func testAnswerOnlyApprovalCannotCertifyMethodProcessAndFullReviewCan() async throws {
    let store = temporaryStore()
    let method = try await store.saveMethod(title: "步骤审校", category: "四年级", instructions: "检查两种分法，比较每份差与总差。")
    let solution = MathQuestionSolution(question: "不用方程", answer: "每份差与总差相比", model: "fixture", method: method)
    let question = try await store.save(.init(captureID: UUID().uuidString, imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.table), ocrText: "同一总量的两种分配", solutions: [solution]))
    _ = try await store.reviewSolution(questionID: question.id, solutionID: solution.id, status: "confirmed", scope: "最终答案", note: "只核对答案", correction: "")
    let answerOnly = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(answerOnly.evidence.first?.verification, "unverified")
    _ = try await store.reviewSolution(questionID: question.id, solutionID: solution.id, status: "confirmed", scope: "答案及解题过程", note: "检查适用条件和完整解法", correction: "")
    let fullReview = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(fullReview.evidence.first?.verification, "confirmed")
    _ = try await store.reviewSolution(questionID: question.id, solutionID: solution.id, status: "confirmed", scope: "最终答案", note: "新一轮只确认最终答案", correction: "")
    let latest = try await store.profileResearchAttempt(method: method)
    XCTAssertEqual(latest.evidence.first?.verification, "unverified", "Latest review scope remains authoritative")
    await store.close()
  }

  func testCounterexampleRoleUsesExactForbiddenMethodRatherThanGlobalNegativeKind() async throws {
    let store = temporaryStore(), catalogue = try MathSkillCatalogue.load()
    let review = try MathTeachingReviewCatalogue.load()
    _ = try await store.importMethods(catalogue.skills.map { .init(sourceID: $0.sourceID, title: $0.title, category: $0.category, instructions: $0.instructions) })
    let methods = try await store.methods()
    for method in methods {
      let attempt = try await store.profileResearchAttempt(method: method)
      let reference = try XCTUnwrap(review.reference(for: method))
      for item in attempt.evidence {
        let id = String(item.questionID.dropFirst("teaching-case:".count))
        let example = try XCTUnwrap(review.cases.first { $0.id == id })
        XCTAssertNotEqual(example.kind, "source_quarantine")
        XCTAssertEqual(item.role, example.forbidden_methods.contains(reference.skill_name) ? "excluded" : "positive")
        XCTAssertTrue(example.expected_methods.contains(reference.skill_name) || example.expected_visuals.contains(reference.skill_name) || example.forbidden_methods.contains(reference.skill_name))
      }
    }
    await store.close()
  }

  func testForgedVersionDigestDimensionsAndAutoApprovalAreRejected() async throws {
    let store = temporaryStore()
    let method = try await store.saveMethod(title: "待审", category: "四年级", instructions: "方法全文")
    let attempt = try await store.profileResearchAttempt(method: method)
    let text = try profileReport(attempt)
    let invalid: [(String, Any)] = [("binding_digest", "wrong"), ("source_sha256", "wrong"), ("version_id", "other"), ("status", "approved"), ("human_decision", "approve"), ("version", true), ("model_calls", 1.5)]
    for (key, value) in invalid {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]); object[key] = value
      let changed = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
      do { try await store.recordProfileResearch(attempt: attempt, report: changed, model: "fixture"); XCTFail("Invalid \(key) must not save") } catch {}
    }
    var result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    result["review"] = ["checks": MathSkillProfileResearchResult.dimensions.map { ["dimension": $0, "passed": true, "reason": "AI invented missing proof"] as [String: Any] }, "recommendation": "ready_for_human"]
    result["status"] = "awaiting_human"
    do { try await store.recordProfileResearch(attempt: attempt, report: String(decoding: JSONSerialization.data(withJSONObject: result), as: UTF8.self), model: "fixture"); XCTFail("No evidence cannot pass mathematics or counterexamples") } catch {}
    let events = try await store.skillLifecycleEvents(versionID: method.versionID); XCTAssertTrue(events.isEmpty)
    await store.close()
  }
}

@MainActor
final class MathSkillProfileResearchUITests: XCTestCase {
  func testAutomaticAssessmentAppearsInRealPanelAndRestoreCancelsLateResearch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first)
    _ = try await store.importMethods([.init(sourceID: skill.sourceID, title: skill.title, category: skill.category, instructions: skill.instructions)])
    let entries = try await store.methods(), method = try XCTUnwrap(entries.first)
    let panel = MathSkillProfilePanel(store: store, method: method, research: { method in
      let attempt = try await store.profileResearchAttempt(method: method)
      try await store.recordProfileResearch(attempt: attempt, report: profileReport(attempt), model: "界面协议测试")
    })
    panel.present()
    XCTAssertTrue(panel.isMutating, "Initial load must keep review controls busy")
    for _ in 0..<500 {
      if !panel.isMutating { break }; try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(panel.isMutating)
    let button = try XCTUnwrap(descendants(panel.panel.contentView).compactMap { $0 as? NSButton }.first { $0.title == "自动五项教研" })
    XCTAssertTrue(button.isEnabled); button.performClick(nil)
    for _ in 0..<100 {
      if !panel.isMutating { break }; try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(panel.isMutating, "Report loading must finish before controls are enabled")
    let text = descendants(panel.panel.contentView).compactMap { $0 as? NSTextView }.map(\.string).joined()
    for label in MathSkillProfileResearchResult.labels.values { XCTAssertTrue(text.contains(label)) }
    XCTAssertTrue(text.contains("非人工批准")); XCTAssertTrue(text.contains("需补充或修订"))
    if let path = ProcessInfo.processInfo.environment["MATH_SKILL_PROFILE_RESEARCH_SNAPSHOT"] {
      panel.panel.bringToFront()
      let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-l", String(panel.panel.windowNumber), path]
      try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    await panel.prepareForLibraryRestore()
    let coordinator = MathSkillProfileResearchCoordinator(store: store, configuration: {
      .init(configuration: .init(baseURL: "https://example.com", model: "fixture", apiKey: ""), api: .chatCompletions, directConnection: false)
    }, analyze: { _, image, _, _ in
      XCTAssertTrue(image.isEmpty, "Text sources must not acquire another question's photo")
      try await Task.sleep(nanoseconds: 10_000_000_000)
      throw ScreenshotQuestionError.invalidResponse
    })
    let late = MathSkillProfilePanel(store: store, method: method, research: { try await coordinator.review(method: $0) })
    late.present()
    for _ in 0..<500 {
      if !late.isMutating { break }; try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(late.isMutating)
    let lateButton = try XCTUnwrap(descendants(late.panel.contentView).compactMap { $0 as? NSButton }.first { $0.title == "自动五项教研" })
    lateButton.performClick(nil); try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(late.isMutating)
    await late.prepareForLibraryRestore()
    XCTAssertFalse(late.isMutating)
    let reports = try await store.profileResearchArchives(versionID: method.versionID); XCTAssertEqual(reports.count, 1)
    await store.close()
  }
  private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
  }
}
