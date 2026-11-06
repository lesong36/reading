import CoreFoundation
import CryptoKit
import Foundation

/// The AI receives immutable source and evidence snapshots, never a permission to approve.
struct MathSkillProfileResearchAttempt: Codable, Sendable, Equatable {
  struct Evidence: Codable, Sendable, Equatable {
    let questionID: String
    let text: String
    let answer: String
    let referenceAnswer: String
    let verification: String
    let role: String
    let grade: Int?
    let userConstraint: String
    let provenance: String
    var object: [String: Any] {
      ["question_id": questionID, "text": text, "answer": answer, "reference_answer": referenceAnswer,
        "verification": verification, "role": role, "grade": grade as Any? ?? NSNull(), "user_constraint": userConstraint]
    }
  }
  struct Source: Codable, Sendable, Equatable {
    let locator: String
    let sha256: String
  }
  let method: MathTeachingMethod
  /// Human status is excluded from the content binding; research does not change it.
  let profile: MathSkillProfile
  let evidence: [Evidence]
  let sourceReferences: [Source]
  let questionSnapshots: [MathSkillLearningSnapshot]

  var bindingDigest: String {
    get throws {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      return Self.digest(try encoder.encode(self))
    }
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  var learningObject: [String: Any] {
    get throws {
      ["profile_review": ["method_id": method.id, "version_id": method.versionID, "binding_digest": try bindingDigest,
        "instructions": method.instructions, "trigger": profile.trigger, "constraints": profile.constraints,
        "exclusions": profile.exclusions.components(separatedBy: .newlines).filter { !$0.isEmpty },
        "prerequisites": profile.prerequisites.components(separatedBy: .newlines).filter { !$0.isEmpty },
        "diagram_templates": profile.supportedDiagrams, "evidence": evidence.map(\.object),
        "source_references": sourceReferences.map { ["locator": $0.locator, "sha256": $0.sha256] }]]
    }
  }
}

struct MathSkillProfileResearchResult: Codable, Sendable, Equatable {
  struct Check: Codable, Sendable, Equatable {
    let dimension: String
    let passed: Bool
    let reason: String
  }
  struct Review: Codable, Sendable, Equatable {
    let checks: [Check]
    let recommendation: String
  }
  let version: Int
  let mode: String
  let methodID: String
  let versionID: String
  let bindingDigest: String
  let sourceSHA256: String
  let review: Review
  let status: String
  let modelCalls: Int
  private enum CodingKeys: String, CodingKey {
    case version, mode, review, status
    case methodID = "method_id", versionID = "version_id", bindingDigest = "binding_digest"
    case sourceSHA256 = "source_sha256", modelCalls = "model_calls"
  }
  static let dimensions = ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"]
  static let labels = ["mathematics": "数学正确性", "grade_scope": "学段与教学限制", "conditions": "适用与排除条件",
    "counterexamples": "混淆反例", "diagram_grounding": "图解与数据依据"]

