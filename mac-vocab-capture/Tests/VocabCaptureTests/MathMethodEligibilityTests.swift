import Foundation
import XCTest
@testable import VocabCapture

final class MathMethodEligibilityTests: XCTestCase {
  private func method(_ skill:MathSkillDefinition) -> MathTeachingMethod {
    .init(id:skill.sourceID,versionID:"snapshot-version",title:skill.title,category:skill.category,
      instructions:skill.instructions,createdAt:Date())
  }
  func testExplicitNoEquationUsesExactSkillsAndPreservesArithmeticAlternatives() throws {
    let catalogue=try MathTeachingReviewCatalogue.load()
    let equation=method(try XCTUnwrap(catalogue.catalogue.skills.first { $0.name=="equations-and-elimination" }))
    let arithmetic=method(try XCTUnwrap(catalogue.catalogue.skills.first { $0.name=="equal-quantity-substitution" }))
    let methods=[equation,arithmetic]
    XCTAssertEqual(MathMethodMatcher.eligibleMethods(methods,question:"四年级，不要使用方程，请解释并验算",catalogue:catalogue),[arithmetic])
    XCTAssertEqual(MathMethodMatcher.eligibleMethods(methods,question:"允许使用方程与消去法，须回代验算",catalogue:catalogue),methods)
    XCTAssertEqual(MathMethodMatcher.eligibleMethods(methods,question:"四年级，直接解题",catalogue:catalogue),[arithmetic])
    XCTAssertEqual(equation.instructions,catalogue.catalogue.skills.first { $0.name=="equations-and-elimination" }?.instructions)
  }
  func testLocalEditsDoNotInheritOldEligibilityOrKeywordMisclassification() throws {
    let catalogue=try MathTeachingReviewCatalogue.load()
    let original=method(try XCTUnwrap(catalogue.catalogue.skills.first { $0.name=="equations-and-elimination" }))
    let edited=MathTeachingMethod(id:original.id,versionID:"edited",title:original.title,category:original.category,
      instructions:"只用算术消去共享量。不使用方程，不适用于变化率不确定的题目。",createdAt:Date())
    XCTAssertEqual(MathMethodMatcher.eligibilityPolicy(for:edited,catalogue:catalogue)?.source, "unknown")
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([edited],question:"不要使用方程",catalogue:catalogue).isEmpty)
    let declared = MathTeachingMethod(id: edited.id, versionID: "new-human-declaration", title: edited.title,
      category: edited.category, instructions: edited.instructions, createdAt: Date(),
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    XCTAssertEqual(MathMethodMatcher.eligibleMethods([declared],question:"不要使用方程",catalogue:catalogue),[declared])
  }
  func testGradeScopeRequiresSpecificPermissionAndFinalPreferenceWins() throws {
    let catalogue=try MathTeachingReviewCatalogue.load()
    let entry=try XCTUnwrap(catalogue.profiles.first { $0.grade_guidance.grade4_policy=="extension_requires_permission" })
    let advanced=method(try XCTUnwrap(catalogue.catalogue.skills.first { $0.name==entry.skill_name }))
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([advanced],question:"四年级；用小学知识解题",catalogue:catalogue).isEmpty)
    XCTAssertEqual(MathMethodMatcher.eligibleMethods([advanced],question:"四年级；允许使用拓展知识",catalogue:catalogue),[advanced])
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([advanced],question:"四年级；允许拓展知识。现在不要使用拓展方法",catalogue:catalogue).isEmpty)
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([advanced],question:"四年级；允许使用方程",catalogue:catalogue).isEmpty,"Equation permission is not permission for every advanced method")
    XCTAssertEqual(MathMethodMatcher.userConstraints("不用方程。改用方程").equations,true)
    XCTAssertEqual(MathMethodMatcher.userConstraints("允许使用方程。不要使用方程").equations,false)
    XCTAssertEqual(MathMethodMatcher.userConstraints("允许使用方程。现在不允许使用方程").equations,false)
    XCTAssertEqual(MathMethodMatcher.userConstraints("grade 3, no equations").grade,3)
    XCTAssertEqual(MathMethodMatcher.userConstraints("grade 3, no equations").equations,false)
  }
  func testTransportPolicyBindsCompleteSnapshotAndLeavesEnglishUnchanged() throws {
    let skill=try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name=="equations-and-elimination" })
    let snapshot=method(skill)
    let config=AIConfiguration(baseURL:"https://example.com/v1",model:"fixture",apiKey:"test-only")
    let bytes=try ScreenshotQuestionClient.payload(question:"不要使用方程",context:.init(text:"原题",selectedWord:nil,imageData:nil),history:[],configuration:config,api:.automatic,teachingSkills:[snapshot])
    let payload=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
    let entry=(payload["teaching_skills"] as! [[String:String]])[0]
    let policy=try JSONDecoder().decode(MathMethodEligibilityPolicy.self,from:Data(try XCTUnwrap(entry["teaching_policy"]).utf8))
    XCTAssertEqual(policy.method_id,snapshot.id); XCTAssertEqual(policy.version_id,snapshot.versionID)
    XCTAssertEqual(policy.skill_sha256,skill.sha256); XCTAssertEqual(policy.equation_policy,"explicit_permission")
    let normal=try ScreenshotQuestionClient.payload(question:"Explain this",context:.init(text:"English text",selectedWord:nil,imageData:nil),history:[],configuration:config,api:.automatic)
    XCTAssertNil((try JSONSerialization.jsonObject(with:normal) as! [String:Any])["teaching_skills"])
  }
}
