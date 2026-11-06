import Foundation
import CSQLite
import CryptoKit
import XCTest
@testable import VocabCapture

final class MathSkillLearningStoreTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("math-skills-learning-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private var proposal: MathSkillProposal {
    .init(signature: "repeat-gap-invariant",title:"重复间隔与不变量",category:"四年级算术",instructions:"先识别不变量，再比较两次变化，检查所求量与全部原题条件。误用反例：变化率未知时不直接套用。",trigger:"两个过程共享不变量",constraints:"必要条件均明确",exclusions:"缺条件或变化率不同不适用",prerequisites:"整数四则",supportedDiagrams:["table"])
  }
  private func question(_ store:MathQuestionStore,_ index:Int,photo:MathDiagram? = nil,text:String? = nil) async throws -> MathQuestionRecord {
    let image=try MathDiagramRenderer.renderPNG(photo ?? [MathDiagramFixtures.bar,MathDiagramFixtures.area,MathDiagramFixtures.state][index % 3])
    return try await store.save(.init(captureID:"capture-\(index)",imageData:image,ocrText:text ?? "独立原题\(index)",solutions:[.init(id:"solution-\(index)",question:"解题",answer:"算术过程\(index)",model:"fixture")]))
  }
  private func claim(_ store:MathQuestionStore,_ id:String) async throws -> MathSkillLearningAttempt {
    let value=try await store.claimSkillLearning(questionID:id)
    return try XCTUnwrap(value)
  }
  private func candidate(_ store:MathQuestionStore,_ record:MathQuestionRecord) async throws -> MathSkillCandidate {
    try await store.enqueueSkillLearning(questionID:record.id)
    let attempt=try await claim(store,record.id)
    try await store.finishSkillLearning(attempt:attempt,proposal:proposal,report:"{\"version\":1}",model:"fixture")
    let values=try await store.listSkillCandidates()
    return try XCTUnwrap(values.first)
  }
  private func assess(_ store:MathQuestionStore,_ id:String,_ record:MathQuestionRecord,_ index:Int,_ boundary:String) async throws {
    let review=try await store.reviewSolution(questionID:record.id,solutionID:"solution-\(index)",status:"confirmed",scope:"答案及解题过程",note:"逐步对照原题",correction:"")
    try await store.assessSkillCandidate(id:id,questionID:record.id,solutionID:"solution-\(index)",reviewID:review.id,boundary:boundary,note:"人工确认此例\(boundary)")
  }

  private func researchReport(_ attempt: MathSkillResearchAttempt, approved: Bool = false) throws -> String {
    let proposal = (attempt.learningObject["candidate"] as! [String: Any])["proposal"]!
    let checks = ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"].map {
      ["dimension": $0, "passed": true, "reason": "Fixture protocol check; not a model accuracy claim"] as [String: Any]
    }
    var object: [String: Any] = ["version": 1, "coverage": "uncovered", "covered_method_ids": [],
      "reason": "Explicit current revision review", "pattern_key": attempt.proposal.signature,
      "pattern_evidence_ids": attempt.evidence.filter { $0.boundary == "applies" }.map(\.questionID),
      "proposal": proposal, "review": ["checks": checks, "recommendation": "ready_for_human"],
      "status": approved ? "approved" : "awaiting_human", "workflow_state": [:]]
    if approved { object["human_decision"] = ["action": "approve", "reviewer": "fixture user", "note": "Checked all steps and boundaries"] }
    var state = object.filter { !["version", "workflow_state"].contains($0.key) }
    state["evidence"] = attempt.learningObject["evidence"]
    state["existing_patterns"] = []
    state["model_calls"] = 1
    object["workflow_state"] = ["version": 1, "state": state]
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
  }

  func testResearchTransportsConfirmedCorrectionAndBindsFreshReview() async throws {
    let store = MathQuestionStore(directory: root.appendingPathComponent("correction-transport"))
    let first = try await question(store, 0), second = try await question(store, 1), excluded = try await question(store, 2)
    let draft = try await candidate(store, first)
    try await assess(store, draft.id, first, 0, "applies")
    try await assess(store, draft.id, second, 1, "applies")
    try await assess(store, draft.id, excluded, 2, "excluded")
    let original = try await store.candidateResearchAttempt(id: draft.id)
    try await store.recordCandidateResearch(attempt: original, report: researchReport(original), model: "fixture")
    let correction = "完整修正：先逐项求差，再比较差值，不将相加误认为求差。"
    let review = try await store.reviewSolution(questionID: first.id, solutionID: "solution-0", status: "confirmed",
      scope: "答案及解题过程", note: "完整核验修正", correction: correction)
    do { _ = try await store.candidateResearchAttempt(id: draft.id); XCTFail("New review invalidates old boundary evidence") } catch {}
    try await store.assessSkillCandidate(id: draft.id, questionID: first.id, solutionID: "solution-0", reviewID: review.id,
      boundary: "applies", note: "核对修正后的过程及适用性")
    let fresh = try await store.candidateResearchAttempt(id: draft.id)
    let sources = try XCTUnwrap(fresh.learningObject["evidence"] as? [[String: Any]])
    let corrected = try XCTUnwrap(sources.first { $0["question_id"] as? String == first.id })
    XCTAssertEqual(corrected["answer"] as? String, correction)
    XCTAssertEqual(corrected["verification"] as? String, "confirmed")
    let boundEntry = try XCTUnwrap(fresh.evidence.first { $0.questionID == first.id })
    let mismatched = MathSkillCandidateEvidence(id: boundEntry.id, candidateID: boundEntry.candidateID,
      candidateRevision: boundEntry.candidateRevision, questionID: boundEntry.questionID, assetID: boundEntry.assetID,
      contentDigest: boundEntry.contentDigest, solutionID: boundEntry.solutionID, reviewID: "unrelated-review",
      referenceID: boundEntry.referenceID, boundary: boundEntry.boundary, origin: boundEntry.origin,
      note: boundEntry.note, snapshot: boundEntry.snapshot, createdAt: boundEntry.createdAt)
    let mismatchedAttempt = MathSkillResearchAttempt(candidateID: fresh.candidateID, revision: fresh.revision,
      proposal: fresh.proposal, evidence: [mismatched])
    let mismatchedSources = try XCTUnwrap(mismatchedAttempt.learningObject["evidence"] as? [[String: Any]])
    XCTAssertEqual(mismatchedSources.first?["answer"] as? String, "算术过程0")
    XCTAssertEqual(mismatchedSources.first?["verification"] as? String, "unverified",
      "An unrelated bound review cannot supply or certify a correction")
    let staleReport = try await store.candidateResearchReport(attempt: fresh)
    XCTAssertNil(staleReport, "A research report over the original cannot certify the corrected process")
    let saved = try await store.solutions(questionID: first.id)
    XCTAssertEqual(saved.first?.answer, "算术过程0", "Human correction never rewrites the original")
    let olderSources = try XCTUnwrap(original.learningObject["evidence"] as? [[String: Any]])
    XCTAssertEqual(olderSources.first { $0["question_id"] as? String == first.id }?["answer"] as? String, "算术过程0")
    await store.close()
  }

  func testPublicationRequiresIndependentProcessEvidenceAndRevocationStopsAutomaticReuse() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("library"))
    let first=try await question(store,0),second=try await question(store,1),excluded=try await question(store,2)
    let draft=try await candidate(store,first)
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("AI observation cannot approve") } catch {}
    try await assess(store,draft.id,first,0,"applies")
    try await assess(store,draft.id,second,1,"applies")
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("Boundary required") } catch {}
    try await assess(store,draft.id,excluded,2,"excluded")
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("Requires current research interrupt and human approval") } catch {}
    let research=try await store.candidateResearchAttempt(id:draft.id)
    let valid = try JSONSerialization.jsonObject(with: Data(researchReport(research).utf8)) as! [String:Any]
    for corruption in ["missing", "budget", "grade", "proposal", "evidence"] {
      var changed = valid
      var checkpoint = changed["workflow_state"] as! [String:Any]
      var state = checkpoint["state"] as! [String:Any]
      switch corruption {
      case "missing": checkpoint = [:]
      case "budget": state["model_calls"] = 99
      case "grade":
        var sources = state["evidence"] as! [[String:Any]]; sources[0]["grade"] = true; state["evidence"] = sources
      case "proposal":
        var proposal = state["proposal"] as! [String:Any]; proposal["instructions"] = "被替换的步骤"; state["proposal"] = proposal
      default:
        var sources = state["evidence"] as! [[String:Any]]; sources[0]["text"] = "被替换的原题"; state["evidence"] = sources
      }
      if corruption != "missing" { checkpoint["state"] = state }
      changed["workflow_state"] = checkpoint
      let report = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
      do { try await store.recordCandidateResearch(attempt: research, report: report, model: "fixture"); XCTFail("Reject \(corruption) checkpoint") } catch {}
    }
    do { try await store.recordCandidateResearch(attempt:research,report:researchReport(research,approved:true),model:"fixture"); XCTFail("Cannot skip the research pause") } catch {}
    try await store.recordCandidateResearch(attempt:research,report:researchReport(research),model:"fixture")
    try await store.recordCandidateResearch(attempt:research,report:researchReport(research,approved:true),model:"fixture")
    let method=try await store.publishSkillCandidate(id:draft.id)
    XCTAssertTrue(method.instructions.contains(proposal.exclusions))
    XCTAssertTrue(method.instructions.contains(proposal.prerequisites))
    let usable=try await store.automaticMethods(); XCTAssertTrue(usable.contains(method))
    try await store.revokeSkillMethod(versionID:method.versionID,note:"出现误用反例，先停止复用")
    let revoked=try await store.automaticMethods(); XCTAssertFalse(revoked.contains(method))
    let manual=try await store.methods(); XCTAssertTrue(manual.contains(method))
    let backup = root.appendingPathComponent("research-proof-backup")
    try await store.backup(to: backup)
    await store.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("questions.sqlite").path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle)
    defer { sqlite3_close(db) }
    _ = try MathQuestionArchive.validate(db)
    var corrupt = valid
    var checkpoint = corrupt["workflow_state"] as! [String:Any]
    var state = checkpoint["state"] as! [String:Any]
    var evidence = state["evidence"] as! [[String:Any]]
    evidence[0]["text"] = "与冻结原题不同但结构合法的条件"
    state["evidence"] = evidence; checkpoint["state"] = state; corrupt["workflow_state"] = checkpoint
    // Keep report/checkpoint mutually consistent; archive validation must still compare actual frozen sources.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(research)).map { String(format: "%02x", $0) }.joined()
    let proof = try JSONSerialization.jsonObject(with: encoder.encode(research.proposal))
    corrupt["native_research"] = ["candidate_id": research.candidateID, "revision": research.revision,
      "binding": digest,
      "evidence_ids": research.evidence.map(\.id), "proposal": proof]
    let corruptText = String(decoding: try JSONSerialization.data(withJSONObject: corrupt), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_learning_reports SET report_json='\(corruptText)' WHERE json_extract(report_json,'$.native_research') IS NOT NULL", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.validate(db), "A syntactically valid but unbound research proof cannot be restored")
  }

  func testDuplicatePhotoCannotSupplyTwoIndependentPositives() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("duplicate"))
    let first=try await question(store,0),duplicate=try await question(store,1,photo:MathDiagramFixtures.bar),excluded=try await question(store,2)
    let draft=try await candidate(store,first)
    try await assess(store,draft.id,first,0,"applies"); try await assess(store,draft.id,duplicate,1,"applies"); try await assess(store,draft.id,excluded,2,"excluded")
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("Same original is one case") } catch {}
    await store.close()
  }

  func testCandidateEditAndNewAnswerReviewInvalidateOldEvidence() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("versions"))
    let first=try await question(store,0),second=try await question(store,1),excluded=try await question(store,2)
    let draft=try await candidate(store,first)
    try await assess(store,draft.id,first,0,"applies"); try await assess(store,draft.id,second,1,"applies"); try await assess(store,draft.id,excluded,2,"excluded")
    _=try await store.reviewSolution(questionID:first.id,solutionID:"solution-0",status:"rejected",scope:"答案及解题过程",note:"复核有误",correction:"")
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("Superseded review cannot certify") } catch {}
    var changed=proposal; changed.instructions += "新增步骤"
    try await store.editSkillCandidate(id:draft.id,proposal:changed)
    do { _=try await store.publishSkillCandidate(id:draft.id); XCTFail("Old review cannot certify edited instructions") } catch {}
    await store.close()
  }

  func testAnswerOnlyReviewCannotCertifySkill() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("answer-only"))
    let first=try await question(store,0),draft=try await candidate(store,first)
    let review=try await store.reviewSolution(questionID:first.id,solutionID:"solution-0",status:"confirmed",scope:"最终答案",note:"数字相同",correction:"")
    do { try await store.assessSkillCandidate(id:draft.id,questionID:first.id,solutionID:"solution-0",reviewID:review.id,boundary:"applies",note:"数字一致"); XCTFail("Answer-only insufficient") } catch {}
    await store.close()
  }

  func testRestartRecoveryRejectsLateAttemptAndBackupRetainsCandidatesAndReports() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("restart"))
    let first=try await question(store,0)
    try await store.enqueueSkillLearning(questionID:first.id)
    let stale=try await claim(store,first.id)
    try await store.recoverSkillLearning()
    let fresh=try await claim(store,first.id)
    try await store.finishSkillLearning(attempt:stale,proposal:proposal,report:"{}",model:"fixture")
    let empty=try await store.listSkillCandidates(); XCTAssertTrue(empty.isEmpty)
    try await store.finishSkillLearning(attempt:fresh,proposal:proposal,report:"{\"version\":1}",model:"fixture")
    let backup=root.appendingPathComponent("backup"); try await store.backup(to:backup); await store.close()
    let restored=MathQuestionStore(directory:backup)
    let drafts=try await restored.listSkillCandidates(),reports=try await restored.skillLearningReports(questionID:first.id)
    XCTAssertEqual(drafts.count,1); XCTAssertEqual(reports.count,1)
    XCTAssertEqual(drafts.first?.proposal,proposal); await restored.close()
  }

  func testEmptyObservationAccumulatesWithoutPublishingAndSameSignatureMerges() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("observations"))
    for index in 0..<2 {
      let record=try await question(store,index); try await store.enqueueSkillLearning(questionID:record.id)
      let attempt=try await claim(store,record.id)
      try await store.finishSkillLearning(attempt:attempt,proposal:nil,report:"{}",model:"fixture",patternKey:proposal.signature)
    }
    let observed=try await store.listSkillCandidates(); XCTAssertEqual(observed.count,1); XCTAssertEqual(observed.first?.status,"observing")
    let evidence=try await store.candidateEvidence(id:try XCTUnwrap(observed.first?.id)); XCTAssertEqual(evidence.count,2)
    let methods=try await store.automaticMethods(); XCTAssertTrue(methods.isEmpty); await store.close()
  }

  func testEditedMethodCannotInheritApprovalOfOlderVersion() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("method-review"))
    let method=try await store.saveMethod(title:"用户方法",category:"四年级",instructions:"原来的方法与边界")
    let profile=MathSkillProfile(versionID:method.versionID,trigger:"适用条件",constraints:"学段限制",exclusions:"缺条件不适用",prerequisites:"四则运算",supportedDiagrams:["table"])
    try await store.saveSkillProfile(profile:profile)
    let draft=try await store.automaticMethods(); XCTAssertFalse(draft.contains(method))
    try await store.reviewSkillProfile(versionID:method.versionID,approved:true,note:"用户已核对步骤、正例及边界")
    let approved=try await store.automaticMethods(); XCTAssertTrue(approved.contains(method))
    let edited=try await store.saveMethod(id:method.id,title:method.title,category:method.category,instructions:"不同的新方法正文")
    let automatic=try await store.automaticMethods(); XCTAssertFalse(automatic.contains(edited))
    let manual=try await store.methods(); XCTAssertTrue(manual.contains(edited)); await store.close()
  }

  func testRepeatedSourcesAreFrozenTogetherAndLaterChangesRejectTheWholeReport() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("all-sources"))
    let first=try await question(store,0),second=try await question(store,1)
    try await store.enqueueSkillLearning(questionID:first.id)
    let attempt=try await claim(store,first.id)
    let evidence=try await store.learningSnapshot(questionID:second.id)
    _=try await store.reviewSolution(questionID:second.id,solutionID:"solution-1",status:"confirmed",scope:"答案及解题过程",note:"new review",correction:"")
    try await store.finishSkillLearning(attempt:attempt,proposal:proposal,report:"{}",model:"fixture",evidenceSnapshots:[evidence])
    let absent=try await store.listSkillCandidates(); XCTAssertTrue(absent.isEmpty)
    let reports=try await store.skillLearningReports(questionID:first.id); XCTAssertTrue(reports.isEmpty)
    let fresh=try await claim(store,first.id)
    let current=try await store.learningSnapshot(questionID:second.id)
    try await store.finishSkillLearning(attempt:fresh,proposal:proposal,report:"{}",model:"fixture",evidenceSnapshots:[current])
    let values=try await store.listSkillCandidates()
    let linked=try await store.candidateEvidence(id:try XCTUnwrap(values.first?.id))
    XCTAssertEqual(Set(linked.map(\.questionID)),[first.id,second.id])
    XCTAssertEqual(linked.first(where:{$0.questionID==second.id})?.snapshot,current)
    await store.close()
  }

  func testCancellationRequeuesOnlyTheClaimItOwns() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("cancel"))
    let first=try await question(store,0)
    try await store.enqueueSkillLearning(questionID:first.id)
    let stale=try await claim(store,first.id)
    try await store.releaseSkillLearning(attempt:stale)
    let fresh=try await claim(store,first.id)
    try await store.releaseSkillLearning(attempt:stale)
    let pending=try await store.pendingSkillLearningJobs(); XCTAssertTrue(pending.isEmpty)
    try await store.releaseSkillLearning(attempt:fresh)
    let released=try await store.pendingSkillLearningJobs(); XCTAssertEqual(released.map(\.questionID),[first.id])
    await store.close()
  }

  func testChangedEvidenceAndCandidateInvalidatePendingResearchAcrossRestart() async throws {
    let directory=root.appendingPathComponent("research-restart")
    let store=MathQuestionStore(directory:directory)
    let first=try await question(store,0),second=try await question(store,1),excluded=try await question(store,2)
    let draft=try await candidate(store,first)
    try await assess(store,draft.id,first,0,"applies"); try await assess(store,draft.id,second,1,"applies"); try await assess(store,draft.id,excluded,2,"excluded")
    let attempt=try await store.candidateResearchAttempt(id:draft.id)
    try await store.recordCandidateResearch(attempt:attempt,report:researchReport(attempt),model:"fixture")
    let backup=root.appendingPathComponent("research-backup")
    try await store.backup(to:backup); await store.close()
    let reopened=MathQuestionStore(directory:backup)
    let current=try await reopened.candidateResearchAttempt(id:draft.id)
    XCTAssertEqual(current,attempt)
    let persisted=try await reopened.candidateResearchReport(attempt:current); XCTAssertNotNil(persisted)
    _=try await reopened.reviewSolution(questionID:first.id,solutionID:"solution-0",status:"rejected",scope:"答案及解题过程",note:"counterexample after restart",correction:"")
    do { try await reopened.recordCandidateResearch(attempt:attempt,report:researchReport(attempt,approved:true),model:"fixture"); XCTFail("Superseded source cannot resume") } catch {}
    var edit=proposal; edit.instructions += " changed boundary"
    try await reopened.editSkillCandidate(id:draft.id,proposal:edit)
    do { try await reopened.recordCandidateResearch(attempt:attempt,report:researchReport(attempt,approved:true),model:"fixture"); XCTFail("Old revision cannot resume") } catch {}
    await reopened.close()
  }
}
