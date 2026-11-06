import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

final class MathTeachingPermissionIntegrationTests: XCTestCase {
  private func root() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("permission-integration-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func testCustomEquationPermissionDoesNotGrantIndependentExtensionPermission() {
    let declaration = MathTeachingPermissions(minimumGrade: 5, equationRequirement: .required, extensionRequirement: .explicitPermission)
    let method = MathTeachingMethod(id: "custom", versionID: "immutable-v1", title: "用户方法", category: "声明权限",
      instructions: "用户方法完整正文；不能仅根据分类或排除条款判断学段。", createdAt: Date(), teachingPermissions: declaration)
    for text in ["四年级，允许方程，禁止拓展", "五年级，允许方程", "四年级，允许方程"] {
      XCTAssertTrue(MathMethodMatcher.eligibleMethods([method], question: text).isEmpty, text)
    }
    XCTAssertEqual(MathMethodMatcher.eligibleMethods([method], question: "五年级，允许方程，允许拓展"), [method])
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([method], question: "五年级，不用方程，允许拓展").isEmpty)
  }

  func testLegacyUnknownMethodRemainsManualAndOldJSONDoesNotInventPermissions() throws {
    let old = #"{"id":"legacy","versionID":"v1","title":"旧方法","category":"四年级","instructions":"不用方程只是一句正文数据，不能替代结构化声明","createdAt":0}"#
    let legacy = try JSONDecoder().decode(MathTeachingMethod.self, from: Data(old.utf8))
    XCTAssertNil(legacy.teachingPermissions)
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([legacy], question: "四年级不用方程").isEmpty)
    let policy = try XCTUnwrap(MathMethodMatcher.eligibilityPolicy(for: legacy))
    XCTAssertEqual(policy.schema_version, 2); XCTAssertEqual(policy.source, "unknown")
    let selected = try MathMethodMatcher.parse(#"{"method_id":"legacy","reason":"用户手动选择原版本"}"#, methods: [legacy])
    XCTAssertEqual(selected.method, legacy, "Manual selection and frozen legacy snapshots remain readable")
  }

  func testProfilePermissionEditsAndOmittedDeclarationStayVersionBoundAcrossReopenAndBackup() async throws {
    let directory = root(), store = MathQuestionStore(directory: directory.appendingPathComponent("library"))
    let permissions = MathTeachingPermissions(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none)
    let method = try await store.saveMethod(title: "用户算术", category: "四年级", instructions: "比较两量之差。", teachingPermissions: permissions)
    try await store.reviewCurrentSkillProfile(method: method, approved: true, note: "核对当前正文与教学权限")
    let solution = MathQuestionSolution(question: "不用方程", answer: "算术解答", model: "隔离测试", method: method)
    let question = try await store.save(.init(captureID: UUID().uuidString, imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), ocrText: "两量和差", solutions: [solution]))
    let currentProfile = try await store.skillProfile(versionID: method.versionID)
    var change = try XCTUnwrap(currentProfile)
    change.teachingPermissions = .init(minimumGrade: 5, equationRequirement: .required, extensionRequirement: .explicitPermission)
    let revised = try await store.saveSkillProfileRevision(method: method, profile: change)
    XCTAssertNotEqual(revised.versionID, method.versionID)
    let approvedOld = try await store.skillProfile(versionID: method.versionID)
    let draftNew = try await store.skillProfile(versionID: revised.versionID)
    XCTAssertEqual(approvedOld?.status, "approved"); XCTAssertEqual(draftNew?.status, "draft")
    XCTAssertEqual(revised.teachingPermissions, change.teachingPermissions)
    let automatic = try await store.automaticMethods(); XCTAssertTrue(automatic.isEmpty)
    await store.close()
    let reopened = MathQuestionStore(directory: directory.appendingPathComponent("library"))
    let methods = try await reopened.methods(); XCTAssertEqual(methods, [revised])
    let oldAnswers = try await reopened.solutions(questionID: question.id)
    XCTAssertEqual(oldAnswers, [solution]); XCTAssertEqual(oldAnswers.first?.method?.teachingPermissions, permissions)
    let backup = directory.appendingPathComponent("backup")
    try await reopened.backup(to: backup)
    let restored = MathQuestionStore(directory: directory.appendingPathComponent("restored"))
    _ = try await restored.restoreBackup(from: backup)
    let restoredAnswers = try await restored.solutions(questionID: question.id)
    let restoredMethods = try await restored.methods()
    XCTAssertEqual(restoredAnswers, [solution]); XCTAssertEqual(restoredMethods, [revised])
    let noDeclaration = try await restored.saveMethod(id: revised.id, title: revised.title, category: revised.category, instructions: revised.instructions + " 改写")
    XCTAssertNil(noDeclaration.teachingPermissions)
    let noDeclarationProfile = try await restored.skillProfile(versionID: noDeclaration.versionID)
    XCTAssertEqual(noDeclarationProfile?.status, "draft")
    try await restored.reviewCurrentSkillProfile(method: noDeclaration, approved: true, note: "仅正文人审，未声明教学权限")
    let approvedMethods = try await restored.automaticMethods()
    XCTAssertTrue(MathMethodMatcher.eligibleMethods(approvedMethods, question: "四年级不用方程").isEmpty)
    await reopened.close(); await restored.close()
  }

  func testCannotAttachPermissionsToExistingVersionWithoutMakingNewVersion() async throws {
    let store = MathQuestionStore(directory: root())
    let method = try await store.saveMethod(title: "旧版本", category: "四年级", instructions: "保留旧正文")
    let profile = MathSkillProfile(versionID: method.versionID, trigger: "同量", constraints: "小学算术", exclusions: "条件不足",
      prerequisites: "整数加减", supportedDiagrams: [], teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    do { try await store.saveSkillProfile(profile: profile); XCTFail("Permission declaration cannot be attached in place") } catch {}
    let methods = try await store.methods(); XCTAssertEqual(methods, [method])
    let saved = try await store.skillProfile(versionID: method.versionID); XCTAssertNil(saved)
    await store.close()
  }

  func testPermissionProfileResearchArchiveCanBeBackedUpWithRenderedPermissionPrefix() async throws {
    let directory = root(), store = MathQuestionStore(directory: directory.appendingPathComponent("library"))
    let permission = MathTeachingPermissions(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none)
    let initial = try await store.saveMethod(title: "权限教研", category: "四年级", instructions: "比较总差与每份差。", teachingPermissions: permission)
    let loaded = try await store.skillProfile(versionID: initial.versionID)
    var profile = try XCTUnwrap(loaded)
    profile.trigger = "总量不变"; profile.exclusions = "两次总量不同不适用"; profile.prerequisites = "整数除法"
    let method = try await store.saveSkillProfileRevision(method: initial, profile: profile)
    XCTAssertTrue(method.instructions.hasPrefix("结构化教学权限："))
    let attempt = try await store.profileResearchAttempt(method: method)
    let output: [String: Any] = ["version": 1, "mode": "profile_review", "method_id": method.id,
      "version_id": method.versionID, "binding_digest": try attempt.bindingDigest,
      "source_sha256": MathSkillProfileResearchAttempt.digest(Data(method.instructions.utf8)), "status": "review_required", "model_calls": 1,
      "review": ["checks": MathSkillProfileResearchResult.dimensions.map { ["dimension": $0, "passed": false, "reason": "协议测试，缺少确认正反例"] as [String: Any] }, "recommendation": "needs_revision"]]
    try await store.recordProfileResearch(attempt: attempt, report: String(decoding: JSONSerialization.data(withJSONObject: output), as: UTF8.self), model: "protocol-fixture")
    let backup = directory.appendingPathComponent("backup")
    try await store.backup(to: backup)
    let restored = MathQuestionStore(directory: directory.appendingPathComponent("restored"))
    _ = try await restored.restoreBackup(from: backup)
    let reports = try await restored.profileResearchArchives(versionID: method.versionID)
    XCTAssertEqual(reports.first?.attempt, attempt)
    await store.close(); await restored.close()
  }

  func testRestoreRejectsValidButUnboundFrozenAnswerPermissionsWithoutReplacingTarget() async throws {
    let directory = root(), source = MathQuestionStore(directory: directory.appendingPathComponent("source"))
    let permissions = MathTeachingPermissions(minimumGrade: 5, equationRequirement: .required, extensionRequirement: .explicitPermission)
    let method = try await source.saveMethod(title: "方程方法", category: "用户", instructions: "方法完整正文", teachingPermissions: permissions)
    let solution = MathQuestionSolution(question: "允许方程", answer: "待核验回答", model: "fixture", method: method)
    _ = try await source.save(.init(captureID: UUID().uuidString, imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), ocrText: "原题", solutions: [solution]))
    let backup = directory.appendingPathComponent("backup")
    try await source.backup(to: backup); await source.close()
    let spoofed = MathTeachingMethod(id: method.id, versionID: method.versionID, title: method.title, category: method.category,
      instructions: method.instructions, createdAt: method.createdAt,
      teachingPermissions: .init(minimumGrade: 1, equationRequirement: .notRequired, extensionRequirement: .none))
    let text = String(decoding: try JSONEncoder().encode(spoofed), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    var pointer: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(backup.appendingPathComponent("questions.sqlite").path, &pointer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
    let db = try XCTUnwrap(pointer)
    XCTAssertEqual(sqlite3_exec(db, "UPDATE question_solutions SET method_snapshot='\(text)' WHERE id='\(solution.id)'", nil, nil, nil), SQLITE_OK)
    sqlite3_close_v2(db)
    let target = MathQuestionStore(directory: directory.appendingPathComponent("target"))
    let retained = try await target.saveMethod(title: "当前库", category: "保留", instructions: "恢复失败时不得覆盖")
    do { _ = try await target.restoreBackup(from: backup); XCTFail("Valid JSON permission must match its immutable version profile") } catch {}
    let actual = try await target.methods(); XCTAssertEqual(actual, [retained])
    await target.close()
  }

  func testNativePermissionTransportAcceptedByPythonAndBodyVersionTamperingRejected() async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let engine = package.appendingPathComponent("question-engine"), python = engine.appendingPathComponent(".venv/bin/python")
    guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Requires existing question-engine local runtime") }
    let method = MathTeachingMethod(id: "native-custom", versionID: "native-version", title: "本地方法", category: "用户方法",
      instructions: "正文的方程字样不参与权限推断。", createdAt: Date(),
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    let data = try ScreenshotQuestionClient.payload(question: "四年级不用方程", context: .init(text: "原题", selectedWord: nil, imageData: nil),
      history: [], configuration: .init(baseURL: "https://example.com", model: "协议测试", apiKey: ""), api: .automatic, teachingSkills: [method])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try XCTUnwrap(object["teaching_skills"] as? [[String: String]])
    let body = try JSONSerialization.data(withJSONObject: rows)
    let script = """
      import json,sys
      from math_skills import snapshots_for,eligible_snapshots,SkillError
      rows=json.load(sys.stdin)
      snapshots=snapshots_for(rows)
      assert [s['id'] for s in eligible_snapshots(snapshots,'四年级不用方程')]==['native-custom']
      for field,value in [('instructions','已变更正文'),('version_id','新版本')]:
          try: snapshots_for([{**rows[0],field:value}])
          except SkillError: pass
          else: raise AssertionError('Unbound policy accepted: '+field)
      print('native-python exact permission binding passed')
      """
    let result = try await Task.detached {
      let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
      process.executableURL = python; process.currentDirectoryURL = engine; process.arguments = ["-c", script]
      process.standardInput = input; process.standardOutput = output; process.standardError = errors
      try process.run(); try input.fileHandleForWriting.write(contentsOf: body); try input.fileHandleForWriting.close()
      let bytes = output.fileHandleForReading.readDataToEndOfFile(), diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: bytes, as: UTF8.self), String(decoding: diagnostics, as: UTF8.self))
    }.value
    XCTAssertEqual(result.0, 0, result.2); XCTAssertTrue(result.1.contains("exact permission binding passed"))
  }
}
