import Foundation

/// Provenance of a historical reference, never an approval of a new solution or skill.
struct MathReviewedExampleReference: Codable, Sendable, Equatable {
  let questionID: String
  let solutionID: String
  let reviewID: String
  let scope: String
  let title: String

  var displayLabel: String {
    "本次提供的历史参考：\(title)（已确认：\(scope)"
      + (scope == "答案及解题过程" ? "）" : "；过程未确认）")
  }

  var isValid: Bool {
    [questionID, solutionID, reviewID].allSatisfy { !$0.isEmpty && $0.count <= 128 }
      && ["最终答案", "答案及解题过程"].contains(scope)
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 256
  }
}

struct MathReviewedExample: Sendable {
  let reference: MathReviewedExampleReference
  let text: String
  let answer: String
  let imageData: Data

  /// A bounded rollout, not a claim that other models cannot solve maths.
  /// The Sonnet probe answered the historical image as another current problem;
  /// do not automatically send that extra image to unvalidated configurations.
  static func supportsAutomaticUse(configuration: AIConfiguration, api: ScreenshotQuestionAPI) -> Bool {
    guard configuration.model == "deepseek-flash", api.resolved(for: configuration) == .chatCompletions,
      let endpoint = try? api.endpoint(for: configuration) else { return false }
    return endpoint.scheme == "https" && endpoint.host == "api.deepseek.com"
      && endpoint.port == nil && endpoint.path == "/chat/completions"
  }

  /// Retrieval evidence only: neither these tokens nor their score grant applicability.
  static func relevance(query: String, source: String) -> Int? {
    let queryTokens = MathLocalSkillRetrieval.tokens(query, stripInstructionWords: true)
    let sourceTokens = MathLocalSkillRetrieval.tokens(source, stripInstructionWords: true)
    let relations = queryTokens.filter { $0.hasPrefix("relation:") }
    let sourceRelations = sourceTokens.filter { $0.hasPrefix("relation:") }
    if relations.count >= 2 {
      guard relations.isSubset(of: sourceRelations) else { return nil }
      return 100 + queryTokens.intersection(sourceTokens).count
    }
    let generic: Set<String> = ["乘法", "整数", "原来", "原数", "得数", "结果", "算式", "计算", "多少", "求原", "数字", "一个", "正确", "答案", "解题"]
    let queryWords = queryTokens.filter { !$0.hasPrefix("relation:") && !generic.contains($0) }
    let sourceWords = sourceTokens.filter { !$0.hasPrefix("relation:") && !generic.contains($0) }
    let overlap = queryWords.intersection(sourceWords)
    guard overlap.count >= 3, Double(overlap.count) / Double(max(1, queryWords.count)) >= 0.3 else { return nil }
    return overlap.count
  }
}
