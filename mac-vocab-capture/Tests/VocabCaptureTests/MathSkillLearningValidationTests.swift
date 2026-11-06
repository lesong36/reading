import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

final class MathSkillLearningValidationTests: XCTestCase {
  private func checkpoint(status: String = "observing", count: Int = 1) -> [String: Any] {
    let sources = (0..<count).map { index in
      ["question_id": "q-\(index)", "text": "不同结构条件 \(index)", "answer": "算术过程", "reference_answer": "",
       "verification": "unverified", "role": "positive", "grade": 4, "user_constraint": "不用方程"] as [String: Any]
    }
    let proposal: Any = status == "awaiting_human" ? [
      "title": "共享不变量", "category": "四年级", "instructions": String(repeating: "先明确共同不变量，再比较两个过程变化，逐条验算原题条件；不将条件缺失题目认定为适用。", count: 4),
      "trigger": "两个过程共用已知不变量", "prerequisites": ["整数四则"], "exclusions": ["共同条件缺失"], "diagram_templates": ["table"],
      "evidence_ids": sources.map { $0["question_id"]! }, "review_notes": "需要人工核对"] : NSNull()
    let review: Any = status == "awaiting_human" ? ["checks": MathSkillLearningValidation.dimensions.sorted().map {
      ["dimension": $0, "passed": true, "reason": "协议测试，不代表实测模型准确率"] as [String: Any]
    }, "recommendation": "ready_for_human"] : NSNull()
    var result: [String: Any] = ["version": 1, "coverage": status == "covered" ? "covered" : "uncovered", "covered_method_ids": status == "covered" ? ["existing-method"] : [],
      "pattern_evidence_ids": sources.map { $0["question_id"]! }, "reason": "比较结构后观察", "pattern_key": "shared-invariant",
      "proposal": proposal, "review": review, "status": status]
    var state = result; state.removeValue(forKey: "version")
    state["evidence"] = sources; state["existing_patterns"] = []; state["model_calls"] = status == "awaiting_human" ? 3 : 1
    result["workflow_state"] = ["version": 1, "state": state]
    return result
  }

  private func mutateState(_ source: [String: Any], _ mutation: (inout [String: Any]) -> Void) -> [String: Any] {
    var report = source, checkpoint = report["workflow_state"] as! [String: Any]
    var state = checkpoint["state"] as! [String: Any]; mutation(&state)
    for key in ["coverage", "covered_method_ids", "pattern_evidence_ids", "reason", "pattern_key", "proposal", "review", "status"] { report[key] = state[key] }
    checkpoint["state"] = state; report["workflow_state"] = checkpoint; return report
  }

  func testValidProductionStatesAndInertHistoricalReportsRemainReadable() throws {
    for status in ["covered", "observing", "awaiting_human"] {
      try MathSkillLearningValidation.validate(checkpoint(status: status, count: status == "awaiting_human" ? 3 : 1))
    }
    try MathSkillLearningValidation.validate([:])
    try MathSkillLearningValidation.validate(["version": 1])
    XCTAssertThrowsError(try MathSkillLearningValidation.validate([:], allowLegacyWithoutCheckpoint: false))
  }

  func testPagedCoverageBudgetsAndZeroCallUncertaintyRemainValid() throws {
    let reviewed = mutateState(checkpoint(status: "awaiting_human", count: 3)) { $0["model_calls"] = 8 }
    try MathSkillLearningValidation.validate(reviewed)
    let incomplete = mutateState(checkpoint()) {
      $0["model_calls"] = 0
      $0["coverage"] = "uncertain"
      $0["covered_method_ids"] = [String]()
      $0["pattern_evidence_ids"] = [String]()
    }
    try MathSkillLearningValidation.validate(incomplete)
  }

