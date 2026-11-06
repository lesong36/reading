import Foundation
import XCTest
@testable import VocabCapture

private actor LearningProbe {
  var calls = 0
  var imageCounts: [Int] = []
  var inputIDs: [[String]] = []
  var answerInputs: [[String: String]] = []
  let pauseFirst: Bool
  let matchingPrefix: String?
  init(pauseFirst: Bool = false, matchingPrefix: String? = nil) { self.pauseFirst=pauseFirst; self.matchingPrefix=matchingPrefix }
  func run(_ data:Data) async throws -> String {
    calls += 1
    if pauseFirst && calls == 1 { try await Task.sleep(nanoseconds:10_000_000_000) }
    let input=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    let sources=try XCTUnwrap(input["evidence"] as? [[String:Any]])
    let photos=try XCTUnwrap(input["originals"] as? [[String:String]])
    answerInputs.append(Dictionary(uniqueKeysWithValues: sources.map {
      ($0["question_id"] as! String, ($0["verification"] as! String) + ":" + ($0["answer"] as! String))
    }))
    imageCounts.append(photos.count)
    inputIDs.append(sources.compactMap { $0["question_id"] as? String })
    XCTAssertEqual(Set(photos.compactMap{$0["question_id"]}),Set(sources.compactMap{$0["question_id"] as? String}))
    let matched = sources.filter { source in
      matchingPrefix.map { (source["text"] as? String ?? "").hasPrefix($0) } ?? true
    }.compactMap { $0["question_id"] as? String }
    var output:[String:Any]=["version":1,"coverage":"uncovered","reason":"Protocol fixture; not real-model accuracy",
      "pattern_key":"shared-invariant","pattern_evidence_ids":matched,"status":"observing"]
    if matched.count >= 3 {
      output["proposal"]=["title":"待核验的新方法","category":"四年级算术","instructions":"识别共同不变量，再比较两个过程的变化，逐条检查原题条件并排除不适用的情况。",
        "trigger":"共享同一不变量","prerequisites":["整数四则"],"exclusions":["缺少条件时不套用"],"diagram_templates":["table"],
        "evidence_ids":matched,"review_notes":"必须人工确认" ]
      output["status"]="awaiting_human"
    }
    return String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self)
  }
}

@MainActor
final class MathSkillLearningCoordinatorTests:XCTestCase {
  private func store()->MathQuestionStore {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("learning-coordinator-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at:root) }
    return MathQuestionStore(directory:root)
  }
  private func question(_ store:MathQuestionStore,_ index:Int) async throws -> MathQuestionRecord {
    try await store.save(.init(captureID:"photo-\(index)",imageData:MathDiagramRenderer.renderPNG([MathDiagramFixtures.bar,MathDiagramFixtures.area,MathDiagramFixtures.state][index % 3]),ocrText:"独立原题 \(index)"))
  }
  private func coordinator(_ store:MathQuestionStore,_ probe:LearningProbe,enabled:Bool=true)->MathSkillLearningCoordinator {
    .init(store:store,enabled:enabled,configuration:{
      .init(configuration:.init(baseURL:"https://example.com",model:"fixture",apiKey:""),api:.chatCompletions,directConnection:false)
    },analyze:{ data,_,_,_ in try await probe.run(data) })
  }
  private func settle(_ condition:() async throws ->Bool) async throws {
    for _ in 0..<200 { if try await condition(){return}; try await Task.sleep(nanoseconds:10_000_000) }
    XCTFail("Learning coordinator did not settle")
  }

  func testDiscoveryUsesOnlyLatestConfirmedProcessCorrectionWithoutChangingOriginal() async throws {
    for downgrade in [nil, "rejected", "answer-only", "unverified"] as [String?] {
      let db = store(), probe = LearningProbe()
      let q = try await db.save(.init(captureID: UUID().uuidString,
        imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), ocrText: "修正传输测试",
        solutions: [.init(id: "answer", question: "解题", answer: "原始错误过程", model: "fixture")]))
      _ = try await db.reviewSolution(questionID: q.id, solutionID: "answer", status: "confirmed",
        scope: "答案及解题过程", note: "隔离测试核验", correction: "已核验的完整修正过程")
      if let downgrade {
        _ = try await db.reviewSolution(questionID: q.id, solutionID: "answer",
          status: downgrade == "answer-only" ? "confirmed" : downgrade,
          scope: downgrade == "answer-only" ? "最终答案" : "答案及解题过程",
          note: "最新核验替代此前结论", correction: "这段不能作为已核验完整过程")
      }
      let runner = coordinator(db, probe)
      await runner.enqueue(q.id)
      try await settle { try await db.skillLearningReports(questionID: q.id).count == 1 }
      await runner.setEnabled(false)
      let inputs = await probe.answerInputs
      XCTAssertEqual(inputs.first?[q.id], downgrade == nil
        ? "confirmed:已核验的完整修正过程" : "unverified:原始错误过程")
      let saved = try await db.solutions(questionID: q.id)
      XCTAssertEqual(saved.first?.answer, "原始错误过程")
      await db.close()
    }
  }

