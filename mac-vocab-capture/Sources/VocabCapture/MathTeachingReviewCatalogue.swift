import Foundation

/// Bundled research is source-bound reference material, never a human approval.
struct MathTeachingReviewCatalogue: Sendable {
  struct Profile: Decodable, Sendable {
    struct Grade: Decodable, Sendable {
      let minimum_grade: Int?
      let grade4_policy: String
      let authority: String
    }
    struct Source: Decodable, Sendable {
      let kind: String
      let locator: String
      let sha256: String
    }
    let skill_name: String
    let skill_version: String
    let skill_sha256: String
    let selection_roles: [String]
    let review_status: String
    let grade_guidance: Grade
    let prerequisites: [String]
    let applicable_when: [String]
    let exclusions: [String]
    let source_references: [Source]
    let evidence_case_ids: [String]
    let limitations: [String]
  }
  struct Case: Decodable, Sendable {
    let id: String
    let kind: String
    let stem: String
    let grade: Int?
    let user_constraint: String
    let expected_methods: [String]
    let expected_visuals: [String]
    let forbidden_methods: [String]
  }
  private struct Profiles: Decodable {
    let schema_version: Int
    let approval_policy: String
    let profiles: [Profile]
  }
  private struct Corpus: Decodable {
    let schema_version: Int
    let cases: [Case]
  }
  let profiles: [Profile]
  let cases: [Case]
  let catalogue: MathSkillCatalogue

  static func load() throws -> Self {
    var directory = Bundle.main.url(forResource: "MathTeachingReview", withExtension: nil)
    #if SWIFT_PACKAGE
      if directory == nil { directory = Bundle.module.url(forResource: "MathTeachingReview", withExtension: nil) }
    #endif
    guard let directory else { throw MathQuestionStoreError.database("教研资料缺失，请重新安装应用") }
    return try Self(directory: directory, catalogue: MathSkillCatalogue.load())
  }

  init(directory: URL, catalogue: MathSkillCatalogue) throws {
    let profiles = try JSONDecoder().decode(Profiles.self, from: Data(contentsOf: directory.appendingPathComponent("profiles.json")))
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: directory.appendingPathComponent("evaluation-corpus.json")))
    guard profiles.schema_version == 1, corpus.schema_version == 1,
      profiles.approval_policy == "human_review_only",
      profiles.profiles.count == catalogue.skills.count,
      Set(profiles.profiles.map(\.skill_name)).count == profiles.profiles.count,
      Set(corpus.cases.map(\.id)).count == corpus.cases.count
    else { throw MathQuestionStoreError.database("教研资料目录格式不一致") }
    for profile in profiles.profiles {
      guard let skill = catalogue.skills.first(where: { $0.name == profile.skill_name }),
        skill.version == profile.skill_version, skill.sha256 == profile.skill_sha256,
        ["unreviewed", "review_required", "regression_checked"].contains(profile.review_status),
        (1...2).contains(profile.selection_roles.count),
        !profile.selection_roles.contains("routing") || profile.selection_roles == ["routing"],
        Set(profile.selection_roles).count == profile.selection_roles.count,
        profile.selection_roles.allSatisfy({ ["solution", "visual", "routing"].contains($0) }),
        !profile.applicable_when.isEmpty, !profile.exclusions.isEmpty,
        profile.evidence_case_ids.allSatisfy({ id in corpus.cases.contains { $0.id == id } })
      else { throw MathQuestionStoreError.database("教研资料与技能版本不一致：\(profile.skill_name)") }
    }
    self.profiles = profiles.profiles
    cases = corpus.cases
    self.catalogue = catalogue
  }

  func reference(for method: MathTeachingMethod) -> Profile? {
    guard let metadata = catalogue.discoveryMetadata(for: method),
      let skill = catalogue.skills.first(where: { $0.name == metadata.name }),
      skill.instructions == method.instructions else { return nil }
    return profiles.first { $0.skill_name == metadata.name }
  }

  func seed(for method: MathTeachingMethod) -> MathSkillProfile? {
    guard let reference = reference(for: method) else { return nil }
    let policy: String
    switch reference.grade_guidance.grade4_policy {
    case "arithmetic_only": policy = "四年级优先使用算术，不使用方程。"
    case "extension_requires_permission": policy = "超出四年级常规范围，使用前需用户明确允许拓展。"
    case "visual_only": policy = "只提供图解辅助，须配合主解法。"
    default: policy = "需结合题目与用户要求确认学段。"
    }
    return .init(versionID: method.versionID,
      trigger: reference.applicable_when.joined(separator: "\n"),
      constraints: ([policy, reference.grade_guidance.authority] + reference.limitations).joined(separator: "\n"),
      exclusions: reference.exclusions.joined(separator: "\n"),
      prerequisites: reference.prerequisites.joined(separator: "\n"), supportedDiagrams: [],
      sourceInstructions: method.instructions)
  }

  func evidenceText(for method: MathTeachingMethod) -> String {
    guard let reference = reference(for: method) else {
      return "自定义或已修改的方法：请自行补充适用正例、排除反例、教学步骤和参考来源。"
    }
    let sources = reference.source_references.map { "来源：\($0.locator)\n摘要：\($0.sha256)" }
    let labels = ["positive": "适用正例", "confusing_negative": "混淆反例", "source_example": "宝典来源例题", "source_quarantine": "来源有疑义，不能作为认证依据"]
    let examples = cases.filter { reference.evidence_case_ids.contains($0.id) }.map {
      "[\(labels[$0.kind] ?? "待审案例")] \($0.id)\n\($0.stem)\n教学要求：\($0.user_constraint)"
    }
    return (["以下是版本 \(reference.skill_version) 的待审资料。有限测试通过不代表人工认证。"] + sources + examples).joined(separator: "\n\n")
  }
}