  func testForgedStatesBudgetsSourcesProposalAndReviewAreRejected() throws {
    let valid = checkpoint(status: "awaiting_human", count: 3)
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["model_calls"] = true }, { $0["model_calls"] = 9 }, { $0["model_calls"] = 2 },
      { $0["status"] = "approved" }, { $0["status"] = "draft" }, { $0["status"] = "failed" },
      { $0["pattern_evidence_ids"] = ["nonexistent"] }, { $0["pattern_evidence_ids"] = ["q-0", "q-0"] },
      { $0["pattern_key"] = "fixed_problem_123" },
      { var evidence = $0["evidence"] as! [[String: Any]]; evidence[0]["grade"] = true; $0["evidence"] = evidence },
      { var evidence = $0["evidence"] as! [[String: Any]]; evidence[1]["question_id"] = "q-0"; $0["evidence"] = evidence },
      { var draft = $0["proposal"] as! [String: Any]; draft["evidence_ids"] = ["q-0", "q-1", "invented"]; $0["proposal"] = draft },
      { var draft = $0["proposal"] as! [String: Any]; draft["diagram_templates"] = ["unsupported"]; $0["proposal"] = draft },
      { var review = $0["review"] as! [String: Any], checks = review["checks"] as! [[String: Any]]; checks[0]["passed"] = 1; review["checks"] = checks; $0["review"] = review },
      { var review = $0["review"] as! [String: Any], checks = review["checks"] as! [[String: Any]]; checks[0]["passed"] = false; review["checks"] = checks; $0["review"] = review },
      { $0["human_decision"] = ["action": "approve", "reviewer": "AI", "note": "自批"] }
    ]
    for (index, mutation) in mutations.enumerated() {
      XCTAssertThrowsError(try MathSkillLearningValidation.validate(mutateState(valid, mutation)), "Mutation \(index)")
    }
    var mismatch = valid; mismatch["reason"] = "顶层被替换"
    XCTAssertThrowsError(try MathSkillLearningValidation.validate(mismatch))
    var boolVersion = valid; boolVersion["version"] = true
    XCTAssertThrowsError(try MathSkillLearningValidation.validate(boolVersion))
    XCTAssertThrowsError(try MathSkillLearningValidation.validate(checkpoint(status: "covered"), allowedMethodIDs: []))
  }

  func testFrozenBackgroundSourcesSurviveUpdatesAndRejectRestoreTampering() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("learning-validator-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let question = try await store.save(.init(captureID: "frozen", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), ocrText: "原题关系", solutions: [.init(id: "original-answer", question: "不用方程", answer: "原始算术过程", model: "fixture")]))
    try await store.enqueueSkillLearning(questionID: question.id)
    let claimed = try await store.claimSkillLearning(questionID: question.id), attempt = try XCTUnwrap(claimed)
    var object = checkpoint()
    object = mutateState(object) { state in
      state["evidence"] = [MathSkillLearningValidation.backgroundEvidence(attempt.snapshot)]
      state["pattern_evidence_ids"] = [question.id]
    }
    let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    try await store.finishSkillLearning(attempt: attempt, proposal: nil, report: text, model: "fixture", patternKey: "shared-invariant")
    let reports = try await store.skillLearningReports(questionID: question.id)
    let persisted = try XCTUnwrap(reports.first)
    let durable = try JSONSerialization.jsonObject(with: Data(persisted.report.utf8)) as! [String: Any]
    XCTAssertNotNil(durable["native_learning_sources"])
    try await store.updateOCR(questionID: question.id, text: "后来的人工索引")
    _ = try await store.reviewSolution(questionID: question.id, solutionID: "original-answer", status: "confirmed", scope: "答案及解题过程", note: "之后核验", correction: "")
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup); await store.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("questions.sqlite").path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
    _ = try MathQuestionArchive.validate(db)
    var bad = durable
    var frozen = bad["native_learning_sources"] as! [[String: Any]]
    var solutions = frozen[0]["solutions"] as! [[String: Any]]; solutions[0]["answer"] = "伪造解答"
    frozen[0]["solutions"] = solutions; bad["native_learning_sources"] = frozen
    let altered = String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_learning_reports SET report_json='\(altered)'", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.validate(db))
    let original = persisted.report.replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_learning_reports SET report_json='\(original)'", nil, nil, nil), SQLITE_OK)
    _ = try MathQuestionArchive.validate(db)
    var malformed = mutateState(durable) { $0["model_calls"] = 99 }
    malformed["native_learning_sources"] = durable["native_learning_sources"]
    let malformedText = String(decoding: try JSONSerialization.data(withJSONObject: malformed), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_learning_reports SET report_json='\(malformedText)'", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.validate(db))
  }
}
