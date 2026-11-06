import Foundation

/// All review decisions belong to one immutable method version. AI reports never approve it.
struct MathSkillProfile: Codable, Sendable, Equatable {
  let versionID: String
  var trigger: String
  var constraints: String
  var exclusions: String
  var prerequisites: String
  var supportedDiagrams: [String]
  var status: String = "draft"
  var sourceInstructions: String? = nil
  var teachingPermissions: MathTeachingPermissions? = nil
}

/// Structural identity excludes title; repeated observations merge by signature.
struct MathSkillProposal: Codable, Sendable, Equatable {
  var signature: String
  var title: String
  var category: String
  var instructions: String
  var trigger: String
  var constraints: String
  var exclusions: String
  var prerequisites: String
  var supportedDiagrams: [String]
  var teachingPermissions: MathTeachingPermissions? = nil
}

struct MathSkillCandidate: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let proposal: MathSkillProposal
  let revision: Int
  let status: String
  let publishedVersionID: String?
  let createdAt: Date
  let updatedAt: Date
}

struct MathSkillLearningSnapshot: Codable, Sendable, Equatable {
  var grade: Int? = nil
  let questionID: String
  let assetID: String
  let ocrText: String
  let solutions: [MathQuestionSolution]
  let references: [MathReferenceAnswer]
  let reviews: [MathSolutionReview]

  /// Only the latest full-process decision for this answer can supply a reviewed correction.
  /// A later rejection or answer-only review must not reuse an older confirmation.
  func confirmedProcessReview(for solution: MathQuestionSolution) -> MathSolutionReview? {
    guard solution.verificationStatus == "confirmed",
      let review = reviews.last(where: { $0.solutionID == solution.id }),
      review.status == "confirmed", review.scope == "答案及解题过程" else { return nil }
    return review
  }

  func learningAnswer(for solution: MathQuestionSolution, review: MathSolutionReview?) -> String {
    guard let review, review == confirmedProcessReview(for: solution),
      !review.correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return solution.answer }
    return review.correction
  }
}

struct MathSkillLearningAttempt: Sendable, Equatable {
  let questionID: String
  let token: String
  let snapshot: MathSkillLearningSnapshot
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.questionID == rhs.questionID && lhs.token == rhs.token }
}

struct MathSkillLearningJob: Sendable, Equatable {
  let questionID: String
  let status: String
  let error: String
  let updatedAt: Date
}

/// AI observations and explicit human boundary assessments are append-only, revision-bound.
struct MathSkillCandidateEvidence: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let candidateID: String
  let candidateRevision: Int
  let questionID: String
  let assetID: String
  let contentDigest: String
  let solutionID: String?
  let reviewID: String?
  let referenceID: String?
  let boundary: String
  let origin: String
  let note: String
  let snapshot: MathSkillLearningSnapshot
  let createdAt: Date
}

struct MathSkillLearningReport: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let questionID: String
  let token: String
  let model: String
  let report: String
  let snapshot: MathSkillLearningSnapshot
  let createdAt: Date
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The complete proposal and current human evidence bind each research result.
struct MathSkillResearchAttempt: Codable, Sendable, Equatable {
  let candidateID: String
  let revision: Int
  let proposal: MathSkillProposal
  let evidence: [MathSkillCandidateEvidence]

  var learningObject: [String: Any] {
    let sources = evidence.map { entry -> [String: Any] in
      let solution = entry.snapshot.solutions.first { $0.id == entry.solutionID }
      let review = solution.flatMap { entry.snapshot.confirmedProcessReview(for: $0) }
        .flatMap { $0.id == entry.reviewID ? $0 : nil }
      let answer = solution.map { entry.snapshot.learningAnswer(for: $0, review: review) } ?? ""
      return ["question_id": entry.questionID, "text": String(entry.snapshot.ocrText.prefix(2_000)),
        "answer": String(answer.prefix(2_000)),
        "reference_answer": String((entry.snapshot.references.first { $0.id == entry.referenceID }?.text ?? "").prefix(500)),
        "verification": review == nil ? "unverified" : "confirmed", "role": entry.boundary == "excluded" ? "excluded" : "positive",
        "grade": entry.snapshot.grade as Any? ?? NSNull(), "user_constraint": String((solution?.question ?? "").prefix(500))]
    }
    return ["evidence": sources, "candidate": ["pattern_key": proposal.signature, "proposal": [
      "title": proposal.title, "category": proposal.category, "instructions": proposal.instructions,
      "trigger": proposal.trigger, "prerequisites": proposal.prerequisites.components(separatedBy: .newlines).filter { !$0.isEmpty },
      "exclusions": proposal.exclusions.components(separatedBy: .newlines).filter { !$0.isEmpty },
      "diagram_templates": proposal.supportedDiagrams, "evidence_ids": evidence.map(\.questionID),
      "review_notes": (proposal.constraints.isEmpty ? "需人工核对适用条件与教学步骤" : proposal.constraints)
        + (proposal.teachingPermissions.map { "\n用户声明的结构化教学权限（须审查）：\($0.summary)" } ?? "")]]]
  }
}

struct MathSkillLifecycleEvent: Sendable, Equatable {
  let id: String
  let decision: String
  let note: String
  let createdAt: Date
}
