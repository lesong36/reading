import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

final class MathSkillResearchArchiveValidationTests: XCTestCase {
  private func report(_ attempt: MathSkillProfileResearchAttempt) throws -> String {
    let object: [String: Any] = ["version": 1, "mode": "profile_review", "method_id": attempt.method.id,
      "version_id": attempt.method.versionID, "binding_digest": try attempt.bindingDigest,
      "source_sha256": MathSkillProfileResearchAttempt.digest(Data(attempt.method.instructions.utf8)),
      "review": ["checks": MathSkillProfileResearchResult.dimensions.map {
        ["dimension": $0, "passed": false, "reason": "归档协议校验，缺少完整人工证据"] as [String: Any]
      }, "recommendation": "needs_revision"], "status": "review_required", "model_calls": 1]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  func testProfileHistoricalSourceBindingSurvivesEditsButRejectsConsistentFabrication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-archive-validator-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let original = try await store.saveMethod(title: "不变量比较", category: "四年级", instructions: "保留完整原方法：先找到不变量，再用四则比较变化。")
    let method = try await store.saveSkillProfileRevision(method: original, profile: .init(versionID: original.versionID,
      trigger: "共享不变量", constraints: "不用方程", exclusions: "条件不足", prerequisites: "整数四则", supportedDiagrams: ["table"]))
    let question = try await store.save(.init(captureID: "history", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.table), ocrText: "原题条件",
      solutions: [.init(id: "historical-solution", question: "不用方程", answer: "待核验过程", model: "fixture", method: method)]))
    let attempt = try await store.profileResearchAttempt(method: method)
    try await store.recordProfileResearch(attempt: attempt, report: report(attempt), model: "fixture")
    try await store.reviewCurrentSkillProfile(method: method, approved: true, note: "用户核对当前版本")
    let approved = try await store.skillProfile(versionID: method.versionID)
    var next = try XCTUnwrap(approved); next.exclusions += "；新增边界"
    _ = try await store.saveSkillProfileRevision(method: method, profile: next)
    try await store.updateOCR(questionID: question.id, text: "后来更正的索引")
    _ = try await store.reviewSolution(questionID: question.id, solutionID: "historical-solution", status: "confirmed", scope: "答案及解题过程", note: "后来确认", correction: "")
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup); await store.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("questions.sqlite").path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
    _ = try MathQuestionArchive.validate(db)
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT note FROM skill_lifecycle_events WHERE decision='ai_research'", -1, &statement, nil), SQLITE_OK)
    let prepared = try XCTUnwrap(statement); defer { sqlite3_finalize(prepared) }
    XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
    let text = try XCTUnwrap(sqlite3_column_text(prepared, 0)).withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    var archive = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    var source = archive["attempt"] as! [String: Any]
    var sourceMethod = source["method"] as! [String: Any]; sourceMethod["instructions"] = "伪造但相互一致的方法正文"
    source["method"] = sourceMethod; archive["attempt"] = source
    let changedAttempt = try JSONDecoder().decode(MathSkillProfileResearchAttempt.self, from: JSONSerialization.data(withJSONObject: source))
    var result = archive["result"] as! [String: Any]
    result["binding_digest"] = try changedAttempt.bindingDigest
    result["source_sha256"] = MathSkillProfileResearchAttempt.digest(Data(changedAttempt.method.instructions.utf8))
    archive["result"] = result
    let altered = String(decoding: try JSONSerialization.data(withJSONObject: archive), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_lifecycle_events SET note='\(altered)' WHERE decision='ai_research'", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.validate(db), "Self-consistent forged content must still bind the actual immutable method version")
    let restored = text.replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_lifecycle_events SET note='\(restored)' WHERE decision='ai_research'", nil, nil, nil), SQLITE_OK)
    _ = try MathQuestionArchive.validate(db)
  }

  func testResearchBeforeInitialProfileSaveRemainsValidHistoricalMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-seed-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let method = try await store.saveMethod(title: "用户完整方法", category: "四年级", instructions: "先比较不变量，使用整数四则运算。")
    let attempt = try await store.profileResearchAttempt(method: method)
    try await store.recordProfileResearch(attempt: attempt, report: report(attempt), model: "fixture")
    try await store.saveSkillProfile(profile: .init(versionID: method.versionID, trigger: "共同不变量",
      constraints: "不用方程", exclusions: "共同条件未知", prerequisites: "整数四则", supportedDiagrams: ["table"]))
    try await store.backup(to: root.appendingPathComponent("backup"))
    let historical = try await store.profileResearchArchives(versionID: method.versionID)
    XCTAssertEqual(historical.first?.attempt, attempt, "A later initial profile cannot replace historical research inputs")
    await store.close()
  }

  func testFrozenPrimaryAndVisualMethodsMustMatchOriginalSolutionSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-method-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let primary = try await store.saveMethod(title: "主解法", category: "四年级", instructions: "先识别数量关系，再用整数加减比较。")
    let visual = try await store.saveMethod(title: "辅助画图", category: "图解", instructions: "用两条线段表示数量关系。")
    _ = try await store.save(.init(captureID: "frozen-methods", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), ocrText: "数量比较的条件",
      solutions: [.init(id: "two-method-answer", question: "四年级不用方程", answer: "需要人工核验的过程", model: "fixture", method: primary, visualMethods: [visual])]))
    let attempt = try await store.profileResearchAttempt(method: primary)
    let response = try report(attempt)
    try await store.recordProfileResearch(attempt: attempt, report: response, model: "fixture")
    let archives = try await store.profileResearchArchives(versionID: primary.versionID)
    let original = try XCTUnwrap(archives.first)
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup); await store.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("questions.sqlite").path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let originalData = try encoder.encode(original)
    for role in ["method", "visualMethods"] {
      var object = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
      var source = object["attempt"] as! [String: Any]
      var snapshots = source["questionSnapshots"] as! [[String: Any]]
      var solutions = snapshots[0]["solutions"] as! [[String: Any]]
      if role == "method" {
        var selected = solutions[0]["method"] as! [String: Any]; selected["instructions"] = "冒充相同版本的另一种方法"
        solutions[0]["method"] = selected
      } else {
        var selected = solutions[0]["visualMethods"] as! [[String: Any]]; selected[0]["instructions"] = "冒充相同版本的另一幅画图方法"
        solutions[0]["visualMethods"] = selected
      }
      snapshots[0]["solutions"] = solutions; source["questionSnapshots"] = snapshots; object["attempt"] = source
      let changed = try JSONDecoder().decode(MathSkillProfileResearchAttempt.self, from: JSONSerialization.data(withJSONObject: source))
      var result = object["result"] as! [String: Any]; result["binding_digest"] = try changed.bindingDigest; object["result"] = result
      let altered = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
      XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_lifecycle_events SET note='\(altered)' WHERE decision='ai_research'", nil, nil, nil), SQLITE_OK)
      XCTAssertThrowsError(try MathQuestionArchive.validate(db), "Frozen \(role) must match the solution's immutable method_snapshot")
    }
    let restore = String(decoding: originalData, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_lifecycle_events SET note='\(restore)' WHERE decision='ai_research'", nil, nil, nil), SQLITE_OK)
    _ = try MathQuestionArchive.validate(db)
  }

}
