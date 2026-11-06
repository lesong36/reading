import AppKit
import CoreText
import XCTest
@testable import VocabCapture

@MainActor
final class MathSkillReviewUITests:XCTestCase {
  func testSameNameCandidatesKeepEveryIdentityAndLoadInitialFields() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("same-name-candidates-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    for index in 0..<3 {
      let record = try await store.save(.init(captureID: "same-name-\(index)",
        imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.area), ocrText: "独立题面\(index)"))
      try await store.rename(questionID: record.id, title: "同名题目")
      let proposal = MathSkillProposal(signature: "distinct-pattern-" + ["alpha", "beta", "gamma"][index], title: "观察中的新模式", category: "待审",
        instructions: "独立步骤\(index)", trigger: "原题条件\(index)", constraints: "不要混淆同名方法",
        exclusions: "条件不足", prerequisites: "四则运算", supportedDiagrams: ["table"])
      try await store.enqueueSkillLearning(questionID: record.id)
      let attempt = try await store.claimSkillLearning(questionID: record.id)
      try await store.finishSkillLearning(attempt: XCTUnwrap(attempt), proposal: proposal, report: "{}", model: "UI fixture")
    }
    let candidates = try await store.listSkillCandidates()
    var opened: [String] = []
    let editor = MathSkillReviewPanel(store: store, openQuestion: { opened.append($0) })
    defer { editor.panel.close() }
    editor.present()
    let views = descendants(try XCTUnwrap(editor.panel.contentView))
    let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择待审方法候选" })
    let merge = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择合并来源候选" })
    let evidence = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择核验例题" })
    let steps = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "候选方法步骤" })
    let title = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "方法名称" })
    try await settle { picker.numberOfItems == 3 && !steps.string.isEmpty }
    XCTAssertEqual(Set(picker.itemTitles).count, 3, "Same-name candidates must be distinguishable")
    for candidate in candidates {
      let item = try XCTUnwrap(picker.itemArray.first { ($0.representedObject as? String) == candidate.id })
      picker.select(item); picker.sendAction(picker.action, to: picker.target)
      XCTAssertEqual(title.stringValue, candidate.proposal.title)
      XCTAssertEqual(steps.string, candidate.proposal.instructions)
      XCTAssertEqual(merge.numberOfItems, 2)
      XCTAssertEqual(Set(merge.itemArray.compactMap { $0.representedObject as? String }),
        Set(candidates.filter { $0.id != candidate.id }.map(\.id)))
    }
    let records = try await store.list()
    XCTAssertEqual(evidence.numberOfItems, 3)
    XCTAssertEqual(Set(evidence.itemTitles).count, 3)
    XCTAssertEqual(Set(evidence.itemArray.compactMap { $0.representedObject as? String }), Set(records.map(\.id)))
    let record = try XCTUnwrap(records.last)
    evidence.select(try XCTUnwrap(evidence.itemArray.first { ($0.representedObject as? String) == record.id }))
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "查看原题与核验" }).performClick(nil)
    XCTAssertEqual(opened, [record.id], "The same-name evidence must open its own original, never an index neighbor")
    await editor.prepareForLibraryRestore()
    await store.close()
  }

  private func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
  private func settle(_ condition:() async throws -> Bool) async throws {
    for _ in 0..<200 { if try await condition(){return}; try await Task.sleep(nanoseconds:10_000_000) }
    XCTFail("Skill review UI did not settle")
  }
  func testCandidateEditorCannotPublishAIObservationAndInvalidatedWriteIsRejected() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("skill-review-ui-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let store=MathQuestionStore(directory:root)
    let question=try await store.save(.init(captureID:"q",imageData:MathDiagramRenderer.renderPNG(MathDiagramFixtures.area),ocrText:"原题"))
    let proposal=MathSkillProposal(signature:"shared-gap-invariant",title:"待审方法",category:"四年级",instructions:"比较数量关系，再独立验算",trigger:"条件明确",constraints:"原图为准",exclusions:"缺条件不适用",prerequisites:"四则运算",supportedDiagrams:["table"])
    try await store.enqueueSkillLearning(questionID:question.id)
    let claimed=try await store.claimSkillLearning(questionID:question.id),attempt=try XCTUnwrap(claimed)
    try await store.finishSkillLearning(attempt:attempt,proposal:proposal,report:"{}",model:"fixture")
    let panel=MathSkillReviewPanel(store:store,openQuestion:{_ in})
    let views=descendants(try XCTUnwrap(panel.panel.contentView))
    let buttons=views.compactMap{$0 as? NSButton}
    let refresh=try XCTUnwrap(buttons.first{$0.title=="刷新"}); refresh.performClick(nil)
    let name=try XCTUnwrap(views.compactMap{$0 as? NSTextField}.first{$0.placeholderString=="方法名称"})
    try await settle { name.stringValue=="待审方法" }
    XCTAssertNotNil(buttons.first { $0.title=="合并到当前候选" })
    XCTAssertNotNil(buttons.first { $0.title=="导出技能…" })
    let publish=try XCTUnwrap(buttons.first{$0.title=="批准并用于自动解题"}); publish.performClick(nil)
    try await settle { publish.isEnabled }
    let methods=try await store.automaticMethods(); XCTAssertTrue(methods.isEmpty)
    name.stringValue="不应保存的旧窗口修改"
    let save=try XCTUnwrap(buttons.first{$0.title=="保存候选修改"}); save.performClick(nil)
    await panel.prepareForLibraryRestore()
    let candidates=try await store.listSkillCandidates(); XCTAssertEqual(candidates.first?.proposal.title,"待审方法")
    await store.close()
  }

  func testLibraryExposesAutomaticLearningAndReviewWithoutRemovingFlatTagRows() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("skill-library-ui-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let store=MathQuestionStore(directory:root)
    var enabled=false
    let library=MathQuestionLibrary(store:store,reindex:{_ in},onLearningEnabled:{enabled=$0},backfillLearning:{})
    let views=descendants(try XCTUnwrap(library.contentView)),buttons=views.compactMap{$0 as? NSButton}
    XCTAssertNotNil(buttons.first{$0.title=="方法候选与教研…"})
    XCTAssertNotNil(buttons.first{$0.title=="检查已有题目"})
    let toggle=try XCTUnwrap(buttons.first{$0.title=="自动积累方法"})
    toggle.state = .on; toggle.sendAction(toggle.action,to:toggle.target)
    XCTAssertTrue(enabled)
    library.close(); await store.close()
  }

  /// This is an isolated UI and persistence fixture, not AI research or human approval.
  func testLongOriginalAndStoredResearchKeepCandidateEditingAndActionsAccessible() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-candidate-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let proposal = MathSkillProposal(signature: "long-source-ui-fixture", title: "长原图教研候选（界面测试）",
      category: "四年级 · 隔离测试", instructions: String(repeating: "先核对原图与参考过程，再比较共同不变量；条件缺失时不得套用。\n", count: 30),
      trigger: "两种分配共享同一总量", constraints: "仅为界面测试；教研检查未代表真实模型认证",
      exclusions: "总量变化或缺少分配条件", prerequisites: "四则运算", supportedDiagrams: ["table"],
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    var records: [MathQuestionRecord] = []
    for index in 0..<3 {
      let source = "独立长原图 \(index)：每人分配数量与总量的比较。\n" + String(repeating: "原图末尾条件必须可查看；OCR 仅用于索引。\n", count: 70)
      records.append(try await store.save(.init(captureID: "long-fixture-\(index)",
        imageData: longOriginal(index), ocrText: source,
        solutions: [.init(id: "long-solution-\(index)", question: "不要使用方程",
          answer: "隔离测试过程 \(index)，不是模型回答或已认证答案。", model: "UI fixture") ])))
    }
    try await store.enqueueSkillLearning(questionID: records[0].id)
    let claimed = try await store.claimSkillLearning(questionID: records[0].id)
    try await store.finishSkillLearning(attempt: XCTUnwrap(claimed), proposal: proposal, report: "{}", model: "UI fixture")
    let candidates = try await store.listSkillCandidates()
    let candidate = try XCTUnwrap(candidates.first)
    for (index, record) in records.enumerated() {
      let reference = try await store.addReferenceAnswer(questionID: record.id,
        text: "隔离 UI 参考过程 \(index)", source: "测试作者提供；不是实际用户核验", scope: "答案及解题过程")
      let review = try await store.reviewSolution(questionID: record.id, solutionID: "long-solution-\(index)",
        status: "confirmed", scope: "答案及解题过程", note: "明确的人审测试夹具；不修改实际题库", correction: "")
      try await store.assessSkillCandidate(id: candidate.id, questionID: record.id, solutionID: "long-solution-\(index)",
        reviewID: review.id, referenceID: reference.id, boundary: index == 2 ? "excluded" : "applies",
        note: "人审界面测试依据 \(index)；" + String(repeating: "逐步核对原图条件和参考过程。", count: 30))
    }
    let attempt = try await store.candidateResearchAttempt(id: candidate.id)
    try await store.recordCandidateResearch(attempt: attempt, report: researchFixture(attempt), model: "UI fixture, no model call")
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    let editor = MathSkillReviewPanel(store: store, openQuestion: { library.present(questionID: $0) })
    defer { editor.panel.close(); library.close() }
    editor.present()
    editor.panel.setContentSize(NSSize(width: 780, height: 820))
    let views = descendants(try XCTUnwrap(editor.panel.contentView))
    let summary = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "方法证据和审校记录" })
    try await settle { summary.string.contains("图解依据") && summary.string.contains("当前版本教研检查") }
    let steps = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "候选方法步骤" })
    XCTAssertEqual(steps.string, proposal.instructions)
    XCTAssertTrue(steps.isEditable)
    XCTAssertTrue(summary.string.contains("人工确认"))
    XCTAssertTrue(summary.string.contains("仍需人工批准"))
    for text in [steps, summary] {
      let scroll = try XCTUnwrap(text.enclosingScrollView)
      XCTAssertTrue(scroll.hasVerticalScroller)
      text.layoutManager?.ensureLayout(for: try XCTUnwrap(text.textContainer))
      XCTAssertGreaterThan(text.frame.height, scroll.contentView.bounds.height)
      text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length - 1, length: 1))
      XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The end of the long evidence must be reachable")
    }
    editor.panel.contentView?.layoutSubtreeIfNeeded()
    let buttons = views.compactMap { $0 as? NSButton }
    let content = try XCTUnwrap(editor.panel.contentView)
    let actions = try ["保存候选修改", "教研审校", "拒绝候选", "批准并用于自动解题", "查看原题与核验"].map { title in
      try XCTUnwrap(buttons.first { $0.title == title })
    }
    for button in actions {
      let rect = button.convert(button.bounds, to: content)
      XCTAssertTrue(button.isEnabled)
      XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
      XCTAssertTrue(content.bounds.contains(rect), "Action must remain inside the minimum candidate window: \(button.title)")
      XCTAssertGreaterThan(rect.height, 15)
    }
    let protected = actions.map { $0 as NSView } + [try XCTUnwrap(steps.enclosingScrollView), try XCTUnwrap(summary.enclosingScrollView)]
    for left in protected.indices {
      for right in protected.indices where right > left {
        XCTAssertFalse(protected[left].convert(protected[left].bounds, to: content)
          .intersects(protected[right].convert(protected[right].bounds, to: content)),
          "Long text must not overlap editing or decision controls")
      }
    }
    let sourceAction = try XCTUnwrap(buttons.first { $0.title == "查看原题与核验" })
    let evidencePicker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择核验例题" })
    let allRecords = try await store.list()
    evidencePicker.selectItem(at: try XCTUnwrap(allRecords.firstIndex { $0.id == records[0].id }))
    sourceAction.performClick(nil)
    let libraryViews = descendants(try XCTUnwrap(library.contentView))
    let photo = try XCTUnwrap(libraryViews.compactMap { $0 as? NSImageView }.first)
    try await settle { photo.image != nil }
    XCTAssertEqual(photo.image?.size.height, 6_000)
    try XCTUnwrap(libraryViews.compactMap { $0 as? NSButton }.first { $0.title == "查看原图" }).performClick(nil)
    let original = try XCTUnwrap(NSApp.windows.first { $0.title == "题目原图" && $0.isVisible })
    let originalScroll = try XCTUnwrap(original.contentView as? NSScrollView)
    let originalView = try XCTUnwrap(originalScroll.documentView as? NSImageView)
    XCTAssertTrue(originalScroll.hasVerticalScroller)
    XCTAssertTrue(originalScroll.hasHorizontalScroller)
    XCTAssertEqual(originalView.frame.height, 6_000)
    XCTAssertGreaterThan(originalView.frame.height, originalScroll.contentView.bounds.height)
    originalView.scrollToVisible(NSRect(x: 0, y: 5_900, width: 100, height: 100))
    XCTAssertGreaterThan(originalScroll.contentView.bounds.minY, 5_000, "The final original condition must be reachable at native resolution")
    editor.present()
    editor.panel.title = "方法候选与教研 · 隔离长原图测试"
    try await settle { summary.string.contains("当前版本教研检查") }
    editor.panel.makeKeyAndOrderFront(nil)
    editor.panel.orderFrontRegardless()
    // CUA, not a subprocess or cached-view screenshot, inspects this composed window.
    let configured = Double(ProcessInfo.processInfo.environment["MATH_SKILL_UI_HOLD_SECONDS"] ?? "0") ?? 0
    let hold = configured.isFinite ? min(60, max(0, configured)) : 0
    if hold > 0 {
      print("CUA inspection: 方法候选与教研 · 隔离长原图测试; 数学题库; 题目原图 (\(hold) seconds)")
      try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
    }
    let name = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "方法名称" })
    XCTAssertTrue(name.isEditable)
    name.stringValue = "长原图候选修改（隔离测试）"
    try XCTUnwrap(buttons.first { $0.title == "保存候选修改" }).performClick(nil)
    try await settle { try await store.listSkillCandidates().first?.revision == 2 }
    let after = try await store.listSkillCandidates()
    XCTAssertEqual(after.first?.status, "draft", "Displaying a review must never publish or simulate approval")
    XCTAssertEqual(after.first?.proposal.title, name.stringValue)
    let methods = try await store.automaticMethods()
    let preservedOriginal = try await store.originalImage(questionID: records[0].id)
    XCTAssertTrue(methods.isEmpty)
    XCTAssertEqual(preservedOriginal, try longOriginal(0))
    original.close()
    await editor.prepareForLibraryRestore()
    await store.close()
  }

  private func longOriginal(_ index: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 1_024, height: 6_000, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 6_000))
    for row in 0..<30 {
      context.setFillColor((row.isMultiple(of: 2) ? NSColor(calibratedWhite: 0.94, alpha: 1) : .white).cgColor)
      context.fill(CGRect(x: 0, y: row * 200, width: 1_024, height: 200))
      context.textPosition = CGPoint(x: 40, y: row * 200 + 70)
      CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "隔离原图 \(index) · 原始条件 \(row + 1)（不代表真实题目）",
        attributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])), context)
    }
    return try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
  }

  private func researchFixture(_ attempt: MathSkillResearchAttempt) throws -> String {
    let candidate = try XCTUnwrap(attempt.learningObject["candidate"] as? [String: Any])
    let proposal = try XCTUnwrap(candidate["proposal"])
    let checks: [[String: Any]] = ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"].map {
      ["dimension": $0, "passed": false, "reason": "界面夹具，尚未进行真实教研认证。" + String(repeating: "需逐条核对原题、过程与适用边界。", count: 60)]
    }
    var object: [String: Any] = ["version": 1, "coverage": "uncovered", "covered_method_ids": [],
      "reason": "Stored isolated UI fixture; no AI or human approval", "pattern_key": attempt.proposal.signature,
      "pattern_evidence_ids": attempt.evidence.filter { $0.boundary == "applies" }.map(\.questionID),
      "proposal": proposal, "review": ["checks": checks, "recommendation": "needs_revision"],
      "status": "awaiting_human", "workflow_state": [:]]
    var state = object.filter { !["version", "workflow_state"].contains($0.key) }
    state["evidence"] = attempt.learningObject["evidence"]
    state["existing_patterns"] = []
    state["model_calls"] = 0
    object["workflow_state"] = ["version": 1, "state": state]
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
  }
}
