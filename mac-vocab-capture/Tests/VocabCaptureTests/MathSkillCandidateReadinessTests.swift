import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathSkillCandidateReadinessTests: XCTestCase {
  private func fixture(_ body: (MathQuestionStore, MathSkillCandidate, [MathQuestionRecord]) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-readiness-\(UUID().uuidString)")
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    var records: [MathQuestionRecord] = []
    for (index, diagram) in [MathDiagramFixtures.bar, MathDiagramFixtures.area, MathDiagramFixtures.state].enumerated() {
      records.append(try await store.save(.init(captureID: "readiness-\(index)",
        imageData: MathDiagramRenderer.renderPNG(diagram), ocrText: "独立题文\(index)",
        solutions: [.init(id: "solution-\(index)", question: "核对", answer: "完整步骤\(index)", model: "fixture")])))
    }
    let proposal = MathSkillProposal(signature: "shared-comparison-structure", title: "待核验方法",
      category: "四年级", instructions: "对照原题，比较数量关系，再验算全部条件", trigger: "相同完整数量关系",
      constraints: "不使用方程", exclusions: "必要条件不同不适用", prerequisites: "整数运算", supportedDiagrams: ["table"])
    try await store.enqueueSkillLearning(questionID: records[0].id)
    let claim = try await store.claimSkillLearning(questionID: records[0].id)
    try await store.finishSkillLearning(attempt: XCTUnwrap(claim), proposal: proposal, report: "{}", model: "fixture")
    let candidates = try await store.listSkillCandidates()
    let candidate = try XCTUnwrap(candidates.first)
    do { try await body(store, candidate, records); await store.close() }
    catch { await store.close(); throw error }
  }

  private func assess(_ store: MathQuestionStore, _ candidate: MathSkillCandidate, _ record: MathQuestionRecord, _ index: Int, boundary: String = "applies") async throws {
    let review = try await store.reviewSolution(questionID: record.id, solutionID: "solution-\(index)",
      status: "confirmed", scope: "答案及解题过程", note: "逐步核验", correction: "")
    try await store.assessSkillCandidate(id: candidate.id, questionID: record.id,
      solutionID: "solution-\(index)", reviewID: review.id, boundary: boundary, note: "核对完整适用边界")
  }

  func testCurrentEvidenceCountsZeroOneAndTwoWithoutGrantingPublication() async throws {
    try await fixture { store, candidate, records in
      let zero = try await store.candidateCurrentEvidence(id: candidate.id)
      XCTAssertEqual(zero.count, 0)
      let text = await MathSkillReviewPanel.publicationGapText(store: store, candidate: candidate)
      XCTAssertTrue(text.contains("适用正例：0条"))
      XCTAssertTrue(text.contains("排除反例：0条"))
      XCTAssertTrue(text.contains("最低适用年级、方程要求、拓展许可"))
      XCTAssertTrue(text.contains("明确人工批准"))
      for index in 0..<2 {
        try await assess(store, candidate, records[index], index)
        let current = try await store.candidateCurrentEvidence(id: candidate.id)
        XCTAssertEqual(current.count, index + 1)
        let gaps = await MathSkillReviewPanel.publicationGapText(store: store, candidate: candidate)
        XCTAssertTrue(gaps.contains("适用正例：\(index + 1)条"))
        XCTAssertTrue(gaps.contains("尚无与当前有效依据绑定的报告"))
      }
    }
  }

  func testSourceOrLatestReviewChangesInvalidateCounts() async throws {
    try await fixture { store, candidate, records in
      try await assess(store, candidate, records[0], 0)
      try await assess(store, candidate, records[1], 1)
      try await store.updateOCR(questionID: records[0].id, text: "原题条件已修正")
      let afterSource = try await store.candidateCurrentEvidence(id: candidate.id)
      XCTAssertEqual(afterSource.map(\.questionID), [records[1].id])
      _ = try await store.reviewSolution(questionID: records[1].id, solutionID: "solution-1",
        status: "rejected", scope: "答案及解题过程", note: "过程存在问题", correction: "修正")
      let afterReview = try await store.candidateCurrentEvidence(id: candidate.id)
      XCTAssertTrue(afterReview.isEmpty)
      let gaps = await MathSkillReviewPanel.publicationGapText(store: store, candidate: candidate)
      XCTAssertTrue(gaps.contains("适用正例：0条"))
    }
  }

  func testSavedPermissionRevisionDiscardsOldEvidenceAndUnsavedTextDoesNotClaimReadiness() async throws {
    try await fixture { store, candidate, records in
      try await assess(store, candidate, records[0], 0)
      var proposal = candidate.proposal
      proposal.teachingPermissions = .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none)
      try await store.editSkillCandidate(id: candidate.id, proposal: proposal)
      let values = try await store.listSkillCandidates()
      let saved = try XCTUnwrap(values.first)
      let empty = try await store.candidateCurrentEvidence(id: saved.id)
      XCTAssertTrue(empty.isEmpty)
      let stale = await MathSkillReviewPanel.publicationGapText(store: store, candidate: candidate)
      XCTAssertTrue(stale.contains("保存版本已改变"))
      let unsaved = await MathSkillReviewPanel.publicationGapText(store: store, candidate: saved, unsaved: true)
      XCTAssertTrue(unsaved.contains("未保存修改"))
      for index in 0..<3 { try await assess(store, saved, records[index], index, boundary: index == 2 ? "excluded" : "applies") }
      let current = try await store.candidateCurrentEvidence(id: saved.id)
      XCTAssertEqual(current.count, 3)
      let gaps = await MathSkillReviewPanel.publicationGapText(store: store, candidate: saved)
      XCTAssertTrue(gaps.contains("保存版本 2"))
      XCTAssertTrue(gaps.contains("适用正例：2条（独立原图2份、独立题文2份"))
      XCTAssertTrue(gaps.contains("排除反例：1条"))
      XCTAssertTrue(gaps.contains("教学权限：已保存三项声明"))
      XCTAssertTrue(gaps.contains("不是发布许可"))
      XCTAssertTrue(gaps.contains("尚无与当前有效依据绑定的报告"))
    }
  }
  func testReadOnlySummaryScrollShowsGapsAndPreservesEvidenceDuringEdits() async throws {
    try await fixture { store, _, _ in
      let panel = MathSkillReviewPanel(store: store, openQuestion: { _ in })
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      let views = descendants(try XCTUnwrap(panel.panel.contentView))
      let refresh = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "刷新" })
      let summary = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "方法证据和审校记录" })
      let name = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "方法名称" })
      refresh.performClick(nil)
      for _ in 0..<200 {
        if summary.string.contains("自动观察") && summary.string.contains("适用正例：0条") { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertFalse(summary.isEditable)
      XCTAssertNotNil(summary.enclosingScrollView)
      XCTAssertTrue(summary.string.hasPrefix("保存版本 1 · 发布缺口"))
      XCTAssertTrue(summary.accessibilityHelp()?.hasPrefix("当前版本发布缺口：") == true)
      XCTAssertTrue(summary.string.contains("自动观察"))
      XCTAssertTrue(summary.string.contains("独立题文0"))
      name.stringValue += "（尚未保存）"
      panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
      XCTAssertTrue(summary.string.hasPrefix("存在未保存修改"))
      XCTAssertTrue(summary.string.contains("自动观察"), "Changing the gap prefix must preserve evidence history")
      XCTAssertTrue(summary.string.contains("独立题文0"))
      await panel.prepareForLibraryRestore()
    }
  }

}