  func testUnsolvedPhotoSaveIsIndependentAndRepeatedSourcesRemainUnapproved() async throws {
    let db=store(),probe=LearningProbe()
    let first=try await question(db,0),second=try await question(db,1),third=try await question(db,2)
    let runner=coordinator(db,probe,enabled:false)
    await runner.enqueue(first.id)
    let before=await probe.calls; XCTAssertEqual(before,0)
    let answers=try await db.solutions(questionID:first.id); XCTAssertTrue(answers.isEmpty)
    await runner.setEnabled(true)
    try await settle { try await db.skillLearningReports(questionID:first.id).count == 1 }
    await runner.setEnabled(false)
    let candidates=try await db.listSkillCandidates(); XCTAssertEqual(candidates.count,1)
    let evidence=try await db.candidateEvidence(id:try XCTUnwrap(candidates.first?.id))
    XCTAssertEqual(Set(evidence.map(\.questionID)),[first.id,second.id,third.id])
    let counts=await probe.imageCounts; XCTAssertEqual(counts,[3])
    let methods=try await db.automaticMethods(); XCTAssertTrue(methods.isEmpty)
    await runner.enqueue(first.id); await runner.setEnabled(true)
    try await Task.sleep(nanoseconds:30_000_000)
    await runner.setEnabled(false)
    let calls=await probe.calls; XCTAssertEqual(calls,1)
    await db.close()
  }
  func testDisableCancelsAndReenableRecoversPendingPhotoWithoutLosingTheJob() async throws {
    let db=store(),probe=LearningProbe(pauseFirst:true)
    let record=try await question(db,0)
    let runner=coordinator(db,probe)
    await runner.enqueue(record.id)
    try await settle { await probe.calls == 1 }
    await runner.setEnabled(false)
    let pending=try await db.pendingSkillLearningJobs(); XCTAssertEqual(pending.map(\.questionID),[record.id])
    let reports=try await db.skillLearningReports(questionID:record.id); XCTAssertTrue(reports.isEmpty)
    await runner.setEnabled(true)
    try await settle { try await db.skillLearningReports(questionID:record.id).count == 1 }
    await runner.setEnabled(false)
    let calls=await probe.calls; XCTAssertEqual(calls,2)
    let image=try await db.originalImage(questionID:record.id); XCTAssertFalse(image.isEmpty)
    await db.close()
  }

  func testOlderObservedPatternRetrievesOriginalsBeyondRecentWindowWithoutCountingDuplicatePhotos() async throws {
    let db = store(), first = try await question(db, 0), second = try await question(db, 1)
    let original = try await db.originalImage(questionID: first.id)
    let alias = try await db.save(.init(captureID: "same-photo-again", imageData: original, ocrText: "独立原题重存"))
    try await db.enqueueSkillLearning(questionID: first.id)
    let claimed = try await db.claimSkillLearning(questionID: first.id)
    let observation = try XCTUnwrap(claimed)
    let snapshots = try await [db.learningSnapshot(questionID: second.id), db.learningSnapshot(questionID: alias.id)]
    try await db.finishSkillLearning(attempt: observation, proposal: nil, report: "{}", model: "fixture", patternKey: "shared-invariant", evidenceSnapshots: snapshots)
    for index in 0..<12 {
      var drawing = MathDiagramFixtures.bar
      drawing.title = "无关干扰图 \(index)"
      _ = try await db.save(.init(captureID: "unrelated-\(index)", imageData: MathDiagramRenderer.renderPNG(drawing), ocrText: "无关题目 \(index)"))
    }
    let current = try await question(db, 2)
    let probe = LearningProbe(matchingPrefix: "独立原题"), runner = coordinator(db, probe)
    await runner.enqueue(current.id)
    try await settle { try await db.skillLearningReports(questionID: current.id).count == 1 }
    await runner.setEnabled(false)
    let inputs = await probe.inputIDs
    XCTAssertEqual(inputs.count, 2, "One bounded recent comparison and one historical comparison")
    XCTAssertEqual(inputs[0].count, 8)
    XCTAssertFalse(inputs[0].contains(second.id))
    XCTAssertEqual(inputs[1].first, current.id)
    XCTAssertTrue(inputs[1].contains(second.id))
    XCTAssertEqual(inputs[1].count, 3, "Re-saved original cannot count as independent evidence")
    let candidates = try await db.listSkillCandidates()
    let candidate = try XCTUnwrap(candidates.first)
    XCTAssertEqual(candidate.status, "draft")
    let methods = try await db.automaticMethods()
    XCTAssertTrue(methods.isEmpty, "Discovery does not certify the new method")
    await db.close()
  }

