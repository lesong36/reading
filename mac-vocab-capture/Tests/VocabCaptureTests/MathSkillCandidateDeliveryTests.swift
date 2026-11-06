import Foundation
import XCTest
@testable import VocabCapture

final class MathSkillCandidateDeliveryTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root=FileManager.default.temporaryDirectory.appendingPathComponent("candidate-delivery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
  private func proposal(_ signature:String) -> MathSkillProposal {
    .init(signature:signature,title:"共享数量的变化比较",category:"四年级",instructions:"先找出两次过程共同保持不变的数量，逐项比较变化，选择四则运算求所求量，再对照原题全部条件验算。",trigger:"两个过程共享确定的数量",constraints:"只用小学四则运算",exclusions:"变化量或共同数量未知时不适用",prerequisites:"整数四则运算",supportedDiagrams:["table"])
  }
  private func question(_ store:MathQuestionStore,_ index:Int) async throws -> MathQuestionRecord {
    try await store.save(.init(captureID:"q-\(index)",
      imageData:MathDiagramRenderer.renderPNG([MathDiagramFixtures.bar,MathDiagramFixtures.area,MathDiagramFixtures.state][index%3]),
      ocrText:"独立数量条件\(index)",solutions:[.init(id:"s-\(index)",question:"小学算术解题",answer:"算术过程\(index)",model:"fixture")]))
  }
  private func candidate(_ store:MathQuestionStore,_ q:MathQuestionRecord,_ signature:String) async throws -> MathSkillCandidate {
    try await store.enqueueSkillLearning(questionID:q.id)
    let claim=try await store.claimSkillLearning(questionID:q.id)
    try await store.finishSkillLearning(attempt:try XCTUnwrap(claim),proposal:proposal(signature),report:"{}",model:"fixture")
    let candidates=try await store.listSkillCandidates()
    return try XCTUnwrap(candidates.first { $0.proposal.signature==signature })
  }
  private func assess(_ store:MathQuestionStore,_ candidateID:String,_ q:MathQuestionRecord,_ index:Int,_ boundary:String) async throws {
    let review=try await store.reviewSolution(questionID:q.id,solutionID:"s-\(index)",status:"confirmed",scope:"答案及解题过程",note:"人工核验原题全部条件",correction:"")
    try await store.assessSkillCandidate(id:candidateID,questionID:q.id,solutionID:"s-\(index)",reviewID:review.id,boundary:boundary,note:"核验适用边界")
  }
  private func report(_ attempt:MathSkillResearchAttempt,_ approved:Bool) throws -> String {
    let proposal=(attempt.learningObject["candidate"] as! [String:Any])["proposal"]!
    let checks=["mathematics","grade_scope","conditions","counterexamples","diagram_grounding"].map {
      ["dimension":$0,"passed":true,"reason":"Protocol fixture, not real model accuracy"] as [String:Any]
    }
    var result:[String:Any] = ["version":1,"coverage":"uncovered","covered_method_ids":[],"reason":"Explicit review","pattern_key":attempt.proposal.signature,"pattern_evidence_ids":attempt.evidence.filter { $0.boundary=="applies" }.map(\.questionID),"proposal":proposal,"review":["checks":checks,"recommendation":"ready_for_human"],"status":approved ? "approved" : "awaiting_human"]
    var checkpoint=result
    checkpoint.removeValue(forKey:"version")
    checkpoint["evidence"]=attempt.learningObject["evidence"]
    checkpoint["existing_patterns"]=[]
    checkpoint["model_calls"]=1
    if approved { result["human_decision"]=["action":"approve","reviewer":"test user","note":"Checked current source and boundaries"] }
    if approved { checkpoint["human_decision"]=result["human_decision"] }
    result["workflow_state"]=["version":1,"state":checkpoint]
    return String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self)
  }

  func testEditsPreserveExactPreviousRevisionsWithoutGrantingApproval() async throws {
    let store = MathQuestionStore(directory: root.appendingPathComponent("edit-history"))
    let q = try await question(store, 0)
    let draft = try await candidate(store, q, "shared-gap-change")
    try await assess(store, draft.id, q, 0, "applies")
    let originalEvidence = try await store.candidateEvidence(id: draft.id)
    var first = draft.proposal
    first.instructions = "收窄后的第一版步骤"
    try await store.editSkillCandidate(id: draft.id, proposal: first)
    var second = first
    second.exclusions = "新增独立反例边界"
    try await store.editSkillCandidate(id: draft.id, proposal: second)
    let events = try await store.candidateEvents(id: draft.id)
    XCTAssertEqual(events.map(\.decision), ["previous_revision", "previous_revision"])
    XCTAssertEqual(events.map(\.revision), [draft.revision, draft.revision + 1])
    XCTAssertEqual(events.map(\.proposal), [draft.proposal, first])
    let current = try await store.listSkillCandidates().first { $0.id == draft.id }
    XCTAssertEqual(current?.proposal, second)
    XCTAssertEqual(current?.revision, draft.revision + 2)
    XCTAssertEqual(current?.status, "draft")
    XCTAssertNil(current?.publishedVersionID)
    let evidence = try await store.candidateEvidence(id: draft.id)
    XCTAssertEqual(evidence, originalEvidence)
    let usable = try await store.candidateCurrentEvidence(id: draft.id)
    XCTAssertTrue(usable.isEmpty)
    do { _ = try await store.publishSkillCandidate(id: draft.id); XCTFail("An edit is not approval") } catch {}
    var invalid = second
    invalid.title = " "
    do { try await store.editSkillCandidate(id: draft.id, proposal: invalid); XCTFail("Invalid edit must fail") } catch {}
    let afterFailure = try await store.candidateEvents(id: draft.id)
    XCTAssertEqual(afterFailure, events)
    let reports = try await store.skillLearningReports(questionID: q.id)
    let historyReports = reports.filter { $0.report.contains("previous_revision") }
    XCTAssertEqual(historyReports.count, 2)
    XCTAssertTrue(historyReports.allSatisfy { $0.model == "native" })
    let backup = root.appendingPathComponent("edit-history-backup")
    try await store.backup(to: backup)
    await store.close()
    let restored = MathQuestionStore(directory: backup)
    let restoredEvents = try await restored.candidateEvents(id: draft.id)
    XCTAssertEqual(restoredEvents, events)
    await restored.close()
  }

  func testRejectionReasonSurvivesBackupAndAIEventsCannotImpersonateUser() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("library"))
    let q=try await question(store,0),draft=try await candidate(store,q,"shared-gap-change")
    do { try await store.rejectSkillCandidate(id:draft.id,note:" "); XCTFail("Reason required") } catch {}
    try await store.rejectSkillCandidate(id:draft.id,note:"此模式缺少独立条件；保留观察依据")
    let events=try await store.candidateEvents(id:draft.id)
    XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.reason,"此模式缺少独立条件；保留观察依据")
    do { try await store.rejectSkillCandidate(id:draft.id,note:"覆盖旧决定"); XCTFail("No overwrite") } catch {}
    let backup=root.appendingPathComponent("backup"); try await store.backup(to:backup); await store.close()
    let restored=MathQuestionStore(directory:backup)
    let restoredEvents=try await restored.candidateEvents(id:draft.id); XCTAssertEqual(restoredEvents,events)
    try await restored.enqueueSkillLearning(questionID:q.id)
    let claim=try await restored.claimSkillLearning(questionID:q.id)
    if let claim {
      do { try await restored.finishSkillLearning(attempt:claim,proposal:nil,report:"{\"native_candidate_event\":{}}",model:"AI"); XCTFail("Native decisions cannot be forged") } catch {}
    }
    await restored.close()
  }

  func testMergePreservesSourceHistoryAndInvalidatesHumanEvidence() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("merge"))
    let q0=try await question(store,0),q1=try await question(store,1),q2=try await question(store,2)
    let target=try await candidate(store,q0,"shared-gap-change"),source=try await candidate(store,q1,"repeated-gap-change")
    try await assess(store,target.id,q0,0,"applies"); try await assess(store,target.id,q2,2,"excluded")
    let before=try await store.candidateEvidence(id:target.id)
    try await store.mergeSkillCandidates(sourceID:source.id,targetID:target.id,note:"原题共享同一不变量，统一审校")
    let after=try await store.listSkillCandidates()
    XCTAssertEqual(after.first { $0.id==target.id }?.revision,target.revision+1)
    XCTAssertEqual(after.first { $0.id==source.id }?.status,"rejected")
    let evidence=try await store.candidateEvidence(id:target.id)
    XCTAssertTrue(before.allSatisfy { evidence.contains($0) })
    let current=evidence.filter { $0.candidateRevision==target.revision+1 }
    XCTAssertEqual(Set(current.map(\.questionID)),[q0.id,q1.id,q2.id])
    XCTAssertTrue(current.allSatisfy { $0.boundary=="observed" && $0.origin=="ai" && $0.reviewID==nil })
    do { _=try await store.candidateResearchAttempt(id:target.id); XCTFail("Merge requires fresh human assessment") } catch {}
    let sourceEvents=try await store.candidateEvents(id:source.id)
    XCTAssertEqual(sourceEvents.first?.decision,"merged_into"); XCTAssertEqual(sourceEvents.first?.relatedCandidateID,target.id)
    let backup=root.appendingPathComponent("merge-backup"); try await store.backup(to:backup); await store.close()
    let restored=MathQuestionStore(directory:backup)
    let restoredEvidence=try await restored.candidateEvidence(id:target.id); XCTAssertEqual(restoredEvidence,evidence)
    let events=try await restored.candidateEvents(id:source.id); XCTAssertEqual(events,sourceEvents)
    await restored.close()
  }

  @MainActor
  func testApprovedExportPreservesSourceAndExactVersionAndNeverOverwrites() async throws {
    let store=MathQuestionStore(directory:root.appendingPathComponent("export"))
    let q0=try await question(store,0),q1=try await question(store,1),q2=try await question(store,2)
    let draft=try await candidate(store,q0,"shared-gap-change")
    do { _=try await store.candidateSkillExport(id:draft.id); XCTFail("Unapproved export forbidden") } catch {}
    try await assess(store,draft.id,q0,0,"applies"); try await assess(store,draft.id,q1,1,"applies"); try await assess(store,draft.id,q2,2,"excluded")
    let attempt=try await store.candidateResearchAttempt(id:draft.id)
    try await store.recordCandidateResearch(attempt:attempt,report:report(attempt,false),model:"fixture")
    try await store.recordCandidateResearch(attempt:attempt,report:report(attempt,true),model:"fixture")
    let method=try await store.publishSkillCandidate(id:draft.id)
    let export=try await store.candidateSkillExport(id:draft.id)
    XCTAssertEqual(export.method.versionID,method.versionID)
    let destination=root.appendingPathComponent("skills-export"); try export.write(to:destination)
    let folder=destination.appendingPathComponent(export.name)
    XCTAssertEqual(try String(contentsOf:folder.appendingPathComponent("references/source.md")),draft.proposal.instructions)
    let provenance=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("references/provenance.json"))) as! [String:Any]
    XCTAssertEqual(provenance["method_version_id"] as? String,method.versionID)
    let validator=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/validate-math-skills.py")
    let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/env"); process.arguments=["python3",validator.path,destination.path]
    let pipe=Pipe(); process.standardOutput=pipe; process.standardError=pipe
    try process.run(); let output=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus,0,String(decoding:output,as:UTF8.self))
    do { try export.write(to:destination); XCTFail("Existing export cannot be replaced") } catch {}
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let suite = "candidate-sync-audit-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let sync = MathSkillProjectSyncCoordinator(store: store, defaults: defaults)
    try sync.selectProject(project); await sync.synchronize()
    XCTAssertTrue(sync.status.hasPrefix("已核对并同步"), sync.status)
    let snapshots = try await store.projectSkillSnapshots()
    let published = try XCTUnwrap(snapshots.first { $0.method.versionID == method.versionID })
    let frozen = try XCTUnwrap(published.candidateReview)
    XCTAssertEqual(frozen.candidate, export.candidate)
    XCTAssertEqual(frozen.evidence, export.evidence)
    XCTAssertEqual(frozen.researchJSON, export.researchJSON)
    XCTAssertEqual(frozen.events, export.events)
    XCTAssertEqual(published.profile?.status, "approved")
    let publishedArtifact = try MathSkillProjectArtifact(snapshot: published)
    let publishedDirectory = project.appendingPathComponent(publishedArtifact.relativePath)
    try publishedArtifact.verify(at: publishedDirectory)
    let reviewFile = publishedDirectory.appendingPathComponent(publishedArtifact.name + "/references/candidate-review.json")
    XCTAssertEqual(try JSONDecoder().decode(MathProjectCandidateReviewSnapshot.self, from: Data(contentsOf: reviewFile)), frozen)
    let skillProcess = Process(); skillProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    skillProcess.arguments = ["python3", validator.path, publishedDirectory.path]
    let skillPipe = Pipe(); skillProcess.standardOutput = skillPipe; skillProcess.standardError = skillPipe
    try skillProcess.run(); let skillOutput = skillPipe.fileHandleForReading.readDataToEndOfFile(); skillProcess.waitUntilExit()
    XCTAssertEqual(skillProcess.terminationStatus, 0, String(decoding: skillOutput, as: UTF8.self))
    var oversized = published
    oversized.candidateReview = .init(candidate: frozen.candidate, evidence: frozen.evidence,
      researchJSON: String(repeating: "e", count: 4_000_001), events: frozen.events)
    XCTAssertThrowsError(try MathSkillProjectArtifact(snapshot: oversized)) { error in
      XCTAssertTrue(error.localizedDescription.contains("未截断或同步"), error.localizedDescription)
    }
    XCTAssertEqual(try JSONDecoder().decode(MathProjectCandidateReviewSnapshot.self, from: Data(contentsOf: reviewFile)), frozen)
    _=try await store.saveMethod(id:method.id,title:method.title,category:method.category,instructions:"后续修订的不同方法")
    let historical=try await store.candidateSkillExport(id:draft.id); XCTAssertEqual(historical.method,method)
    do { try await store.mergeSkillCandidates(sourceID:draft.id,targetID:draft.id,note:"不能合并发布版本"); XCTFail("Published history immutable") } catch {}
    try await store.revokeSkillMethod(versionID:method.versionID,note:"新反例，停止复用")
    await sync.synchronize()
    XCTAssertTrue(sync.status.hasPrefix("已核对并同步"), sync.status)
    let revokedSnapshots = try await store.projectSkillSnapshots()
    let revoked = try XCTUnwrap(revokedSnapshots.first { $0.method.versionID == method.versionID })
    XCTAssertEqual(revoked.candidateReview, frozen)
    XCTAssertEqual(revoked.profile?.status, "revoked")
    XCTAssertFalse(revoked.automaticEligible)
    let revokedArtifact = try MathSkillProjectArtifact(snapshot: revoked)
    XCTAssertNotEqual(revokedArtifact.sha256, publishedArtifact.sha256)
    try publishedArtifact.verify(at: publishedDirectory)
    let revokedDirectory = project.appendingPathComponent(revokedArtifact.relativePath)
    try revokedArtifact.verify(at: revokedDirectory)
    XCTAssertEqual(try JSONDecoder().decode(MathProjectCandidateReviewSnapshot.self,
      from: Data(contentsOf: revokedDirectory.appendingPathComponent(revokedArtifact.name + "/references/candidate-review.json"))), frozen)
    do { _=try await store.candidateSkillExport(id:draft.id); XCTFail("Revoked cannot export as reusable approved skill") } catch {}
    if let persistent=ProcessInfo.processInfo.environment["MATH_SKILL_EXPORT_FIXTURE"] {
      try export.write(to:URL(fileURLWithPath:persistent))
    }
    let backup = root.appendingPathComponent("candidate-sync-backup")
    try await store.backup(to: backup); await store.close()
    let restored = MathQuestionStore(directory: root.appendingPathComponent("candidate-restored"))
    _ = try await restored.restoreBackup(from: backup)
    let restoredSnapshots = try await restored.projectSkillSnapshots()
    XCTAssertEqual(restoredSnapshots.first { $0.method.versionID == method.versionID }, revoked)
    await restored.close()
  }
}