  static func parse(_ text: String, attempt: MathSkillProfileResearchAttempt) throws -> Self {
    guard text.utf8.count <= 240_000,
      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      Set(object.keys) == Set(["version", "mode", "method_id", "version_id", "binding_digest", "source_sha256", "review", "status", "model_calls"]),
      integer(object["version"]), integer(object["model_calls"]),
      let review = object["review"] as? [String: Any], Set(review.keys) == Set(["checks", "recommendation"]),
      let checks = review["checks"] as? [[String: Any]], checks.allSatisfy({ check in
        Set(check.keys) == Set(["dimension", "passed", "reason"]) && (check["passed"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
      })
    else { throw ScreenshotQuestionError.invalidResponse }
    let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    try value.validate(attempt: attempt)
    return value
  }
  private static func integer(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
  }
  func validate(attempt: MathSkillProfileResearchAttempt) throws {
    guard attempt.profile.versionID == attempt.method.versionID, attempt.profile.status == "draft",
      version == 1, mode == "profile_review", methodID == attempt.method.id, versionID == attempt.method.versionID,
      bindingDigest == (try attempt.bindingDigest), sourceSHA256 == MathSkillProfileResearchAttempt.digest(Data(attempt.method.instructions.utf8)),
      [1, 2].contains(modelCalls), review.checks.count == 5, Set(review.checks.map(\.dimension)) == Set(Self.dimensions),
      review.checks.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.reason.utf8.count <= 12_000 }),
      ["ready_for_human", "needs_revision"].contains(review.recommendation),
      (review.checks.allSatisfy(\.passed) || review.recommendation == "needs_revision"),
      status == (review.recommendation == "ready_for_human" ? "awaiting_human" : "review_required"),
      !(attempt.evidence.isEmpty && review.checks.contains { $0.dimension == "mathematics" && $0.passed }),
      !(!attempt.evidence.contains { $0.role == "excluded" } && review.checks.contains { $0.dimension == "counterexamples" && $0.passed }),
      !((attempt.profile.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attempt.profile.exclusions.isEmpty)
        && review.checks.contains { $0.dimension == "conditions" && $0.passed })
    else { throw ScreenshotQuestionError.invalidResponse }
  }
  var summary: String {
    Self.dimensions.compactMap { dimension in
      review.checks.first { $0.dimension == dimension }.map { "\(Self.labels[dimension] ?? dimension)：\($0.passed ? "AI 评估通过" : "需补充或修订")\n\($0.reason)" }
    }.joined(separator: "\n\n") + "\n\n" + (status == "awaiting_human" ? "评估已完成，等待用户审校；尚未批准。" : "评估发现缺口，需补充后重新审校。")
  }
}

/// This archive travels with existing lifecycle history and keeps old reports readable.
struct MathSkillProfileResearchArchive: Codable, Sendable, Equatable {
  let version: Int
  let model: String
  let attempt: MathSkillProfileResearchAttempt
  let result: MathSkillProfileResearchResult
}

@MainActor
final class MathSkillProfileResearchCoordinator {
  typealias Analyze = MathSkillLearningCoordinator.Analyze
  typealias Research = @MainActor (MathTeachingMethod) async throws -> Void
  private let store: MathQuestionStore
  private let configuration: () -> MathTagModelConfiguration
  private let analyze: Analyze
  private var generation = UUID()
  private var suspended = false

  init(store: MathQuestionStore, configuration: @escaping () -> MathTagModelConfiguration, analyze: @escaping Analyze) {
    self.store = store; self.configuration = configuration; self.analyze = analyze
  }
  func review(method: MathTeachingMethod) async throws {
    try Task.checkCancellation()
    guard !suspended else { throw CancellationError() }
    let epoch = generation
    let model = configuration()
    guard model.configuration.isComplete else { throw ScreenshotQuestionError.invalidConfiguration }
    let attempt = try await store.profileResearchAttempt(method: method)
    var learning = try attempt.learningObject
    var originals: [[String: String]] = []
    var size = 0
    for snapshot in attempt.questionSnapshots {
      try Task.checkCancellation()
      let image = try await store.originalImage(questionID: snapshot.questionID)
      size += image.count
      guard size <= 20 * 1024 * 1024 else { throw MathQuestionStoreError.database("本次教研原图超过 20 MB，请减少关联题目") }
      originals.append(["question_id": snapshot.questionID, "image_data": image.base64EncodedString()])
    }
    if !originals.isEmpty { learning["originals"] = originals }
    let input = try JSONSerialization.data(withJSONObject: learning, options: .sortedKeys)
    try Task.checkCancellation()
    let output = try await analyze(input, Data(), [method], model)
    try Task.checkCancellation()
    guard !suspended, generation == epoch else { throw CancellationError() }
    try await store.recordProfileResearch(attempt: attempt, report: output, model: model.configuration.model)
  }
  func suspendForLibraryRestore() { suspended = true; generation = UUID() }
  func resumeAfterLibraryRestore() { suspended = false; generation = UUID() }
}
