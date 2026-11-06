import Foundation

/// Read-only source package. Loading it never records a human decision.
struct MathSkillEvidenceReviewPackage: Sendable, Equatable {
  let candidate: MathSkillCandidate
  var sources: [MathSkillLearningSnapshot]
}

struct MathSkillEvidenceReviewItem: Sendable, Equatable {
  let questionID: String
  let boundary: String
  let answerStatus: String
  let correction: String

  init(questionID: String, boundary: String, answerStatus: String = "", correction: String = "") {
    self.questionID = questionID; self.boundary = boundary
    self.answerStatus = answerStatus; self.correction = correction
  }
}