  func testRealLangGraphHumanInterruptPersistsThenPublishesThroughNativeCoordinator() async throws {
    let package=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let engine=package.appendingPathComponent("question-engine")
    let python=engine.appendingPathComponent(".venv/bin/python")
    guard FileManager.default.isExecutableFile(atPath:python.path) else { throw XCTSkip("Requires the existing local question-engine runtime") }
    let source="""
      import asyncio,json,sys
      from langchain_core.messages import AIMessage,HumanMessage
      from math_learning import learn_skills,DIMENSIONS
      from question_engine import learning_originals
      class ResearchModel:
          def __init__(self,resuming): self.resuming=resuming
          async def ainvoke(self,*args,**kwargs):
              if self.resuming: raise AssertionError('Human resume must not call the model')
              return AIMessage(content=json.dumps({'checks':[{'dimension':d,'passed':True,'reason':'Protocol fixture only; no accuracy certification'} for d in sorted(DIMENSIONS)],'recommendation':'ready_for_human'}))
      async def main():
          learning,messages=learning_originals(json.load(sys.stdin),[HumanMessage('Explicit human candidate review')])
          output,details=await learn_skills(ResearchModel('workflow_state' in learning),messages,[],learning)
          print(output)
      asyncio.run(main())
      """
    let analyze:MathSkillLearningCoordinator.Analyze={ data,_,_,_ in
      try await Task.detached {
        let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        process.executableURL=python; process.currentDirectoryURL=engine; process.arguments=["-c",source]
        process.standardInput=input; process.standardOutput=output; process.standardError=errors
        try process.run(); try input.fileHandleForWriting.write(contentsOf:data); try input.fileHandleForWriting.close()
        let result=output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics=errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus==0 else { throw MathQuestionStoreError.database(String(decoding:diagnostics,as:UTF8.self)) }
        return String(decoding:result,as:UTF8.self)
      }.value
    }
    let db=store()
    let proposal=MathSkillProposal(signature:"shared-invariant",title:"协议回归候选",category:"四年级",
      instructions:String(repeating:"先识别共同不变量，比较变化量，使用算术逐条核对题目条件，不把缺条件题作为适用例。",count:4),
      trigger:"共享同一不变量",constraints:"原图及人工核验为准",exclusions:"条件缺失不适用",prerequisites:"整数四则",supportedDiagrams:["table"])
    var questions:[MathQuestionRecord]=[]
    for index in 0..<3 {
      questions.append(try await db.save(.init(captureID:"research-\(index)",imageData:MathDiagramRenderer.renderPNG([MathDiagramFixtures.bar,MathDiagramFixtures.area,MathDiagramFixtures.state][index]),ocrText:"独立教研题 \(index)",solutions:[.init(id:"s-\(index)",question:"解题",answer:"协议测试过程 \(index)",model:"fixture") ])))
    }
    try await db.enqueueSkillLearning(questionID:questions[0].id)
    let claimed=try await db.claimSkillLearning(questionID:questions[0].id),attempt=try XCTUnwrap(claimed)
    try await db.finishSkillLearning(attempt:attempt,proposal:proposal,report:"{}",model:"fixture")
    let candidates=try await db.listSkillCandidates(),candidate=try XCTUnwrap(candidates.first)
    for (index,q) in questions.enumerated() {
      let review=try await db.reviewSolution(questionID:q.id,solutionID:"s-\(index)",status:"confirmed",scope:"答案及解题过程",note:"Human protocol fixture",correction:"")
      try await db.assessSkillCandidate(id:candidate.id,questionID:q.id,solutionID:"s-\(index)",reviewID:review.id,boundary:index==2 ? "excluded" : "applies",note:"Checked applicability boundary")
    }
    func runner(_ store:MathQuestionStore)->MathSkillLearningCoordinator {
      .init(store:store,enabled:false,configuration:{ .init(configuration:.init(baseURL:"https://example.com",model:"fixture",apiKey:""),api:.chatCompletions,directConnection:false) },analyze:analyze)
    }
    try await runner(db).reviewCandidate(id:candidate.id,approve:false,note:"")
    let backup=db.directory.deletingLastPathComponent().appendingPathComponent("resume-\(UUID().uuidString)")
    addTeardownBlock{try? FileManager.default.removeItem(at:backup)}
    try await db.backup(to:backup); await db.close()
    let restored=MathQuestionStore(directory:backup)
    try await runner(restored).reviewCandidate(id:candidate.id,approve:true,note:"用户已核对数学、学段、适用及排除条件")
    let methods=try await restored.automaticMethods()
    XCTAssertEqual(methods.count,1); XCTAssertEqual(methods.first?.title,proposal.title)
    XCTAssertTrue(methods.first?.instructions.contains(proposal.exclusions)==true)
    let published=try await restored.listSkillCandidates(); XCTAssertEqual(published.first?.status,"published")
    await restored.close()
  }
}
