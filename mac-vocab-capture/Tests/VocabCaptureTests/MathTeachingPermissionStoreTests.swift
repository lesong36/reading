import AppKit
import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class MathTeachingPermissionStoreTests: XCTestCase {
  func testPermissionChangesRequireNewVersionAndDoNotInheritApproval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-version-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let permission = MathTeachingPermissions(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none)
    let first = try await store.saveMethod(title: "按份数比较", category: "用户方法", instructions: "算术比较", teachingPermissions: permission)
    try await store.reviewCurrentSkillProfile(method: first, approved: true, note: "隔离fixture")
    let before = try await store.automaticMethods()
    XCTAssertEqual(MathMethodMatcher.eligibleMethods(before, question: "四年级不用方程"), [first])
    let nextPermission = MathTeachingPermissions(minimumGrade: 5, equationRequirement: .required, extensionRequirement: .explicitPermission)
    let next = try await store.saveMethod(id: first.id, title: first.title, category: first.category, instructions: first.instructions, teachingPermissions: nextPermission)
    XCTAssertNotEqual(next.versionID, first.versionID)
    let after = try await store.automaticMethods()
    XCTAssertTrue(after.isEmpty)
    let oldProfile = try await store.skillProfile(versionID: first.versionID)
    let newProfile = try await store.skillProfile(versionID: next.versionID)
    XCTAssertEqual(oldProfile?.status, "approved"); XCTAssertEqual(newProfile?.status, "draft")
    XCTAssertEqual(oldProfile?.teachingPermissions, permission)
    XCTAssertEqual(newProfile?.teachingPermissions, nextPermission)
    try await store.reviewCurrentSkillProfile(method: next, approved: true, note: "隔离fixture重新核对")
    XCTAssertTrue(MathMethodMatcher.eligibleMethods([next], question: "四年级不用方程").isEmpty)
    XCTAssertEqual(MathMethodMatcher.eligibleMethods([next], question: "五年级允许方程，允许拓展"), [next])
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup); await store.close()
    let restored = MathQuestionStore(directory: root.appendingPathComponent("restored"))
    _ = try await restored.restoreBackup(from: backup)
    let restoredMethods = try await restored.methods()
    XCTAssertEqual(restoredMethods, [next])
    await restored.close()
  }
  func testPermissionDecoderRejectsInvalidValuesAndPreservesUnknown() throws {
    for text in [
      #"{"minimumGrade":99,"equationRequirement":"notRequired","extensionRequirement":"none"}"#,
      #"{"minimumGrade":true,"equationRequirement":"notRequired","extensionRequirement":"none"}"#,
      #"{"minimumGrade":4,"equationRequirement":"none","extensionRequirement":"none"}"#,
      #"{"minimumGrade":4,"equationRequirement":"notRequired","extensionRequirement":"none","aiApproved":true}"#,
      #"{"minimumGrade":4,"equationRequirement":"notRequired"}"#
    ] { XCTAssertThrowsError(try JSONDecoder().decode(MathTeachingPermissions.self, from: Data(text.utf8)), text) }
    let unknown = try JSONDecoder().decode(MathTeachingPermissions.self,
      from: Data(#"{"equationRequirement":"unknown","extensionRequirement":"unknown"}"#.utf8))
    XCTAssertFalse(unknown.isComplete)
    let editor = MathTeachingPermissionEditor()
    editor.load(.init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    XCTAssertEqual(editor.extensionPermission.indexOfSelectedItem, 1)
    XCTAssertEqual(editor.optionalValue?.extensionRequirement, MathTeachingPermissions.Extension.none)
  }
}
