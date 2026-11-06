import CoreFoundation
import Foundation

/// Validate the portable graph and report together before durable human approval.
enum MathSkillResearchValidation {
  static func validate(_ object: [String: Any], evidence expectedEvidence: Any? = nil,
    proposal expectedProposal: Any? = nil) throws {
    func fail() -> MathQuestionStoreError { .database("教研恢复点与当前方法或核验依据不一致，请重新审校") }
    guard integer(object["version"]) == 1,
      let status = object["status"] as? String, ["awaiting_human", "approved"].contains(status),
      let checkpoint = object["workflow_state"] as? [String: Any], Set(checkpoint.keys) == ["version", "state"],
      integer(checkpoint["version"]) == 1,
      try JSONSerialization.data(withJSONObject: checkpoint).count <= 200_000,
      let state = checkpoint["state"] as? [String: Any],
      let calls = integer(state["model_calls"]), (0...4).contains(calls),
      let evidence = state["evidence"] as? [[String: Any]], (3...24).contains(evidence.count),
      let proposal = state["proposal"] as? [String: Any],
      let research = state["review"] as? [String: Any],
      let checks = research["checks"] as? [[String: Any]], checks.count == 5,
      Set(research.keys) == ["checks", "recommendation"],
      Set(checks.compactMap { $0["dimension"] as? String }) == ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"]
    else { throw fail() }
    var fields: Set<String> = ["evidence", "existing_patterns", "coverage", "covered_method_ids", "pattern_evidence_ids", "reason", "pattern_key", "proposal", "review", "status", "model_calls"]
    if status == "approved" { fields.insert("human_decision") }
    guard Set(state.keys) == fields, state["coverage"] as? String == "uncovered",
      (state["covered_method_ids"] as? [String])?.isEmpty == true,
      let signature = state["pattern_key"] as? String,
      signature.range(of: "^[a-z][a-z_-]{2,127}$", options: .regularExpression) != nil,
      let reason = state["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 2_000,
      let patterns = state["existing_patterns"] as? [[String: Any]], patterns.count <= 100
    else { throw fail() }
    for pattern in patterns {
      guard Set(pattern.keys) == ["signature", "evidence_ids", "status"],
        let patternID = pattern["signature"] as? String, !patternID.isEmpty, patternID.count <= 256,
        let ids = pattern["evidence_ids"] as? [String], ids.count <= 100, Set(ids).count == ids.count,
        ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
        let patternStatus = pattern["status"] as? String, !patternStatus.isEmpty, patternStatus.count <= 64
      else { throw fail() }
    }
    for item in evidence {
      guard Set(item.keys) == ["question_id", "text", "answer", "reference_answer", "verification", "role", "grade", "user_constraint"],
        let id = item["question_id"] as? String, !id.isEmpty, id.count <= 128,
        ["text", "answer", "reference_answer"].allSatisfy({ (item[$0] as? String).map { $0.count <= 6_000 } == true }),
        (item["user_constraint"] as? String).map({ $0.count <= 2_000 }) == true,
        item["verification"] as? String == "confirmed",
        ["positive", "excluded"].contains(item["role"] as? String ?? ""),
        item["grade"] is NSNull || integer(item["grade"]).map({ (1...6).contains($0) }) == true
      else { throw fail() }
    }
    let ids = evidence.compactMap { $0["question_id"] as? String }
    guard Set(ids).count == ids.count,
      try JSONSerialization.data(withJSONObject: evidence).count <= 150_000,
      let matched = state["pattern_evidence_ids"] as? [String], Set(matched).count == matched.count,
      Set(matched) == Set(evidence.filter { $0["role"] as? String == "positive" }.compactMap { $0["question_id"] as? String }),
      let citations = proposal["evidence_ids"] as? [String], citations.count >= 3,
      Set(citations).count == citations.count, Set(citations).isSubset(of: Set(ids))
    else { throw fail() }
    let allPassed = checks.allSatisfy { $0["passed"] as? Bool == true }
    for check in checks {
      guard Set(check.keys) == ["dimension", "passed", "reason"],
        let passed = check["passed"] as? NSNumber, CFGetTypeID(passed) == CFBooleanGetTypeID(),
        let text = check["reason"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2_000
      else { throw fail() }
    }
    guard research["recommendation"] as? String == (allPassed ? "ready_for_human" : "needs_revision") else { throw fail() }
    for key in ["coverage", "covered_method_ids", "pattern_evidence_ids", "reason", "pattern_key", "proposal", "review", "status"] {
      guard try equal(state[key], object[key]) else { throw fail() }
    }
    if let expectedEvidence, try !equal(evidence, expectedEvidence) { throw fail() }
    if let expectedProposal, try !equal(proposal, expectedProposal) { throw fail() }
    if status == "approved" {
      guard allPassed, let decision = object["human_decision"] as? [String: Any],
        Set(decision.keys) == ["action", "reviewer", "note"], decision["action"] as? String == "approve",
        ["reviewer", "note"].allSatisfy({ (decision[$0] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 2_000 } == true }),
        try equal(state["human_decision"], decision)
      else { throw fail() }
    } else if object["human_decision"] != nil { throw fail() }
  }

  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max),
      number.doubleValue == number.doubleValue.rounded() else { return nil }
    return number.intValue
  }
  private static func equal(_ left: Any?, _ right: Any?) throws -> Bool {
    guard let left, let right else { return false }
    return try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys, .fragmentsAllowed]) == JSONSerialization.data(withJSONObject: right, options: [.sortedKeys, .fragmentsAllowed])
  }
}
