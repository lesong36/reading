import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathSkillCandidatePermissionUITests: XCTestCase {
  private let complete = MathTeachingPermissions(minimumGrade: 4,
    equationRequirement: .notRequired, extensionRequirement: .none)

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func settle(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Candidate permission UI did not settle")
  }

  private func withCandidate(
    permissions: MathTeachingPermissions?,
    research: @escaping @MainActor (String, Bool, String) async throws -> Void,
    body: (MathQuestionStore, MathSkillReviewPanel, [NSView]) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-permission-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let question = try await store.save(.init(captureID: "permission-fixture",
      imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.area), ocrText: "原题"))
    let proposal = MathSkillProposal(signature: "shared-gap-invariant", title: "权限候选",
      category: "四年级", instructions: "比较数量关系，再独立验算", trigger: "条件明确",
      constraints: "原图为准", exclusions: "缺条件不适用", prerequisites: "四则运算",
      supportedDiagrams: ["table"], teachingPermissions: permissions)
    try await store.enqueueSkillLearning(questionID: question.id)
    let claimed = try await store.claimSkillLearning(questionID: question.id)
    let attempt = try XCTUnwrap(claimed)
    try await store.finishSkillLearning(attempt: attempt, proposal: proposal, report: "{}", model: "fixture")
    let panel = MathSkillReviewPanel(store: store, openQuestion: { _ in }, research: research)
    let views = descendants(try XCTUnwrap(panel.panel.contentView))
    try button("刷新", in: views).performClick(nil)
    let name = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "方法名称" })
    try await settle { name.stringValue == proposal.title }
    do {
      try await body(store, panel, views)
      await panel.prepareForLibraryRestore()
      await store.close()
    } catch {
      await panel.prepareForLibraryRestore()
      await store.close()
      throw error
    }
  }

  private func button(_ title: String, in views: [NSView]) throws -> NSButton {
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title })
  }

  private func popup(_ label: String, in views: [NSView]) throws -> NSPopUpButton {
    try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label })
  }

  private func message(in views: [NSView]) throws -> NSTextField {
    try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "候选操作说明" })
  }

  func testMissingOrPartialSavedPermissionsBlockAutomaticApprovalWithoutBlockingReview() async throws {
    let incomplete: [MathTeachingPermissions?] = [nil,
      .init(minimumGrade: nil, equationRequirement: .notRequired, extensionRequirement: .none),
      .init(minimumGrade: 4, equationRequirement: .unknown, extensionRequirement: .none),
      .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .unknown)]
    for permissions in incomplete {
      var calls: [Bool] = []
      try await withCandidate(permissions: permissions, research: { _, approve, _ in calls.append(approve) }) { store, _, views in
        try button("批准并用于自动解题", in: views).performClick(nil)
        XCTAssertTrue(calls.isEmpty)
        let guidance = try message(in: views).stringValue
        XCTAssertTrue(guidance.contains("最低适用年级"))
        XCTAssertTrue(guidance.contains("方程要求"))
        XCTAssertTrue(guidance.contains("拓展许可"))
        XCTAssertTrue(guidance.contains("保存候选修改"))
        try button("教研审校", in: views).performClick(nil)
        try await settle { calls == [false] }
        let saved = try await store.listSkillCandidates()
        XCTAssertEqual(saved.first?.revision, 1)
        XCTAssertEqual(saved.first?.proposal.teachingPermissions, permissions)
      }
    }
  }

  func testCompleteSavedPermissionsReachHumanApprovalCallback() async throws {
    var calls: [Bool] = []
    try await withCandidate(permissions: complete, research: { _, approve, _ in calls.append(approve) }) { _, _, views in
      try button("批准并用于自动解题", in: views).performClick(nil)
      try await settle { calls == [true] }
    }
  }

  func testNewPermissionDeclarationsMustBeSavedAsNewRevisionBeforeApproval() async throws {
    var approvals = 0
    try await withCandidate(permissions: nil, research: { _, approve, _ in if approve { approvals += 1 } }) { store, _, views in
      try popup("方法最低适用年级", in: views).selectItem(at: 4)
      try popup("方法方程权限", in: views).selectItem(at: 1)
      try popup("方法拓展许可", in: views).selectItem(at: 1)
      let publish = try button("批准并用于自动解题", in: views)
      publish.performClick(nil)
      XCTAssertEqual(approvals, 0)
      XCTAssertTrue(try message(in: views).stringValue.contains("未保存修改"))
      let before = try await store.listSkillCandidates()
      XCTAssertNil(before.first?.proposal.teachingPermissions)
      try button("保存候选修改", in: views).performClick(nil)
      try await settle { try await store.listSkillCandidates().first?.revision == 2 && publish.isEnabled }
      // Refresh is asynchronous: wait until the loaded revision matches the saved candidate.
      try await settle { try message(in: views).stringValue.contains("版本 2") }
      let saved = try await store.listSkillCandidates()
      XCTAssertEqual(saved.first?.proposal.teachingPermissions, complete)
      publish.performClick(nil)
      try await settle { approvals == 1 }
    }
  }

  func testUnsavedChangesToEachPermissionOrInstructionsNeverApproveSavedRevision() async throws {
    var approvals = 0
    try await withCandidate(permissions: complete, research: { _, approve, _ in if approve { approvals += 1 } }) { store, _, views in
      let publish = try button("批准并用于自动解题", in: views)
      for (label, savedIndex, editedIndex) in [("方法最低适用年级", 4, 5), ("方法方程权限", 1, 2), ("方法拓展许可", 1, 2)] {
        let control = try popup(label, in: views)
        control.selectItem(at: editedIndex)
        publish.performClick(nil)
        XCTAssertEqual(approvals, 0)
        XCTAssertTrue(try message(in: views).stringValue.contains("未保存修改"))
        control.selectItem(at: savedIndex)
      }
      let instructions = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "候选方法步骤" })
      instructions.string += "\n新增不同的解题步骤"
      publish.performClick(nil)
      XCTAssertEqual(approvals, 0)
      let saved = try await store.listSkillCandidates()
      XCTAssertEqual(saved.first?.revision, 1)
      XCTAssertEqual(saved.first?.proposal.teachingPermissions, complete)
      XCTAssertEqual(saved.first?.proposal.instructions, "比较数量关系，再独立验算")
    }
  }

  func testStalePanelDoesNotApproveCandidateChangedInDatabase() async throws {
    var approvals = 0
    try await withCandidate(permissions: complete, research: { _, approve, _ in if approve { approvals += 1 } }) { store, _, views in
      let candidates = try await store.listSkillCandidates()
      let saved = try XCTUnwrap(candidates.first)
      var revised = saved.proposal
      revised.teachingPermissions = .init(minimumGrade: 5, equationRequirement: .required, extensionRequirement: .explicitPermission)
      try await store.editSkillCandidate(id: saved.id, proposal: revised)
      try button("批准并用于自动解题", in: views).performClick(nil)
      try await settle { try message(in: views).stringValue.contains("候选版本已更新") }
      XCTAssertEqual(approvals, 0)
      let current = try await store.listSkillCandidates()
      XCTAssertEqual(current.first?.revision, 2)
      XCTAssertEqual(current.first?.proposal.teachingPermissions, revised.teachingPermissions)
    }
  }
}
