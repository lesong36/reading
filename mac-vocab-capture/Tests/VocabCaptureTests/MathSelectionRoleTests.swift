import CryptoKit
import Foundation
import XCTest
@testable import VocabCapture

final class MathSelectionRoleTests: XCTestCase {
  private func snapshot(_ name: String) throws -> MathTeachingMethod {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == name })
    return .init(id: skill.sourceID, versionID: "role-test-version", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
  }

  private func output(primary: MathTeachingMethod?, visual: [MathTeachingMethod] = [], requireApplicability: Bool = true) throws -> String {
    var object: [String: Any] = ["method_id": primary?.id as Any? ?? NSNull(),
      "visual_method_ids": visual.map(\.id), "reason": "题内条件支持所选方法。"]
    if requireApplicability {
      object["applicability"] = ([primary].compactMap { $0 } + visual).map {
        ["method_id": $0.id, "status": "applicable", "conditions": [
          ["requirement": "题内数量与方法条件相符", "evidence": "本题给出了必要条件", "status": "met"]
        ]] as [String: Any]
      }
    }
    return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
  }

  func testAllBundledProfilesDeclareRolesWithoutHumanApproval() throws {
    let catalogue = try MathTeachingReviewCatalogue.load()
    XCTAssertEqual(catalogue.profiles.count, catalogue.catalogue.skills.count)
    for profile in catalogue.profiles {
      XCTAssertFalse(profile.selection_roles.isEmpty)
      XCTAssertEqual(Set(profile.selection_roles).count, profile.selection_roles.count)
      XCTAssertTrue(profile.selection_roles.allSatisfy { ["solution", "visual", "routing"].contains($0) })
      XCTAssertNotEqual(profile.review_status, "approved")
      let expected = profile.skill_name == "math-diagram-routing" ? "routing"
        : profile.grade_guidance.grade4_policy == "visual_only" ? "visual" : "solution"
      XCTAssertEqual(profile.selection_roles, [expected])
    }
  }

  func testProfileRoleSchemaRejectsOversizedMixedRoutingAndInvalidDeclarations() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/VocabCapture/Resources/MathTeachingReview")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.copyItem(at: source.appendingPathComponent("evaluation-corpus.json"),
      to: directory.appendingPathComponent("evaluation-corpus.json"))
    let data = try Data(contentsOf: source.appendingPathComponent("profiles.json"))
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let catalogue = try MathSkillCatalogue.load()
    for roles in [[String](), ["solution", "visual", "routing"], ["routing", "solution"],
      ["routing", "visual"], ["solution", "solution"], ["unknown"]] {
      var object = original
      var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
      profiles[0]["selection_roles"] = roles
      object["profiles"] = profiles
      try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("profiles.json"))
      XCTAssertThrowsError(try MathTeachingReviewCatalogue(directory: directory, catalogue: catalogue), "\(roles)")
    }
    var object = original
    var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
    profiles[0]["selection_roles"] = ["solution", "visual"]
    object["profiles"] = profiles
    try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("profiles.json"))
    XCTAssertEqual(try MathTeachingReviewCatalogue(directory: directory, catalogue: catalogue).profiles[0].selection_roles,
      ["solution", "visual"])
  }

  func testExactBundledRolesRejectSwapsAndRoutingWithoutRejectingCorrectPair() throws {
    let solution = try snapshot("reverse-operations")
    let visual = try snapshot("inventory-transitions-diagram")
    let routing = try snapshot("math-diagram-routing")
    let methods = [solution, visual, routing]
    let match = try MathMethodMatcher.parse(output(primary: solution, visual: [visual]), methods: methods, requireApplicability: true)
    XCTAssertEqual(match.method, solution)
    XCTAssertEqual(match.visualMethods, [visual])
    XCTAssertThrowsError(try MathMethodMatcher.parse(output(primary: visual, visual: [solution]), methods: methods, requireApplicability: true))
    XCTAssertThrowsError(try MathMethodMatcher.parse(output(primary: nil, visual: [solution]), methods: methods, requireApplicability: true))
    XCTAssertThrowsError(try MathMethodMatcher.parse(output(primary: routing), methods: methods, requireApplicability: true))
    XCTAssertThrowsError(try MathMethodMatcher.parse(output(primary: solution, visual: [routing]), methods: methods, requireApplicability: true))
    XCTAssertEqual(try MathMethodMatcher.parse(output(primary: nil, visual: [visual]), methods: methods, requireApplicability: true).visualMethods, [visual])
  }

  func testLegacyDecodePreservesPriorRoleAssignments() throws {
    let solution = try snapshot("reverse-operations")
    let visual = try snapshot("inventory-transitions-diagram")
    let legacy = try output(primary: visual, visual: [solution], requireApplicability: false)
    let decoded = try MathMethodMatcher.parse(legacy, methods: [solution, visual], requireApplicability: false)
    XCTAssertEqual(decoded.method, visual)
    XCTAssertEqual(decoded.visualMethods, [solution])
    XCTAssertThrowsError(try MathMethodMatcher.parse(legacy, methods: [solution, visual], requireApplicability: true))
  }

  func testEditedBodiesLoseRolesAndCustomMethodsRemainCompatible() throws {
    let original = try snapshot("inventory-transitions-diagram")
    let research = try MathTeachingReviewCatalogue.load()
    for suffix in ["用户修改", "\n"] {
      let edited = MathTeachingMethod(id: original.id, versionID: "edited", title: original.title,
        category: original.category, instructions: original.instructions + suffix, createdAt: Date())
      XCTAssertNil(research.reference(for: edited))
      XCTAssertNil(MathMethodMatcher.selectionRolePolicy(for: edited, catalogue: research))
      XCTAssertEqual(try MathMethodMatcher.parse(output(primary: edited), methods: [edited], requireApplicability: true).method, edited)
    }
    let custom = MathTeachingMethod(id: "custom", versionID: "custom-version", title: "自定义解法",
      category: "数形结合", instructions: "用户提供的完整方法。", createdAt: Date())
    XCTAssertNil(MathMethodMatcher.selectionRolePolicy(for: custom, catalogue: research))
    XCTAssertEqual(try MathMethodMatcher.parse(output(primary: custom), methods: [custom], requireApplicability: true).method, custom)
    XCTAssertEqual(try MathMethodMatcher.parse(output(primary: nil, visual: [custom]), methods: [custom], requireApplicability: true).visualMethods, [custom])
  }

  func testPayloadRoleEnvelopeBindsSnapshotAndIsIndependentOfPermissions() throws {
    let original = try snapshot("inventory-transitions-diagram")
    let declared = MathTeachingMethod(id: original.id, versionID: original.versionID, title: original.title,
      category: original.category, instructions: original.instructions, createdAt: original.createdAt,
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    let edited = MathTeachingMethod(id: original.id, versionID: "edited", title: original.title,
      category: original.category, instructions: original.instructions + "自定义内容", createdAt: Date(),
      teachingPermissions: declared.teachingPermissions)
    let data = try ScreenshotQuestionClient.payload(question: "不用方程", context: .init(text: "题面", selectedWord: nil, imageData: nil),
      history: [], configuration: .init(baseURL: "https://example.com/v1", model: "fixture", apiKey: ""),
      api: .automatic, teachingSkills: [declared, edited])
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try XCTUnwrap(payload["teaching_skills"] as? [[String: String]])
    let raw = try XCTUnwrap(entries[0]["selection_role_policy"])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["method_id", "version_id", "instructions_sha256", "roles"]))
    let policy = try JSONDecoder().decode(MathMethodSelectionRolePolicy.self, from: Data(raw.utf8))
    XCTAssertEqual(policy.method_id, declared.id)
    XCTAssertEqual(policy.version_id, declared.versionID)
    XCTAssertEqual(policy.instructions_sha256, SHA256.hash(data: Data(declared.instructions.utf8)).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(policy.roles, ["visual"])
    XCTAssertEqual(policy, MathMethodMatcher.selectionRolePolicy(for: original))
    XCTAssertNotNil(entries[0]["teaching_policy"])
    XCTAssertNotNil(entries[1]["teaching_policy"])
    XCTAssertNil(entries[1]["selection_role_policy"])
  }
}
