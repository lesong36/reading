import CoreFoundation
import Foundation

/// Validate persisted LangGraph protocol, never interpret a model's checkpoint as human consent.
/// Older opaque reports without checkpoints remain readable; they cannot be resumed or approved.
enum MathSkillLearningValidation {
  static let dimensions: Set<String> = ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"]

  static func validate(_ object: [String: Any], sourceSnapshots: [MathSkillLearningSnapshot] = [],
    allowedMethodIDs: Set<String>? = nil, allowLegacyWithoutCheckpoint: Bool = true,
    requireCompleteSourceBinding: Bool = true) throws {
    func fail() -> MathQuestionStoreError { .database("后台教研报告或恢复点字段、来源或状态不一致") }
    guard JSONSerialization.isValidJSONObject(object), try JSONSerialization.data(withJSONObject: object).count <= 512_000,
      object["native_research"] == nil, object["native_candidate_event"] == nil,
      object["human_decision"] == nil,
      !["approved", "rejected", "revision_required"].contains(object["status"] as? String ?? "") else { throw fail() }
    guard let checkpointValue = object["workflow_state"] else {
      guard allowLegacyWithoutCheckpoint else { throw fail() }
      // A missing checkpoint is historical metadata only; never a portable recovery point.
      return
    }
    let outputFields: Set<String> = ["version", "coverage", "covered_method_ids", "pattern_evidence_ids", "reason", "pattern_key", "proposal", "review", "status", "workflow_state"]
    guard Set(object.keys).subtracting(["native_learning_sources"]) == outputFields,
      MathSkillResearchValidation.integer(object["version"]) == 1,
      let checkpoint = checkpointValue as? [String: Any], Set(checkpoint.keys) == ["version", "state"],
      MathSkillResearchValidation.integer(checkpoint["version"]) == 1,
      try JSONSerialization.data(withJSONObject: checkpoint).count <= 200_000,
      let state = checkpoint["state"] as? [String: Any],
      Set(state.keys) == ["evidence", "existing_patterns", "coverage", "covered_method_ids", "pattern_evidence_ids", "reason", "pattern_key", "proposal", "review", "status", "model_calls"],
      let calls = MathSkillResearchValidation.integer(state["model_calls"]), (0...8).contains(calls),
      let evidence = state["evidence"] as? [[String: Any]], (1...24).contains(evidence.count),
      try JSONSerialization.data(withJSONObject: evidence).count <= 150_000,
      let patterns = state["existing_patterns"] as? [[String: Any]], patterns.count <= 100,
      let coverage = state["coverage"] as? String, ["covered", "uncovered", "uncertain", "non_math"].contains(coverage),
      let status = state["status"] as? String, ["covered", "observing", "awaiting_human"].contains(status),
      let methods = strings(state["covered_method_ids"], maximum: 8, width: 256),
      let matched = strings(state["pattern_evidence_ids"], maximum: 24, width: 128),
      let signature = state["pattern_key"] as? String,
      signature.range(of: "^[a-z][a-z_-]{2,127}$", options: .regularExpression) != nil,
      text(state["reason"], maximum: 2_000) != nil else { throw fail() }
    for key in outputFields.subtracting(["version", "workflow_state"]) {
      guard try equal(state[key], object[key]) else { throw fail() }
    }
    if let allowedMethodIDs, !Set(methods).isSubset(of: allowedMethodIDs) { throw fail() }
    if coverage == "covered" && methods.isEmpty { throw fail() }
    var evidenceIDs = Set<String>()
    for entry in evidence {
      guard Set(entry.keys) == ["question_id", "text", "answer", "reference_answer", "verification", "role", "grade", "user_constraint"],
        let id = text(entry["question_id"], maximum: 128), evidenceIDs.insert(id).inserted,
        ["text", "answer", "reference_answer"].allSatisfy({ string(entry[$0], maximum: 6_000) != nil }),
        string(entry["user_constraint"], maximum: 2_000) != nil,
        ["unverified", "confirmed", "referenceMatched", "rejected"].contains(entry["verification"] as? String ?? ""),
        ["positive", "excluded"].contains(entry["role"] as? String ?? ""),
        entry["grade"] is NSNull || MathSkillResearchValidation.integer(entry["grade"]).map({ (1...6).contains($0) }) == true else { throw fail() }
    }
    guard Set(matched).isSubset(of: evidenceIDs) else { throw fail() }
    for pattern in patterns {
      guard Set(pattern.keys) == ["signature", "evidence_ids", "status"], text(pattern["signature"], maximum: 256) != nil,
        strings(pattern["evidence_ids"], maximum: 100, width: 128) != nil,
        text(pattern["status"], maximum: 64) != nil else { throw fail() }
    }
    for snapshot in sourceSnapshots {
      guard let source = evidence.first(where: { $0["question_id"] as? String == snapshot.questionID }),
        try equal(source, backgroundEvidence(snapshot)) else { throw fail() }
    }
    if !sourceSnapshots.isEmpty {
      guard evidence.first?["question_id"] as? String == sourceSnapshots.first?.questionID,
        !requireCompleteSourceBinding || Set(sourceSnapshots.map(\.questionID)) == evidenceIDs else { throw fail() }
    }
    switch status {
    case "covered", "observing":
      guard (status == "covered") == (coverage == "covered"),
        calls > 0 || (status == "observing" && coverage == "uncertain"),
        state["proposal"] is NSNull, state["review"] is NSNull else { throw fail() }
    default:
      guard coverage == "uncovered", calls >= 3,
        let proposal = state["proposal"] as? [String: Any],
        let review = state["review"] as? [String: Any],
        try validProposal(proposal, evidence: evidence, matched: Set(matched)),
        validReview(review) else { throw fail() }
      let positives = Set(evidence.filter { $0["role"] as? String == "positive" && matched.contains($0["question_id"] as? String ?? "") }
        .compactMap { $0["text"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { $0.filter { !$0.isWhitespace } })
      guard positives.count >= 3, matched.contains(evidence[0]["question_id"] as? String ?? "") else { throw fail() }
    }
  }

  static func backgroundEvidence(_ snapshot: MathSkillLearningSnapshot) -> [String: Any] {
    let solution = snapshot.solutions.first(where: { $0.verificationStatus == "confirmed" }) ?? snapshot.solutions.last
    let confirmed = solution.flatMap { selected in snapshot.reviews.last { $0.solutionID == selected.id } }
      .map { $0.status == "confirmed" && $0.scope == "答案及解题过程" } ?? false
    return ["question_id": snapshot.questionID, "text": String(snapshot.ocrText.prefix(2_000)),
      "answer": String((solution?.answer ?? "").prefix(2_000)),
      "reference_answer": String((snapshot.references.last?.text ?? "").prefix(500)),
      "verification": confirmed ? "confirmed" : "unverified", "role": "positive",
      "grade": snapshot.grade as Any? ?? NSNull(), "user_constraint": String((solution?.question ?? "").prefix(500))]
  }

  private static func validProposal(_ value: [String: Any], evidence: [[String: Any]], matched: Set<String>) throws -> Bool {
    guard Set(value.keys) == ["title", "category", "instructions", "trigger", "prerequisites", "exclusions", "diagram_templates", "evidence_ids", "review_notes"],
      text(value["title"], maximum: 256) != nil, text(value["category"], maximum: 256) != nil,
      let body = text(value["instructions"], maximum: 12_000), body.count >= 80,
      text(value["trigger"], maximum: 2_000) != nil, text(value["review_notes"], maximum: 2_000) != nil,
      strings(value["prerequisites"], maximum: 16, width: 2_000, nonempty: true) != nil,
      strings(value["exclusions"], maximum: 16, width: 2_000, nonempty: true) != nil,
      let diagrams = strings(value["diagram_templates"], maximum: 16, width: 2_000), diagrams.allSatisfy({ MathDiagram.Kind(rawValue: $0) != nil }),
      let citations = strings(value["evidence_ids"], maximum: 24, width: 128, nonempty: true), citations.count >= 3 else { return false }
    let allowed = Set(evidence.filter { matched.contains($0["question_id"] as? String ?? "") || $0["role"] as? String == "excluded" }.compactMap { $0["question_id"] as? String })
    return Set(citations).isSubset(of: allowed)
  }

  private static func validReview(_ value: [String: Any]) -> Bool {
    guard Set(value.keys) == ["checks", "recommendation"], let checks = value["checks"] as? [[String: Any]], checks.count == 5,
      Set(checks.compactMap { $0["dimension"] as? String }) == dimensions,
      ["ready_for_human", "needs_revision"].contains(value["recommendation"] as? String ?? "") else { return false }
    var allPassed = true
    for check in checks {
      guard Set(check.keys) == ["dimension", "passed", "reason"], let boolean = check["passed"] as? NSNumber,
        CFGetTypeID(boolean) == CFBooleanGetTypeID(), text(check["reason"], maximum: 2_000) != nil else { return false }
      allPassed = allPassed && boolean.boolValue
    }
    return allPassed || value["recommendation"] as? String == "needs_revision"
  }

  private static func text(_ value: Any?, maximum: Int) -> String? {
    guard let value = string(value, maximum: maximum), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }
  private static func string(_ value: Any?, maximum: Int) -> String? {
    guard let value = value as? String, value.count <= maximum else { return nil }; return value
  }
  private static func strings(_ value: Any?, maximum: Int, width: Int, nonempty: Bool = false) -> [String]? {
    guard let array = value as? [String], array.count <= maximum, !nonempty || !array.isEmpty,
      Set(array).count == array.count, array.allSatisfy({ text($0, maximum: width) != nil }) else { return nil }; return array
  }
  private static func equal(_ lhs: Any?, _ rhs: Any?) throws -> Bool {
    guard let lhs, let rhs else { return false }
    return try JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed]) == JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed])
  }
}
