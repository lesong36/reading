import AppKit
import CSQLite
import XCTest
@testable import VocabCapture

@MainActor
final class MathSkillEvidenceReviewTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-pack-" + UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func fixture(observed: Int = 3) async throws -> (MathQuestionStore, MathSkillEvidenceReviewPackage) {
    let store = MathQuestionStore(directory: root)
    var records: [MathQuestionRecord] = []
    for index in 0..<3 {
      let image = try MathDiagramRenderer.renderPNG([MathDiagramFixtures.bar, MathDiagramFixtures.area, MathDiagramFixtures.state][index])
      let record = try await store.save(.init(captureID: "source-\(index)", imageData: image,
        ocrText: "独立题面\(index)", solutions: [.init(id: "answer-\(index)", question: "测试题",
          answer: "测试专用答案及全部过程\(index)", model: "offline fixture, not real teaching review")]))
      records.append(record)
    }
    let proposal = MathSkillProposal(signature: "evidence-pack-test", title: "测试专用候选", category: "四年级",
      instructions: "这是离线验证流程的步骤，不代表真实教学结论", trigger: "测试适用条件", constraints: "测试专用",
      exclusions: "测试排除条件", prerequisites: "算术", supportedDiagrams: ["table"])
    for record in records.prefix(observed) {
      try await store.enqueueSkillLearning(questionID: record.id)
      let attempt = try await store.claimSkillLearning(questionID: record.id)
      try await store.finishSkillLearning(attempt: XCTUnwrap(attempt), proposal: proposal, report: "{}", model: "offline fixture")
    }
    let candidates = try await store.listSkillCandidates()
    let candidate = try XCTUnwrap(candidates.first)
    let package = try await store.loadSkillEvidenceReview(candidateID: candidate.id)
    return (store, package)
  }
  private func items(_ pack: MathSkillEvidenceReviewPackage) -> [MathSkillEvidenceReviewItem] {
    pack.sources.enumerated().map { .init(questionID: $0.element.questionID, boundary: $0.offset < 2 ? "applies" : "excluded", answerStatus: "confirmed") }
  }
  private func confirm(_ store: MathQuestionStore, _ pack: MathSkillEvidenceReviewPackage) async throws {
    try await store.confirmSkillEvidenceReview(package: pack, items: items(pack),
      note: "离线测试专用模拟人工确认，不是用户真实批准", confirmed: true)
  }
  private func noUserWrites(_ store: MathQuestionStore, _ pack: MathSkillEvidenceReviewPackage) async throws {
    let evidence = try await store.candidateEvidence(id: pack.candidate.id)
    XCTAssertFalse(evidence.contains { $0.origin == "user" })
    for source in pack.sources {
      let current = try await store.learningSnapshot(questionID: source.questionID)
      XCTAssertEqual(current.reviews.count, source.reviews.count)
    }
  }
  func testExplicitWholePacketConfirmsThreeSourcesWithoutPublishing() async throws {
    let (store, pack) = try await fixture()
    XCTAssertEqual(pack.sources.count, 3)
    try await noUserWrites(store, pack)
    try await confirm(store, pack)
    let evidence = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertEqual(evidence.count, 3)
    XCTAssertEqual(evidence.filter { $0.boundary == "applies" }.count, 2)
    XCTAssertEqual(evidence.filter { $0.boundary == "excluded" }.count, 1)
    XCTAssertTrue(evidence.allSatisfy { $0.origin == "user" && $0.candidateRevision == pack.candidate.revision })
    for source in pack.sources {
      let snapshot = try await store.learningSnapshot(questionID: source.questionID)
      XCTAssertEqual(snapshot.reviews.count, 1)
      XCTAssertEqual(snapshot.solutions.last?.verificationStatus, "confirmed")
      XCTAssertEqual(snapshot.reviews.last?.scope, "答案及解题过程")
    }
    let candidates = try await store.listSkillCandidates()
    XCTAssertEqual(candidates.first?.status, "draft")
    XCTAssertNil(candidates.first?.publishedVersionID)
    let methods = try await store.methods(); XCTAssertTrue(methods.isEmpty)
    do { _ = try await store.publishSkillCandidate(id: pack.candidate.id); XCTFail("Evidence is not research or publication approval") } catch {}
    // Consumed packages cannot be replayed to manufacture a second review.
    do { try await confirm(store, pack); XCTFail("Stale review snapshot must reject replay") } catch {}
    let after = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertEqual(after, evidence)
    await store.close()
  }
  func testStaleProposalAndSourceFailBeforeAnyWrite() async throws {
    for change in ["proposal", "ocr", "answer", "reference", "review"] {
      let (store, pack) = try await fixture()
      let source = try XCTUnwrap(pack.sources.first)
      switch change {
      case "proposal":
        var proposal = pack.candidate.proposal; proposal.exclusions += "变更边界"
        try await store.editSkillCandidate(id: pack.candidate.id, proposal: proposal)
      case "ocr": try await store.updateOCR(questionID: source.questionID, text: "更新题面")
      case "answer":
        let original = try await store.originalImage(questionID: source.questionID)
        _ = try await store.save(.init(captureID: "source-0", imageData: original, ocrText: source.ocrText,
          solutions: [.init(id: "new-latest", question: "追问", answer: "更新过程", model: "fixture")]))
      case "reference": _ = try await store.addReferenceAnswer(questionID: source.questionID, text: "新参考", source: "fixture", scope: "答案")
      default:
        _ = try await store.reviewSolution(questionID: source.questionID, solutionID: source.solutions.last!.id,
          status: "rejected", scope: "答案", note: "外部修改", correction: "")
      }
      let baseline = try await pack.sources.asyncMap { try await store.learningSnapshot(questionID: $0.questionID) }
      do { try await confirm(store, pack); XCTFail("Changed \(change) must reject frozen package") } catch {}
      let evidence = try await store.candidateEvidence(id: pack.candidate.id)
      XCTAssertFalse(evidence.contains { $0.origin == "user" })
      let after = try await pack.sources.asyncMap { try await store.learningSnapshot(questionID: $0.questionID) }
      XCTAssertEqual(after, baseline)
      await store.close()
      try FileManager.default.removeItem(at: root)
    }
  }
  func testIndependentSourcesAndExplicitConsentAreRequired() async throws {
    let (store, pack) = try await fixture()
    for choice in ["unchecked", "empty-note", "undecided-answer", "duplicate", "same-text"] {
      var copy = pack, selections = items(pack)
      if choice == "duplicate" { copy.sources.append(copy.sources[0]); selections.append(selections[0]) }
      if choice == "undecided-answer" { selections[0] = .init(questionID: selections[0].questionID, boundary: "applies") }
      if choice == "same-text" {
        // Actual sources with equal indexing text cannot masquerade as independent evidence.
        try await store.updateOCR(questionID: pack.sources[1].questionID, text: pack.sources[0].ocrText)
        copy.sources[1] = try await store.learningSnapshot(questionID: pack.sources[1].questionID)
      }
      do {
        try await store.confirmSkillEvidenceReview(package: copy, items: selections,
          note: choice == "empty-note" ? " \n " : "test only", confirmed: choice != "unchecked")
        XCTFail("Must reject \(choice)")
      } catch {}
      try await noUserWrites(store, pack)
    }
    await store.close()
  }
  func testMissingLatestAnswerAndCopiedPhotoCannotBeConfirmed() async throws {
    let (store, pack) = try await fixture()
    let image = try await store.originalImage(questionID: pack.sources[0].questionID)
    let withoutAnswer = try await store.save(.init(captureID: "missing-answer", imageData: image,
      ocrText: "缺答案来源"))
    var missing = pack
    missing.sources.append(try await store.learningSnapshot(questionID: withoutAnswer.id))
    do { try await confirm(store, missing); XCTFail("A source without an answer must not be declared checked") } catch {}
    let copiedPhoto = try await store.save(.init(captureID: "copied-photo", imageData: image,
      ocrText: "不同文字但同一原图", solutions: [.init(question: "测试", answer: "测试专用答案", model: "fixture")]))
    var copied = pack
    copied.sources[1] = try await store.learningSnapshot(questionID: copiedPhoto.id)
    do { try await confirm(store, copied); XCTFail("Copied photo is not independent positive evidence") } catch {}
    try await noUserWrites(store, pack)
    let snapshot = try await store.learningSnapshot(questionID: copiedPhoto.id)
    XCTAssertTrue(snapshot.reviews.isEmpty)
    await store.close()
  }
  func testDatabaseFailureRollsBackEveryReviewAndEvidence() async throws {
    let (store, pack) = try await fixture()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(root.appendingPathComponent("questions.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    // Failure after the second source review proves rollback beyond validation.
    let sql = "CREATE TRIGGER fail_pack BEFORE INSERT ON method_candidate_evidence WHEN NEW.origin='user' AND (SELECT COUNT(*) FROM method_candidate_evidence WHERE origin='user')=1 BEGIN SELECT RAISE(ABORT,'offline injected failure'); END;"
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    do { try await confirm(store, pack); XCTFail("Injected second evidence insert must fail") } catch {}
    try await noUserWrites(store, pack)
    for source in pack.sources {
      let snapshot = try await store.learningSnapshot(questionID: source.questionID)
      XCTAssertEqual(snapshot.solutions.last?.verificationStatus, "unverified")
    }
    await store.close()
  }
  func testOpeningAndClosingReadablePacketDoesNotWriteReviews() async throws {
    let (store, pack) = try await fixture()
    let review = MathSkillEvidenceReviewPanel(store: store, candidateID: pack.candidate.id)
    review.present()
    defer { review.invalidate() }
    for _ in 0..<150 {
      let labels = descendants(try XCTUnwrap(review.panel.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
      if labels.contains(where: { $0.contains("测试专用答案及全部过程") }) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    review.panel.contentView?.layoutSubtreeIfNeeded()
    let views = descendants(try XCTUnwrap(review.panel.contentView))
    let scrolls = views.compactMap { $0 as? NSScrollView }
    XCTAssertEqual(scrolls.count, 1, "One outer reading area, never tiny answer scroll frames")
    XCTAssertGreaterThan(try XCTUnwrap(scrolls.first?.documentView).frame.height, review.panel.frame.height)
    let pickers = views.compactMap { $0 as? NSPopUpButton }.filter { $0.accessibilityLabel()?.contains("的方法适用性") == true }
    XCTAssertEqual(pickers.count, 3)
    XCTAssertTrue(pickers.allSatisfy { $0.indexOfSelectedItem == 0 })
    let checkbox = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("我已检查") })
    XCTAssertEqual(checkbox.state, .off)
    let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
    XCTAssertEqual(labels.filter { $0.contains("答案与讲解") }.count, 3)
    try await noUserWrites(store, pack)
    let remove = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "从本次核验移除" })
    remove.performClick(nil)
    let remaining = descendants(try XCTUnwrap(review.panel.contentView)).compactMap { $0 as? NSPopUpButton }
      .filter { $0.accessibilityLabel()?.contains("的方法适用性") == true }
    XCTAssertEqual(remaining.count, 2)
    try await noUserWrites(store, pack)
    review.invalidate()
    try await noUserWrites(store, pack)
    await store.close()
  }
  func testUserCanAddMissingSourceAndConfirmWholePacketWithOneAction() async throws {
    let (store, pack) = try await fixture(observed: 2)
    XCTAssertEqual(pack.sources.count, 2)
    let records = try await store.list()
    let missing = try XCTUnwrap(records.first { record in !pack.sources.contains { $0.questionID == record.id } })
    var changes = 0
    let review = MathSkillEvidenceReviewPanel(store: store, candidateID: pack.candidate.id) { changes += 1 }
    review.present(); defer { review.invalidate() }
    func views() throws -> [NSView] { descendants(try XCTUnwrap(review.panel.contentView)) }
    func boundaryPickers() throws -> [NSPopUpButton] {
      try views().compactMap { $0 as? NSPopUpButton }.filter { $0.accessibilityLabel()?.contains("的方法适用性") == true }
    }
    try await settle { try boundaryPickers().count == 2 }
    let addPicker = try XCTUnwrap(try views().compactMap { $0 as? NSPopUpButton }.first {
      $0.accessibilityLabel() == "从题库补充审核题目"
    })
    let item = try XCTUnwrap(addPicker.itemArray.first { $0.representedObject as? String == missing.id })
    addPicker.select(item)
    try XCTUnwrap(try views().compactMap { $0 as? NSButton }.first { $0.title == "补充这道依据" }).performClick(nil)
    try await settle { try boundaryPickers().count == 3 }
    let checkbox = try XCTUnwrap(try views().compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("我已检查") })
    for (index, picker) in try boundaryPickers().enumerated() {
      checkbox.state = .on
      picker.selectItem(at: index < 2 ? 1 : 2)
      picker.sendAction(picker.action, to: picker.target)
      XCTAssertEqual(checkbox.state, .off, "Changing source boundaries invalidates prior pack consent")
    }
    for picker in try views().compactMap({ $0 as? NSPopUpButton }).filter({
      $0.accessibilityLabel()?.contains("的答案过程正确性") == true
    }) {
      picker.selectItem(at: 1); picker.sendAction(picker.action, to: picker.target)
    }
    let note = try XCTUnwrap(try views().compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "整包人工核验说明"
    })
    note.stringValue = "离线 UI 测试模拟确认，不是现实用户审核"
    try await noUserWrites(store, pack)
    checkbox.state = .on
    try XCTUnwrap(try views().compactMap { $0 as? NSButton }.first { $0.title == "一次保存已审核依据" }).performClick(nil)
    try await settle { changes == 1 }
    let current = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertEqual(current.count, 3)
    XCTAssertTrue(current.contains { $0.questionID == missing.id })
    XCTAssertEqual(changes, 1)
    let candidates = try await store.listSkillCandidates()
    XCTAssertEqual(candidates.first?.status, "draft")
    XCTAssertNil(candidates.first?.publishedVersionID)
    await store.close()
  }
  func testRejectedAnswerIsSavedTruthfullyWithoutBecomingUsableEvidence() async throws {
    let (store, pack) = try await fixture()
    let source = pack.sources[0]
    let item = MathSkillEvidenceReviewItem(questionID: source.questionID, boundary: "excluded",
      answerStatus: "rejected", correction: "离线测试：原答案错误，不能确认过程")
    try await store.confirmSkillEvidenceReview(package: pack, items: [item], note: "离线审核说明", confirmed: true)
    let snapshot = try await store.learningSnapshot(questionID: source.questionID)
    XCTAssertEqual(snapshot.solutions.last?.verificationStatus, "rejected")
    XCTAssertEqual(snapshot.reviews.last?.correction, item.correction)
    XCTAssertNil(snapshot.reviews.last?.referenceID)
    let usable = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertTrue(usable.isEmpty)
    do { _ = try await store.publishSkillCandidate(id: pack.candidate.id); XCTFail("Rejected answer cannot publish") } catch {}
    for other in pack.sources.dropFirst() {
      let untouched = try await store.learningSnapshot(questionID: other.questionID)
      XCTAssertTrue(untouched.reviews.isEmpty)
    }
    await store.close()
  }
  func testRejectedAnswerRequiresExplicitExplanation() async throws {
    let (store, pack) = try await fixture()
    do {
      try await store.confirmSkillEvidenceReview(package: pack,
        items: [.init(questionID: pack.sources[0].questionID, boundary: "excluded", answerStatus: "rejected")],
        note: "整体说明", confirmed: true)
      XCTFail("Wrong answers need an explicit reason or correction")
    } catch {}
    try await noUserWrites(store, pack)
    await store.close()
  }
  func testEditedCandidateLoadsHistoricalSourcesWithoutCopyingApprovals() async throws {
    let (store, pack) = try await fixture()
    try await confirm(store, pack)
    var proposal = pack.candidate.proposal; proposal.exclusions += "新版本边界"
    try await store.editSkillCandidate(id: pack.candidate.id, proposal: proposal)
    let fresh = try await store.loadSkillEvidenceReview(candidateID: pack.candidate.id)
    XCTAssertEqual(Set(fresh.sources.map(\.questionID)), Set(pack.sources.map(\.questionID)))
    XCTAssertGreaterThan(fresh.candidate.revision, pack.candidate.revision)
    let current = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertTrue(current.isEmpty)
    await store.close()
  }
  func testPartialReviewDoesNotRequireAnAnswerOnUndecidedCardOrChooseReference() async throws {
    let (store, initial) = try await fixture()
    let source = initial.sources[0]
    _ = try await store.addReferenceAnswer(questionID: source.questionID, text: "不应自动关联的参考", source: "测试", scope: "答案")
    var pack = initial
    pack.sources[0] = try await store.learningSnapshot(questionID: source.questionID)
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let unsolved = try await store.save(.init(captureID: "undecided-unsolved", imageData: image, ocrText: "尚未解答卡片"))
    pack.sources.append(try await store.learningSnapshot(questionID: unsolved.id))
    try await store.confirmSkillEvidenceReview(package: pack,
      items: [.init(questionID: source.questionID, boundary: "applies", answerStatus: "confirmed")],
      note: "只确认第一题，不关联参考", confirmed: true)
    let current = try await store.learningSnapshot(questionID: source.questionID)
    XCTAssertNil(current.reviews.last?.referenceID)
    let evidence = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertEqual(evidence.count, 1)
    XCTAssertNil(evidence.first?.referenceID)
    do { _ = try await store.candidateResearchAttempt(id: pack.candidate.id); XCTFail("Partial review cannot bypass research gates") } catch {}
    await store.close()
  }
  func testPacketUICanRejectAnswerIndependentlyAndShowCorrectionOnReopen() async throws {
    let (store, pack) = try await fixture()
    var changed = false
    let panel = MathSkillEvidenceReviewPanel(store: store, candidateID: pack.candidate.id) { changed = true }
    panel.present(); defer { panel.invalidate() }
    func views() -> [NSView] { panel.panel.contentView.map(descendants) ?? [] }
    try await settle { views().compactMap { $0 as? NSPopUpButton }.contains {
      $0.accessibilityLabel()?.contains("的答案过程正确性") == true
    } }
    let choices = views().compactMap { $0 as? NSPopUpButton }
    XCTAssertTrue(choices.filter { $0.accessibilityLabel()?.contains("的答案过程正确性") == true }.allSatisfy { $0.indexOfSelectedItem == 0 })
    let answer = try XCTUnwrap(choices.first { $0.accessibilityLabel() == "依据 1 的答案过程正确性" })
    let boundary = try XCTUnwrap(choices.first { $0.accessibilityLabel() == "依据 1 的方法适用性" })
    answer.selectItem(at: 2); answer.sendAction(answer.action, to: answer.target)
    boundary.selectItem(at: 2); boundary.sendAction(boundary.action, to: boundary.target)
    let correction = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "依据 1 的错误说明或修正" })
    correction.stringValue = "离线测试：错误过程需要修正"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: correction))
    try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "整包人工核验说明" }).stringValue = "离线模拟审核，非真人批准"
    let preview = views().compactMap { $0 as? NSButton }.filter { $0.title.hasPrefix("放大查看") }
    XCTAssertEqual(preview.count, 3)
    try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("我已检查") }).state = .on
    try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.title == "一次保存已审核依据" }).performClick(nil)
    try await settle { changed }
    let source = try await store.learningSnapshot(questionID: pack.sources[0].questionID)
    XCTAssertEqual(source.solutions.last?.verificationStatus, "rejected")
    XCTAssertEqual(source.reviews.last?.correction, correction.stringValue)
    panel.invalidate()
    let reopened = MathSkillEvidenceReviewPanel(store: store, candidateID: pack.candidate.id)
    reopened.present(); defer { reopened.invalidate() }
    try await settle { reopened.panel.contentView.map(descendants)?.compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("已驳回：答案或过程有误") && $0.stringValue.contains("离线测试：错误过程需要修正")
    } == true }
    let available = try await store.candidateCurrentEvidence(id: pack.candidate.id)
    XCTAssertTrue(available.isEmpty)
    await store.close()
  }
  func testAnswerRejectionDoesNotRequireInventingMethodApplicability() async throws {
    let (store, pack) = try await fixture()
    let source = pack.sources[0]
    try await store.confirmSkillEvidenceReview(package: pack,
      items: [.init(questionID: source.questionID, boundary: "", answerStatus: "rejected", correction: "离线测试：答案错误，方法边界尚未判断")],
      note: "离线测试审核", confirmed: true)
    let snapshot = try await store.learningSnapshot(questionID: source.questionID)
    XCTAssertEqual(snapshot.reviews.last?.status, "rejected")
    let evidence = try await store.candidateEvidence(id: pack.candidate.id)
    XCTAssertFalse(evidence.contains { $0.origin == "user" })
    await store.close()
  }
  private func settle(_ condition: () throws -> Bool) async throws {
    for _ in 0..<150 {
      if try condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Evidence packet UI did not settle")
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private extension Array {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var result: [T] = []
    for value in self { result.append(try await transform(value)) }
    return result
  }
}
