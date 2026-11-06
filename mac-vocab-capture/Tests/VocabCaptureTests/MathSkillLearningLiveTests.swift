import AppKit
import CSQLite
import CryptoKit
import PDFKit
import XCTest
@testable import VocabCapture

/// Opt-in packaged engine + real provider, entirely outside the production library.
/// The human actions below are explicit test fixtures, not user approvals.
@MainActor
final class MathSkillLearningLiveTests: XCTestCase {
  func testSelectionFailureDiagnosticsKeepNativeCategoriesAndDiscardArbitraryMessages() throws {
    let blocked = safeSelectionFailure(MathMethodMatchError.prerequisiteNotSatisfied)
    XCTAssertEqual(blocked["code"] as? String, "skillsPrerequisite")
    XCTAssertEqual(blocked["category"] as? String, "prerequisite_block")
    XCTAssertEqual(blocked["reason"] as? String, MathMethodMatchError.prerequisiteNotSatisfied.localizedDescription)
    let invalid = safeSelectionFailure(MathMethodMatchError.invalidOutput)
    XCTAssertEqual(invalid["category"] as? String, "selection_protocol")
    let unknown = safeSelectionFailure(NSError(domain: "untrusted-fixture", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "DO_NOT_ARCHIVE_PROVIDER_DETAIL_FIXTURE"]))
    XCTAssertEqual(unknown["code"] as? String, "unclassified_native_error")
    XCTAssertEqual(unknown["raw_error_recorded"] as? Bool, false)
    let encoded = try JSONSerialization.data(withJSONObject: unknown)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("DO_NOT_ARCHIVE_PROVIDER_DETAIL_FIXTURE"))
  }

  /// Unlike the empty-catalogue lifecycle fixture below, this exercises coverage
  /// decisions against every shipped method. It makes no human approval.
  func testReadOnlyLearningJobStatusContinuesPendingAndRunningButStopsFailed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("learning-job-status-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("questions.sqlite")
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
    let handle = try XCTUnwrap(database)
    defer { sqlite3_close(handle) }
    XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE skill_learning_jobs(question_id TEXT PRIMARY KEY,status TEXT,error TEXT); INSERT INTO skill_learning_jobs VALUES ('fixture','pending','never read this arbitrary provider detail');", nil, nil, nil), SQLITE_OK)
    for status in ["pending", "running", "failed", "ready"] {
      XCTAssertEqual(sqlite3_exec(handle, "UPDATE skill_learning_jobs SET status='" + status + "' WHERE question_id='fixture'", nil, nil, nil), SQLITE_OK)
      let read = try Self.readOnlyLearningJobStatus(directory: root, questionID: "fixture")
      XCTAssertEqual(read, status)
      XCTAssertEqual(read == "failed", status == "failed")
    }
    XCTAssertNil(try Self.readOnlyLearningJobStatus(directory: root, questionID: "missing"))
  }

  func testOneStrokeFixtureOracleRejectsRepeatedMissingAndInventedEdges() {
    let edges = ["AB", "BC", "CD", "DA", "BD"]
    XCTAssertEqual(Self.oddVertices(edges: edges), Set(["B", "D"]))
    XCTAssertTrue(Self.validTrail(["B", "A", "D", "C", "B", "D"], edges: edges))
    XCTAssertTrue(Self.validTrail(["D", "B", "C", "D", "A", "B"], edges: edges))
    XCTAssertFalse(Self.validTrail(["B", "A", "B", "C", "D", "B"], edges: edges))
    XCTAssertFalse(Self.validTrail(["B", "A", "C", "D", "B", "D"], edges: edges))
    XCTAssertFalse(Self.validTrail(["B", "A", "D", "C", "B"], edges: edges))
    XCTAssertEqual(Self.oddVertices(edges: ["OA", "OB", "OC"]), Set(["O", "A", "B", "C"]))
    XCTAssertFalse(Self.validTrail(["A", "O", "B", "O"], edges: ["OA", "OB", "OC"]))
  }

  func testFullCatalogueCoverageAndUncoveredPatternStaysDraft() async throws {
    guard let output = ProcessInfo.processInfo.environment["MATH_LEARNING_CATALOGUE_ARTIFACTS"],
      let executable = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_ENGINE"] else {
      throw XCTSkip("Requires explicit full-catalogue learning live configuration")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? .init(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let model = MathTagModelConfiguration(configuration: preferences.configuration(fallingBackTo: fallback),
      api: preferences.selectedAPI, directConnection: preferences.selectedDirectConnection)
    let arguments = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_SOURCE"].map { [$0] } ?? []
    let sourceHashes: [String: String]
    if let source = arguments.first {
      let directory = URL(fileURLWithPath: source).deletingLastPathComponent()
      let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix("test_") }
      sourceHashes = try Dictionary(uniqueKeysWithValues: files.map { file in
        (file.lastPathComponent, SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined())
      })
    } else {
      sourceHashes = ["packaged_engine": SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable)))
        .map { String(format: "%02x", $0) }.joined()]
    }
    let client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: executable), arguments: arguments))
    let catalogue = try MathSkillCatalogue.load()
    XCTAssertEqual(catalogue.skills.count, 49, "Revisit this acceptance scope when the shipped catalogue changes")
    let definitions = Dictionary(uniqueKeysWithValues: catalogue.skills.map { ($0.name, $0.sourceID) })
    var observations: [[String: Any]] = []
    func modelCalls(_ result: [String: Any]) -> Int? {
      ((result["workflow_state"] as? [String: Any])?["state"] as? [String: Any])?["model_calls"] as? Int
    }
    func writeReport() throws {
      let summary: [String: Any] = ["scope": "real provider; all shipped methods supplied; six independent synthetic original photos, not certification of all methods",
        "catalogue_count": catalogue.skills.count, "observations": observations,
        "expected_decisions": 4, "completed_decisions": observations.filter { $0["case"] != nil }.count,
        "failed_decisions": observations.filter { $0["acceptance_passed"] as? Bool == false }.count,
        "model_calls": observations.compactMap { $0["model_calls"] as? Int }.reduce(0, +),
        "original_photo_count": 6, "engine_source_hashes": sourceHashes,
        "engine_kind": arguments.isEmpty ? "packaged" : "source", "real_user_approval": false,
        "production_writes": false,
        "acceptance_passed": observations.count == 4 && observations.allSatisfy { $0["acceptance_passed"] as? Bool == true }]
      try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("report.json"), options: .atomic)
    }
    func runner(_ store: MathQuestionStore) -> MathSkillLearningCoordinator {
      .init(store: store, enabled: true, configuration: { model }, analyze: { data, image, methods, model in
        XCTAssertEqual(methods.count, 49)
        return try await client.learnSkills(learning: data, imageData: image, methods: methods,
          configuration: model.configuration, api: model.api, directConnection: model.directConnection)
      })
    }
    func report(_ store: MathQuestionStore, question: MathQuestionRecord) async throws -> [String: Any] {
      for _ in 0..<800 {
        if let saved = try await store.skillLearningReports(questionID: question.id).last {
          return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.report.utf8)) as? [String: Any])
        }
        try await Task.sleep(nanoseconds: 150_000_000)
      }
      throw NSError(domain: "MathSkillLearningCatalogueAcceptance", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Background learning exceeded the explicit 120-second acceptance deadline"])
    }
    let covered = MathQuestionStore(directory: destination.appendingPathComponent("covered-library"))
    _ = try await covered.importBundledMathSkills(catalogue)
    let baseline = try await covered.automaticMethods()
    let coveredRunner = runner(covered)
    let known: [(String, String, [String])] = [
      ("甲乙共有50个苹果，甲比乙多10个。甲和乙各有多少个？", "去掉差后50−10=40；乙40÷2=20，甲20+10=30。30+20=50，30−20=10。", ["sum-and-difference"]),
      ("一个数先加5，再乘3，得到51。原来的数是多少？", "倒过来51÷3=17，17−5=12。验算(12+5)×3=51。", ["reverse-operations"]),
      ("甲乙原有的苹果各自先乘2再加3，两个结果相加是86。甲原来比乙多10个。甲乙原来各有多少个？", "先撤去两次加3：86−3−3=80，再除2得原来总数40。去掉差40−10=30，乙30÷2=15，甲15+10=25。验算53+33=86，25−15=10。", ["reverse-operations", "sum-and-difference"]),
    ]
    do {
      for (index, fixture) in known.enumerated() {
        let question = try await savePhoto(covered, index: index, text: fixture.0, answer: fixture.1)
        try await covered.originalImage(questionID: question.id).write(to: destination.appendingPathComponent("covered-\(index).png"))
        await coveredRunner.enqueue(question.id)
        let result = try await report(covered, question: question)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
          .write(to: destination.appendingPathComponent("covered-\(index).json"))
        let selected = Set(result["covered_method_ids"] as? [String] ?? [])
        let expected = Set(try fixture.2.map { try XCTUnwrap(definitions[$0]) })
        let matched = Set(result["pattern_evidence_ids"] as? [String] ?? [])
        let candidates = try await covered.listSkillCandidates()
        let after = try await covered.automaticMethods()
        observations.append(["case": "covered-\(index)", "expected_coverage": "covered",
          "expected_methods": fixture.2, "coverage": result["coverage"] as Any,
          "selected_methods": Array(selected).sorted(), "status": result["status"] as Any,
          "model_calls": modelCalls(result) as Any, "reason": result["reason"] as Any,
          "pattern_evidence_ids": result["pattern_evidence_ids"] as Any,
          "expected_pattern_evidence_ids": [question.id], "candidate_count": candidates.count,
          "methods_unchanged": after == baseline,
          "acceptance_passed": result["coverage"] as? String == "covered" && result["status"] as? String == "covered"
            && expected.isSubset(of: selected) && matched == [question.id] && candidates.isEmpty
            && !(result["proposal"] is [String: Any]) && modelCalls(result) != nil && after == baseline])
        try writeReport()
        XCTAssertEqual(result["coverage"] as? String, "covered", "Existing reusable methods should prevent a duplicate skill")
        XCTAssertEqual(result["status"] as? String, "covered")
        XCTAssertTrue(expected.isSubset(of: selected), "Coverage must identify the actual methods, including the existing combination")
        XCTAssertEqual(matched, [question.id],
          "Sharing one downstream method does not make the complete quantity relations and solution steps identical")
        XCTAssertNotNil(modelCalls(result))
        XCTAssertFalse(result["proposal"] is [String: Any])
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(after, baseline, "Coverage evaluation must not publish or alter any method")
      }
      await coveredRunner.setEnabled(false)
      await covered.close()
    } catch {
      observations.append(["phase": "covered", "failure": "acceptance did not complete"])
      try? writeReport()
      await coveredRunner.setEnabled(false); await covered.close(); await client.shutdown()
      throw error
    }
    let uncovered = MathQuestionStore(directory: destination.appendingPathComponent("uncovered-library"))
    _ = try await uncovered.importBundledMathSkills(catalogue)
    let uncoveredBaseline = try await uncovered.automaticMethods()
    let uncoveredRunner = runner(uncovered)
    // The catalogue's shared-point counting and periodic cycles do not contain
    // the connected-graph odd-degree criterion for a single non-repeating trail.
    let novel: [(String, String)] = [
      ("一笔画：四点A、B、C、D。边是AB、BC、CD、DA、AC。能否不抬笔且每条边只画一次？应从哪里开始？", "图连通，A和C各连3条边，B和D各连2条。恰有2个奇点，可从A到C：A→B→C→D→A→C。"),
      ("一笔画：五点A、B、C、D、E。边是AB、BC、CD、DE、EA、AC。能否不抬笔且每条边只画一次？应从哪里开始？", "图连通，仅A和C连3条边，其他点连2条。恰有2个奇点，可从A到C：A→B→C→D→E→A→C。"),
      ("一笔画：六点A、B、C、D、E、F。边是AB、BC、CD、DE、EF、FA、AD。能否不抬笔且每条边只画一次？应从哪里开始？", "图连通，仅A和D连3条边，其他点连2条。恰有2个奇点，可从A到D：A→B→C→D→E→F→A→D。"),
    ]
    do {
      var questions: [MathQuestionRecord] = []
      for (index, fixture) in novel.enumerated() {
        let question = try await savePhoto(uncovered, index: index + 3, text: fixture.0, answer: fixture.1)
        questions.append(question)
        try await uncovered.originalImage(questionID: question.id).write(to: destination.appendingPathComponent("uncovered-\(index).png"))
      }
      await uncoveredRunner.enqueue(questions[0].id)
      let result = try await report(uncovered, question: questions[0])
      try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("uncovered.json"))
      await uncoveredRunner.setEnabled(false)
      let candidates = try await uncovered.listSkillCandidates()
      let after = try await uncovered.automaticMethods()
      observations.append(["case": "repeated-uncovered-single-trail", "expected_coverage": "uncovered",
        "coverage": result["coverage"] as Any, "status": result["status"] as Any,
        "selected_methods": result["covered_method_ids"] as Any, "reason": result["reason"] as Any,
        "model_calls": modelCalls(result) as Any, "candidate_statuses": candidates.map(\.status),
        "review_checks": ((result["review"] as? [String: Any])?["checks"] as? [[String: Any]] ?? []).map {
          ["dimension": $0["dimension"] as Any, "passed": $0["passed"] as Any]
        },
        "methods_unchanged": after == uncoveredBaseline,
        "acceptance_passed": result["coverage"] as? String == "uncovered"
          && Set(result["pattern_evidence_ids"] as? [String] ?? []) == Set(questions.map(\.id))
          && candidates.count == 1 && candidates.first?.status == "draft"
          && modelCalls(result) != nil && after == uncoveredBaseline])
      try writeReport()
      XCTAssertEqual(result["coverage"] as? String, "uncovered", "A related title is not a reusable solution for the new odd-degree structure")
      XCTAssertNotNil(modelCalls(result))
      XCTAssertEqual(Set(result["pattern_evidence_ids"] as? [String] ?? []), Set(questions.map(\.id)))
      XCTAssertEqual(candidates.count, 1)
      XCTAssertEqual(candidates.first?.status, "draft", "Repeated unverified examples must never publish automatically")
      XCTAssertEqual(after, uncoveredBaseline)
      await uncovered.close(); await client.shutdown()
    } catch {
      observations.append(["phase": "uncovered", "failure": "acceptance did not complete"])
      try? writeReport()
      await uncoveredRunner.setEnabled(false); await uncovered.close(); await client.shutdown()
      throw error
    }
  }

  func testPackagedBackgroundDiscoveryAndHumanResumeAfterEngineRestart() async throws {
    guard let output = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_ARTIFACTS"],
      let executable = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_ENGINE"] else {
      throw XCTSkip("Requires explicit packaged-engine learning live configuration")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? .init(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let model = MathTagModelConfiguration(configuration: preferences.configuration(fallingBackTo: fallback),
      api: preferences.selectedAPI, directConnection: preferences.selectedDirectConnection)
    func client() -> ScreenshotQuestionClient {
      let arguments = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_SOURCE"].map { [$0] } ?? []
      return .init(langChain: .init(executableURL: URL(fileURLWithPath: executable), arguments: arguments))
    }
    let engineURL = URL(fileURLWithPath: executable)
    let engineHash = SHA256.hash(data: try Data(contentsOf: engineURL)).map { String(format: "%02x", $0) }.joined()
    let engineSourceHashes: [String: String]
    if let source = ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_SOURCE"] {
      let directory = URL(fileURLWithPath: source).deletingLastPathComponent()
      let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "py" && !$0.lastPathComponent.hasPrefix("test_") }
      engineSourceHashes = try Dictionary(uniqueKeysWithValues: files.map { file in
        (file.lastPathComponent, SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined())
      })
    } else { engineSourceHashes = [:] }
    func runner(_ store: MathQuestionStore, _ client: ScreenshotQuestionClient, enabled: Bool) -> MathSkillLearningCoordinator {
      .init(store: store, enabled: enabled, configuration: { model }, analyze: { data, image, methods, model in
        try await client.learnSkills(learning: data, imageData: image, methods: methods,
          configuration: model.configuration, api: model.api, directConnection: model.directConnection)
      })
    }
    let store = MathQuestionStore(directory: destination.appendingPathComponent("isolated-library"))
    let firstClient = client()
    let coordinator = runner(store, firstClient, enabled: true)
    let catalogue = try MathSkillCatalogue.load()
    XCTAssertEqual(catalogue.skills.count, 49)
    _ = try await store.importBundledMathSkills(catalogue)
    let baselineMethods = try await store.automaticMethods()
    XCTAssertEqual(baselineMethods.count, 49)
    let cases: [(String, String)] = [
      ("小学拓展一笔画：四点A、B、C、D。边为AB、BC、CD、DA、AC。不抬笔，每条边只画一次，能否画完？从哪里开始？", "图连通，A、C各连3条边，B、D各连2条。可从A到C：A→B→C→D→A→C。"),
      ("小学拓展一笔画：五点A、B、C、D、E。边为AB、BC、CD、DE、EA、AC。不抬笔，每条边只画一次，能否画完？从哪里开始？", "图连通，仅A、C各连3条边。可从A到C：A→B→C→D→E→A→C。"),
      ("小学拓展一笔画：六点A、B、C、D、E、F。边为AB、BC、CD、DE、EF、FA、AD。不抬笔，每条边只画一次，能否画完？从哪里开始？", "图连通，仅A、D各连3条边。可从A到D：A→B→C→D→E→F→A→D。"),
      ("小学拓展一笔画：中心O与A、B、C相连，只有OA、OB、OC三条边。不抬笔，每条边只画一次，能否画完？", "不能。图连通，但O连3条边，A、B、C各连1条边，共4个奇点。"),
    ]
    // Independent finite edge checks, never a model-produced correctness oracle.
    XCTAssertTrue(Self.validTrail(["A","B","C","D","A","C"], edges: ["AB","BC","CD","DA","AC"]))
    XCTAssertTrue(Self.validTrail(["A","B","C","D","E","A","C"], edges: ["AB","BC","CD","DE","EA","AC"]))
    XCTAssertTrue(Self.validTrail(["A","B","C","D","E","F","A","D"], edges: ["AB","BC","CD","DE","EF","FA","AD"]))
    XCTAssertEqual(Self.oddVertices(edges: ["OA","OB","OC"]), Set(["O","A","B","C"]))
    var questions: [MathQuestionRecord] = []
    for (index, item) in cases.prefix(3).enumerated() {
      questions.append(try await savePhoto(store, index: index, text: item.0, answer: item.1))
    }
    await coordinator.enqueue(questions[0].id)
    var reports: [MathSkillLearningReport] = []
    let discoveryStarted = ProcessInfo.processInfo.systemUptime
    for _ in 0..<800 {
      reports = try await store.skillLearningReports(questionID: questions[0].id)
      if !reports.isEmpty { break }
      if try Self.readOnlyLearningJobStatus(directory: destination.appendingPathComponent("isolated-library"), questionID: questions[0].id) == "failed" {
        let failure: [String: Any] = ["stage": "background_discovery", "status": "failed",
          "elapsed_seconds": ProcessInfo.processInfo.systemUptime - discoveryStarted]
        try JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys, .prettyPrinted])
          .write(to: destination.appendingPathComponent("background-failure.json"), options: .atomic)
        break // A terminal failure is evidence, not permission to retry or count success.
      }
      try await Task.sleep(nanoseconds: 150_000_000)
    }
    await coordinator.setEnabled(false)
    let discovery = try XCTUnwrap(reports.last, "Background real-model discovery did not finish").report
    try Data(discovery.utf8).write(to: destination.appendingPathComponent("discovery.json"))
    var candidates = try await store.listSkillCandidates()
    let candidate = try XCTUnwrap(candidates.first(where: { $0.status == "draft" }), "Repeated independent originals must produce a reviewable draft, never an automatic publication")
    let beforeReview = try await store.automaticMethods()
    XCTAssertEqual(beforeReview, baselineMethods)
    // Development fixtures simulate human edits and check three independent positive cases
    // and adds an exclusion case. These fixture actions only affect this isolated store.
    let discoveryObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(discovery.utf8)) as? [String: Any])
    XCTAssertEqual(discoveryObject["coverage"] as? String, "uncovered", "The real model must judge coverage against all 49 supplied skills")
    XCTAssertEqual(Set(discoveryObject["pattern_evidence_ids"] as? [String] ?? []), Set(questions.map(\.id)))
    let proposal = MathSkillProposal(signature: candidate.proposal.signature, title: "一笔画的奇点与路径检查",
      category: "小学拓展（非四年级常规课程认证）", instructions: """
        仅用于用户明确允许的直观一笔画拓展。先逐条确认原图全部连接，不从OCR缺失猜测边；交叉处只有明确标点才算连接。
        确认所有需要画的线处于同一连通图。数每个点连接的线条数，奇数条的点叫奇点。
        连通且恰好两个奇点时，从一个奇点开始，到另一个结束；没有奇点时可从有线的任一点开始并回到起点。
        超过两个奇点或图不连通时不能一次不抬笔画完；连接不明确时不要套用。
        判定之后必须实际列出路径，按原图逐边检查：相邻点有线，每条线恰用一次，全部线均已覆盖，不重复不遗漏。
        正例：AB、BC、CD、DA、AC可走A→B→C→D→A→C；五点与六点正例见核验原题。
        反例：OA、OB、OC共四个奇点，不能一笔画完。
        这是小学拓展活动，不认证为四年级常规知识。无需方程；不要求新增绘图，diagram_templates为空，只参照原图并列出路径。
        """, trigger: "明确给出完整点线连接，要求不抬笔且每条边恰画一次，用户明确允许拓展",
      constraints: "小学直观拓展；须明确允许拓展；不代表常规课程认证；人工动作仅隔离开发fixture",
      exclusions: "图不连通、奇点超过两个、原图连接不明确或用户未允许拓展",
      prerequisites: "按图识别连接、计数、奇偶数", supportedDiagrams: [],
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .explicitPermission))
    try await store.editSkillCandidate(id: candidate.id, proposal: proposal)
    questions.append(try await savePhoto(store, index: 3, text: cases[3].0, answer: cases[3].1))
    for (index, question) in questions.enumerated() {
      let review = try await store.reviewSolution(questionID: question.id, solutionID: "live-solution-\(index)",
        status: "confirmed", scope: "答案及解题过程", note: "Isolated human-action fixture: independent point/edge/path and applicability checks", correction: "")
      try await store.assessSkillCandidate(id: candidate.id, questionID: question.id, solutionID: "live-solution-\(index)",
        reviewID: review.id, boundary: index == 3 ? "excluded" : "applies", note: "Fixture independently checked edge paths and odd-point exclusion")
    }
    try await coordinator.reviewCandidate(id: candidate.id, approve: false, note: "")
    let attempt = try await store.candidateResearchAttempt(id: candidate.id)
    let pausedReport = try await store.candidateResearchReport(attempt: attempt)
    let paused = try XCTUnwrap(pausedReport)
    try Data(paused.utf8).write(to: destination.appendingPathComponent("paused.json"))
    let pausedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(paused.utf8)) as? [String: Any])
    XCTAssertEqual(pausedObject["status"] as? String, "awaiting_human")
    XCTAssertNil(pausedObject["human_decision"])
    let beforeApproval = try await store.automaticMethods()
    XCTAssertEqual(beforeApproval, baselineMethods)
    let backup = destination.appendingPathComponent("paused-backup")
    try await store.backup(to: backup)
    await store.close()
    await firstClient.shutdown() // A new packaged engine process must reconstruct the interrupt.
    let restored = MathQuestionStore(directory: destination.appendingPathComponent("restored-library"))
    _ = try await restored.restoreBackup(from: backup)
    let secondClient = client(), resumedCoordinator = runner(restored, secondClient, enabled: false)
    try await resumedCoordinator.reviewCandidate(id: candidate.id, approve: true,
      note: "ISOLATED TEST HUMAN ACTION ONLY: independently checked all original edges, three complete paths and the four-odd-point exclusion; not a real user approval")
    let methods = try await restored.automaticMethods()
    XCTAssertEqual(methods.count, 50)
    let publishedMethod = try XCTUnwrap(methods.first { $0.title == proposal.title })
    XCTAssertTrue(MathMethodMatcher.eligibleMethods(methods, question: "四年级，不用方程，允许拓展方法").contains(publishedMethod))
    XCTAssertFalse(MathMethodMatcher.eligibleMethods(methods, question: "四年级，不用方程，不允许拓展").contains(publishedMethod))
    candidates = try await restored.listSkillCandidates()
    XCTAssertEqual(candidates.first(where: { $0.id == candidate.id })?.status, "published")
    let export = try await restored.candidateSkillExport(id: candidate.id)
    let approved = export.researchJSON
    try Data(approved.utf8).write(to: destination.appendingPathComponent("resumed.json"))
    let resumedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(approved.utf8)) as? [String: Any])
    let oldState = try XCTUnwrap((pausedObject["workflow_state"] as? [String: Any])?["state"] as? [String: Any])
    let newState = try XCTUnwrap((resumedObject["workflow_state"] as? [String: Any])?["state"] as? [String: Any])
    XCTAssertEqual(oldState["model_calls"] as? Int, newState["model_calls"] as? Int, "Human resume must not repeat any model call")
    let pausedCalls = try XCTUnwrap(oldState["model_calls"] as? Int)
    let resumedCalls = try XCTUnwrap(newState["model_calls"] as? Int)
    try export.write(to: destination.appendingPathComponent("exported-skill"))
    let publishedBackup = destination.appendingPathComponent("published-backup")
    try await restored.backup(to: publishedBackup)
    await restored.close(); await secondClient.shutdown()
    let verified = MathQuestionStore(directory: destination.appendingPathComponent("published-restored"))
    _ = try await verified.restoreBackup(from: publishedBackup)
    let verifiedMethods = try await verified.automaticMethods()
    XCTAssertEqual(verifiedMethods.count, 50)
    let learned = try XCTUnwrap(verifiedMethods.first { $0.versionID == publishedMethod.versionID })
    XCTAssertEqual(learned, publishedMethod, "Backup restoration must preserve the published exact version")
    let projectDirectory = destination.appendingPathComponent("isolated-project")
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    let projectSuite = "MathLearningProject.\(UUID().uuidString)"
    let projectDefaults = try XCTUnwrap(UserDefaults(suiteName: projectSuite))
    defer { projectDefaults.removePersistentDomain(forName: projectSuite) }
    let projectSync = MathSkillProjectSyncCoordinator(store: verified, defaults: projectDefaults)
    try projectSync.selectProject(projectDirectory)
    await projectSync.synchronize()
    let projectSnapshots = try await verified.projectSkillSnapshots()
    let learnedSnapshot = try XCTUnwrap(projectSnapshots.first { $0.method.versionID == learned.versionID })
    let projectArtifact = try MathSkillProjectArtifact(snapshot: learnedSnapshot)
    let projectArtifactDirectory = projectDirectory.appendingPathComponent(projectArtifact.relativePath)
    try projectArtifact.verify(at: projectArtifactDirectory)
    let projectSource = try Data(contentsOf: projectArtifactDirectory.appendingPathComponent(projectArtifact.name + "/references/source.md"))
    // source.md preserves the human-edited draft; method.json preserves the
    // published wrapper with trigger, boundaries and teaching permissions.
    let originalDraft = try XCTUnwrap(learnedSnapshot.profile?.sourceInstructions)
    XCTAssertEqual(originalDraft, proposal.instructions)
    let projectSourceVerified = projectSource == Data(originalDraft.utf8)
    XCTAssertTrue(projectSourceVerified)
    let projectMethodBytes = try Data(contentsOf: projectArtifactDirectory.appendingPathComponent(projectArtifact.name + "/references/method.json"))
    let projectMethod = try JSONDecoder().decode(MathTeachingMethod.self, from: projectMethodBytes)
    let projectPublishedVersionVerified = projectMethod == learned
    XCTAssertTrue(projectPublishedVersionVerified)
    let projectSkill = try MathSkillCatalogue(directory: projectArtifactDirectory)
    XCTAssertEqual(projectSkill.skills.count, 1)
    let projectSkillBody = try XCTUnwrap(projectSkill.skills.first).instructions
    let projectSkillPublishedBodyVerified = projectSkillBody.hasPrefix("# \(learned.title)\n\n" + learned.instructions + "\n\n")
    XCTAssertTrue(projectSkillPublishedBodyVerified, "The valid SKILL body must include the entire published method before snapshot annotations")
    XCTAssertTrue(learnedSnapshot.automaticEligible)
    // A fresh original is neither discovery evidence nor a human-reviewed training
    // example. Exercise the normal automatic matcher and panel, not injected gold.
    let freshText = "小学拓展一笔画：四点A、B、C、D，边为AB、BC、CD、DA、BD。不抬笔，每条边只画一次，能否画完？请给出完整路径。"
    let freshEdges = ["AB","BC","CD","DA","BD"]
    XCTAssertEqual(Self.oddVertices(edges: freshEdges), Set(["B","D"]))
    XCTAssertTrue(Self.validTrail(["B","A","D","C","B","D"], edges: freshEdges))
    let freshPhoto = try photo(text: freshText)
    try freshPhoto.write(to: destination.appendingPathComponent("fresh-reuse-original.png"))
    let reuseClient = client(), matcher = MathMethodMatcher(client: reuseClient)
    let suite = "MathSkillLearningReuse.\(UUID().uuidString)"
    let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { isolatedDefaults.removePersistentDomain(forName: suite) }
    var selectionRequests = 0, solverRequests = 0
    var suppliedVersion: String?, selectedVersion: String?, solverReceivedExactBody = false
    var selectionDiagnostic: [String: Any] = ["status": "not_requested"]
    func recordSelectionDiagnostic() {
      // Only bounded native checks and allowlisted failure labels; never the
      // configured request, provider error body, credentials or tool arguments.
      try? JSONSerialization.data(withJSONObject: selectionDiagnostic, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("fresh-selection-diagnostic.json"), options: .atomic)
    }
    let panel = ScreenshotQuestionPanel(
      context: .init(text: freshText, selectedWord: nil, imageData: freshPhoto),
      answer: { question, context, history, partial in
        solverRequests += 1
        solverReceivedExactBody = question.contains(learned.instructions)
        XCTAssertTrue(solverReceivedExactBody, "Normal solving must receive the selected immutable learned body")
        XCTAssertEqual(context.imageData, freshPhoto)
        try question.write(to: destination.appendingPathComponent("fresh-solver-prompt.txt"), atomically: true, encoding: .utf8)
        let answer = try await reuseClient.answer(question: question, context: context, history: history,
          configuration: model.configuration, api: model.api, thinking: .off,
          directConnection: model.directConnection, onPartial: partial)
        try answer.write(to: destination.appendingPathComponent("fresh-model-answer.txt"), atomically: true, encoding: .utf8)
        return answer
      }, interfaceDefaults: isolatedDefaults, originalImageData: freshPhoto,
      saveQuestion: { try await verified.save($0) }, solutionModel: { model.configuration.model }, mathStore: verified,
      selectMethodAutomatically: { question, context, supplied in
        selectionRequests += 1
        XCTAssertEqual(supplied, verifiedMethods, "The actual full directory must be supplied, not only the expected learned skill")
        suppliedVersion = supplied.first { $0.id == learned.id }?.versionID
        XCTAssertEqual(context.imageData, freshPhoto)
        let eligible = MathMethodMatcher.eligibleMethods(supplied, question: question)
        selectionDiagnostic = ["status": "requesting", "supplied_count": supplied.count,
          "eligible_count": eligible.count, "supplied_exact_version": supplied.contains(learned),
          "eligible_exact_version": eligible.contains(learned), "original_image_passed": context.imageData == freshPhoto]
        recordSelectionDiagnostic()
        let started = ProcessInfo.processInfo.systemUptime
        let selected: MathMethodMatch
        do {
          selected = try await matcher.select(question: question, context: context, methods: supplied,
            configuration: model.configuration, api: model.api, directConnection: model.directConnection)
        } catch {
          selectionDiagnostic.merge(self.safeSelectionFailure(error)) { _, new in new }
          selectionDiagnostic["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
          recordSelectionDiagnostic()
          throw error // Preserve the normal panel failure path and every acceptance assertion.
        }
        selectionDiagnostic["status"] = selected.method == nil ? "no_primary_selected" : "selected"
        selectionDiagnostic["code"] = selected.method == nil ? "no_primary_selected" : "selection_returned"
        selectionDiagnostic["reason"] = selected.method == nil
          ? "原生匹配器返回了有效选择，但未选择主方法。" : "原生匹配器返回了主方法选择。"
        selectionDiagnostic["selected_exact_version"] = selected.method == learned
        selectionDiagnostic["visual_method_count"] = selected.visualMethods.count
        selectionDiagnostic["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        recordSelectionDiagnostic()
        XCTAssertEqual(selected.method, learned, "The fresh related original must actually select the learned method")
        XCTAssertTrue(selected.visualMethods.isEmpty)
        selectedVersion = selected.method?.versionID
        try ("\(selected.method?.id ?? "none")\n\(selected.method?.versionID ?? "none")\n\(selected.reason)")
          .write(to: destination.appendingPathComponent("fresh-selection.txt"), atomically: true, encoding: .utf8)
        return selected
      })
    defer { panel.close() }
    panel.present()
    let controls = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
      .stringValue = "四年级，允许拓展方法，不使用方程。请参照原图，使用适用方法并逐边验算；末尾单独一行写‘最终路径：A→B→…’，用实际点名替代示例，不要在这一行写其他文字。"
    try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settlePanel { !panel.isAnswering && panel.history.count == 1 }
    selectionDiagnostic["panel_answer_completed"] = !panel.isAnswering && panel.history.count == 1
    selectionDiagnostic["solver_received_exact_body"] = solverReceivedExactBody
    recordSelectionDiagnostic()
    XCTAssertEqual(selectionRequests, 1)
    XCTAssertEqual(solverRequests, 1, "This learned method does not request diagrams or a repair")
    XCTAssertEqual(suppliedVersion, learned.versionID)
    XCTAssertEqual(selectedVersion, learned.versionID)
    let freshAnswer = try XCTUnwrap(panel.history.first?.answer)
    let finalPath = try NSRegularExpression(pattern: #"(?m)^\s*(?:\*\*)?最终路径\s*[:：]\s*([A-D](?:\s*→\s*[A-D])+)(?:\*\*)?\s*[。．]?\s*$"#)
    let matches = finalPath.matches(in: freshAnswer, range: NSRange(freshAnswer.startIndex..., in: freshAnswer))
    XCTAssertEqual(matches.count, 1, "The real answer must state one explicit complete path; the expected path is never sent")
    let match = try XCTUnwrap(matches.first)
    let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: freshAnswer))
    let returnedPath = freshAnswer[valueRange].components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }
    let pathPassed = Self.validTrail(returnedPath, edges: freshEdges)
    XCTAssertTrue(pathPassed, "Independently verify adjacency and exact once-only coverage of every original edge")
    try XCTUnwrap(views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" })
      .performClick(nil)
    try await settlePanel { panel.savedQuestionID != nil }
    let freshID = try XCTUnwrap(panel.savedQuestionID)
    XCTAssertFalse(questions.contains { $0.id == freshID }, "Fresh reuse must not recycle discovery or review evidence")
    panel.close()
    await reuseClient.shutdown()
    await verified.close()
    let reopened = MathQuestionStore(directory: destination.appendingPathComponent("published-restored"))
    let original = try await reopened.originalImage(questionID: freshID)
    XCTAssertEqual(original, freshPhoto)
    let savedAnswers = try await reopened.solutions(questionID: freshID)
    let saved = try XCTUnwrap(savedAnswers.first)
    XCTAssertEqual(savedAnswers.count, 1)
    XCTAssertEqual(saved.answer, freshAnswer)
    XCTAssertEqual(saved.method, learned)
    XCTAssertEqual(saved.verificationStatus, "unverified", "Method approval never verifies a future model answer")
    XCTAssertNil(saved.selectionFailure)
    XCTAssertNil(saved.diagramFailure)
    let records = try await reopened.list()
    let record = try XCTUnwrap(records.first { $0.id == freshID })
    let pdf = destination.appendingPathComponent("fresh-reuse.pdf")
    let pages = try await MathQuestionPDFExporter.export(records: [record], store: reopened, to: pdf,
      options: .init(includeSolutions: true))
    let pdfText = try XCTUnwrap(PDFDocument(url: pdf)?.string)
    XCTAssertGreaterThan(pages, 1)
    XCTAssertTrue(pdfText.contains("参考方法建议（未确认采用）：\(learned.title)"))
    XCTAssertTrue(pdfText.contains("尚未核验"))
    XCTAssertTrue(pdfText.contains("最终路径"))
    XCTAssertFalse(pdfText.contains("用户已确认"))
    try await reopened.revokeSkillMethod(versionID: learned.versionID,
      note: "ISOLATED TEST HUMAN ACTION ONLY: withdraw future automatic reuse; preserve previous answer snapshot")
    await reopened.close()
    let revokedStore = MathQuestionStore(directory: destination.appendingPathComponent("published-restored"))
    func recordRevocationStage(_ stage: String, error: Error? = nil) {
      var diagnostic = ["stage": stage]
      // Type only: never persist an SDK message, request or configuration.
      if let error { diagnostic["error_type"] = String(reflecting: type(of: error)) }
      try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys, .prettyPrinted])
        .write(to: destination.appendingPathComponent("revocation-stage.json"), options: .atomic)
    }
    recordRevocationStage("loading_future_methods")
    let futureMethods: [MathTeachingMethod]
    do { futureMethods = try await revokedStore.automaticMethods() }
    catch { recordRevocationStage("loading_future_methods_failed", error: error); throw error }
    XCTAssertFalse(futureMethods.contains { $0.versionID == learned.versionID })
    XCTAssertEqual(futureMethods.count, 49)
    XCTAssertEqual(Set(futureMethods.map(\.versionID)), Set(baselineMethods.map(\.versionID)))
    let revokedClient = client()
    let revokedMatcher = MathMethodMatcher(client: revokedClient)
    recordRevocationStage("matching_after_revocation")
    let futureMatch: MathMethodMatch
    do {
      futureMatch = try await revokedMatcher.select(question: "四年级，允许拓展方法，不用方程，请用适用的方法解答。",
        context: .init(text: freshText, selectedWord: nil, imageData: freshPhoto), methods: futureMethods,
        configuration: model.configuration, api: model.api, directConnection: model.directConnection)
    } catch { recordRevocationStage("matching_after_revocation_failed", error: error); throw error }
    recordRevocationStage("matched_after_revocation")
    await revokedClient.shutdown()
    XCTAssertNotEqual(futureMatch.method?.versionID, learned.versionID, "The withdrawn exact version must never be selected")
    XCTAssertFalse(futureMatch.visualMethods.contains { $0.versionID == learned.versionID })
    let revokedSync = MathSkillProjectSyncCoordinator(store: revokedStore, defaults: projectDefaults)
    await revokedSync.synchronize()
    try projectArtifact.verify(at: projectArtifactDirectory)
    let revokedSnapshots = try await revokedStore.projectSkillSnapshots()
    let revokedSnapshot = try XCTUnwrap(revokedSnapshots.first { $0.method.versionID == learned.versionID })
    XCTAssertFalse(revokedSnapshot.automaticEligible)
    let revokedArtifact = try MathSkillProjectArtifact(snapshot: revokedSnapshot)
    try revokedArtifact.verify(at: projectDirectory.appendingPathComponent(revokedArtifact.relativePath))
    let oldAnswers = try await revokedStore.solutions(questionID: freshID)
    XCTAssertEqual(oldAnswers, savedAnswers, "Revocation must not rewrite the previous method version or answer verification")
    try JSONEncoder().encode(oldAnswers).write(to: destination.appendingPathComponent("fresh-history-after-revocation.json"))
    let revokedPDF = destination.appendingPathComponent("fresh-reuse-after-revocation.pdf")
    _ = try await MathQuestionPDFExporter.export(records: [record], store: revokedStore, to: revokedPDF,
      options: .init(includeSolutions: true))
    let revokedPDFText = PDFDocument(url: revokedPDF)?.string
    XCTAssertEqual(revokedPDFText, pdfText, "Withdrawing eligibility must leave the historical answer PDF unchanged")
    let reusePassed = learned == publishedMethod && selectionRequests == 1 && solverRequests == 1
      && projectSourceVerified && projectPublishedVersionVerified && projectSkillPublishedBodyVerified
      && suppliedVersion == learned.versionID && selectedVersion == learned.versionID && solverReceivedExactBody
      && matches.count == 1 && pathPassed
      && savedAnswers.count == 1 && saved.answer == freshAnswer && saved.method == learned
      && saved.verificationStatus == "unverified" && saved.selectionFailure == nil && saved.diagramFailure == nil
      && original == freshPhoto && pages > 1 && pdfText.contains("参考方法建议（未确认采用）：\(learned.title)")
      && pdfText.contains("尚未核验") && pdfText.contains("最终路径") && !pdfText.contains("用户已确认")
      && !questions.contains { $0.id == freshID }
      && !futureMethods.contains { $0.versionID == learned.versionID }
      && futureMatch.method?.versionID != learned.versionID && !futureMatch.visualMethods.contains { $0.versionID == learned.versionID }
      && oldAnswers == savedAnswers && revokedPDFText == pdfText
    XCTAssertTrue(reusePassed)
    let lifecyclePassed = beforeReview == baselineMethods && beforeApproval == baselineMethods
      && pausedObject["status"] as? String == "awaiting_human" && pausedObject["human_decision"] == nil
      && methods.count == 50 && publishedMethod.title == proposal.title
      && MathMethodMatcher.eligibleMethods(methods, question: "四年级，不用方程，允许拓展方法").contains(publishedMethod)
      && candidates.first(where: { $0.id == candidate.id })?.status == "published"
      && pausedCalls > 0 && resumedCalls == pausedCalls && verifiedMethods.count == 50
    await revokedStore.close()
    let summary: [String: Any] = ["scope": "isolated full-catalogue discovery and human-action fixtures; elementary enrichment only, not ordinary grade-four certification; real provider",
      "engine_kind": ProcessInfo.processInfo.environment["MATH_LEARNING_LIVE_SOURCE"] == nil ? "packaged" : "source",
      "catalogue_scope": "all 49 bundled skills supplied before discovery; one novel elementary enrichment pattern, not certification of all methods",
      "discovery_status": try XCTUnwrap(JSONSerialization.jsonObject(with: Data(discovery.utf8)) as? [String: Any])["status"] as Any,
      "review_status": "awaiting_human", "resume_status": "approved", "resume_additional_model_calls": resumedCalls - pausedCalls,
      "positive_cases": 3, "exclusion_cases": 1, "ordinary_grade_four_certified": false,
      "permission_policy": "explicit extension permission required", "initial_catalogue_count": baselineMethods.count,
      "discovery_coverage": discoveryObject["coverage"] as Any,
      "project_sync": ["isolated_project": true, "artifact_sha256": projectArtifact.sha256,
        "source_sha256": SHA256.hash(data: projectSource).map { String(format: "%02x", $0) }.joined(),
        "original_draft_sha256": SHA256.hash(data: Data(originalDraft.utf8)).map { String(format: "%02x", $0) }.joined(),
        "original_draft_source_verified": projectSourceVerified,
        "published_instructions_sha256": SHA256.hash(data: Data(learned.instructions.utf8)).map { String(format: "%02x", $0) }.joined(),
        "published_method_json_exact_version_verified": projectPublishedVersionVerified,
        "skill_contains_full_published_body_verified": projectSkillPublishedBodyVerified,
        "revoked_current_snapshot_ineligible": !revokedSnapshot.automaticEligible,
        "historical_artifact_preserved": true], "real_user_approval": false, "production_writes": false,
      "engine_executable_sha256": engineHash, "engine_source_hashes": engineSourceHashes,
      "fresh_reuse": ["original_is_new_evidence": !questions.contains { $0.id == freshID }, "independent_edges": freshEdges, "independent_odd_vertices": ["B","D"], "returned_path": returnedPath, "independent_path_passed": pathPassed,
        "method_id": learned.id, "version_id": learned.versionID,
        "instructions_sha256": SHA256.hash(data: Data(learned.instructions.utf8)).map { String(format: "%02x", $0) }.joined(),
        "selection_requests": selectionRequests, "solver_requests": solverRequests,
        "selection_diagnostic": selectionDiagnostic,
        "supplied_version_id": suppliedVersion as Any, "selected_version_id": selectedVersion as Any,
        "solver_received_exact_body": solverReceivedExactBody,
        "snapshot_survived_reopen": saved.method == learned, "answer_status": saved.verificationStatus,
        "original_preserved": original == freshPhoto, "pdf_pages": pages,
        "revoked_excluded_from_future_eligibility": !futureMethods.contains { $0.versionID == learned.versionID },
        "revoked_future_match_excludes_exact_version": futureMatch.method?.versionID != learned.versionID && !futureMatch.visualMethods.contains { $0.versionID == learned.versionID },
        "history_unchanged_after_revocation": oldAnswers == savedAnswers,
        "raw_engine_read_trace_evaluated": false, "acceptance_passed": reusePassed],
      "acceptance_passed": lifecyclePassed && reusePassed]
    try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys,.prettyPrinted]).write(to: destination.appendingPathComponent("report.json"))
  }

  /// Read only the fixed status column in this test's isolated database. Never
  /// read job.error, provider output, snapshots, or any production database.
  private static func readOnlyLearningJobStatus(directory: URL, questionID: String) throws -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("questions.sqlite").path, &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      if let database { sqlite3_close(database) }
      throw NSError(domain: "MathLearningFixtureStatus", code: 1)
    }
    let handle = try XCTUnwrap(database)
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT status FROM skill_learning_jobs WHERE question_id=?", -1, &statement, nil) == SQLITE_OK else {
      throw NSError(domain: "MathLearningFixtureStatus", code: 2)
    }
    let query = try XCTUnwrap(statement)
    defer { sqlite3_finalize(query) }
    let binding = questionID.withCString { sqlite3_bind_text(query, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    guard binding == SQLITE_OK else { throw NSError(domain: "MathLearningFixtureStatus", code: 3) }
    let result = sqlite3_step(query)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else {
      throw NSError(domain: "MathLearningFixtureStatus", code: 4)
    }
    let status = String(cString: value)
    guard ["pending", "running", "failed", "ready"].contains(status) else {
      throw NSError(domain: "MathLearningFixtureStatus", code: 5)
    }
    return status
  }

  private static func edgeKey(_ a: String, _ b: String) -> String { [a, b].sorted().joined() }

  private static func oddVertices(edges: [String]) -> Set<String> {
    var degrees: [String: Int] = [:]
    for edge in edges {
      for vertex in edge.map(String.init) { degrees[vertex, default: 0] += 1 }
    }
    return Set(degrees.filter { $0.value % 2 == 1 }.map(\.key))
  }

  private static func validTrail(_ path: [String], edges: [String]) -> Bool {
    guard path.count == edges.count + 1, edges.allSatisfy({ $0.count == 2 }) else { return false }
    var remaining: [String: Int] = [:]
    for edge in edges {
      let vertices = edge.map(String.init)
      remaining[edgeKey(vertices[0], vertices[1]), default: 0] += 1
    }
    for (a, b) in zip(path, path.dropFirst()) {
      let key = edgeKey(a, b)
      guard let count = remaining[key], count > 0 else { return false }
      remaining[key] = count - 1
    }
    return remaining.values.allSatisfy { $0 == 0 }
  }

  private func savePhoto(_ store: MathQuestionStore, index: Int, text: String, answer: String) async throws -> MathQuestionRecord {
    let bytes = try photo(text: text)
    return try await store.save(.init(captureID: "learning-live-\(index)", imageData: bytes, ocrText: text,
      solutions: [.init(id: "live-solution-\(index)",
        question: text.contains("一笔画") ? "四年级，允许拓展方法，不使用方程。" : "用小学整数算术，不使用方程。",
        answer: answer, model: text.contains("一笔画") ? "independent-edge-fixture" : "independent-arithmetic-fixture")]))
  }

  private func photo(text: String) throws -> Data {
    let graph = text.contains("一笔画")
    let height: CGFloat = graph ? 460 : 230
    let image = NSImage(size: NSSize(width: 1200, height: height))
    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: height).fill()
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 29), .foregroundColor: NSColor.black])
      .draw(in: NSRect(x: 32, y: graph ? 300 : 50, width: 1136, height: 140))
    if graph {
      let expression = try NSRegularExpression(pattern: #"(?<![A-Z])[A-FO]{2}(?![A-Z])"#)
      let edges = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
        guard let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
      }
      let vertices = Set(edges.flatMap { $0.map(String.init) }).sorted()
      var positions: [String: NSPoint] = [:]
      if vertices.contains("O") {
        positions = ["O": NSPoint(x: 600, y: 145), "A": NSPoint(x: 470, y: 60),
          "B": NSPoint(x: 600, y: 255), "C": NSPoint(x: 730, y: 60)]
      } else {
        for (index, vertex) in vertices.enumerated() {
          let angle = CGFloat(index) * 2 * .pi / CGFloat(vertices.count) + .pi / 4
          positions[vertex] = NSPoint(x: 600 + 130 * cos(angle), y: 150 + 110 * sin(angle))
        }
      }
      NSColor.black.setStroke()
      for edge in edges {
        let endpoints = edge.map(String.init)
        guard let a = positions[endpoints[0]], let b = positions[endpoints[1]] else { continue }
        let line = NSBezierPath(); line.lineWidth = 3; line.move(to: a); line.line(to: b); line.stroke()
      }
      for vertex in vertices {
        guard let point = positions[vertex] else { continue }
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
        NSAttributedString(string: vertex, attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
          .draw(at: NSPoint(x: point.x + 10, y: point.y + 6))
      }
    }
    image.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    return bytes
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func safeSelectionFailure(_ error: Error) -> [String: Any] {
    let code: String, category: String, reason: String
    if let failure = error as? MathMethodMatchError {
      reason = failure.localizedDescription // This enum exposes fixed native strings only.
      switch failure {
      case .invalidOutput: code = "skillsInvalid_or_skillsOutput"; category = "selection_protocol"
      case .catalogueTooLarge: code = "skillsTooLarge"; category = "catalogue_limit"
      case .selectionBudgetExceeded: code = "skillsBudget"; category = "selection_budget"
      case .prerequisiteNotSatisfied: code = "skillsPrerequisite"; category = "prerequisite_block"
      }
    } else if let failure = error as? LangChainTransportError {
      reason = failure.localizedDescription
      category = "native_transport"
      switch failure {
      case .unavailable: code = "engine_unavailable"
      case .incompatibleRuntime: code = "engine_incompatible"
      case .startupTimeout: code = "engine_startup_timeout"
      case .requestTimeout: code = "engine_request_timeout"
      case .disconnected: code = "engine_disconnected"
      case .connection: code = "connection"
      }
    } else if let failure = error as? ScreenshotQuestionError {
      reason = failure.localizedDescription
      category = "question_protocol_or_provider"
      switch failure {
      case .emptyQuestion: code = "empty_question"
      case .missingContext: code = "missing_context"
      case .invalidConfiguration: code = "invalid_configuration"
      case .invalidImage: code = "invalid_image"
      case .server(let status): code = "server_\(status)"
      case .invalidResponse: code = "invalid_response"
      case .emptyResponse: code = "empty_response"
      case .truncatedResponse: code = "truncated_response"
      case .unsupportedThinking: code = "unsupported_thinking"
      }
    } else if error is CancellationError {
      code = "cancelled"; category = "cancelled"; reason = "自动匹配已取消。"
    } else {
      code = "unclassified_native_error"; category = "unclassified"; reason = "自动匹配发生未分类错误；未记录任意异常正文。"
    }
    return ["status": "failed", "code": code, "category": category, "reason": reason,
      "raw_error_recorded": false, "engine_execution_metadata_available": false]
  }

  private func settlePanel(_ finished: () -> Bool) async throws {
    for _ in 0..<1800 {
      if finished() { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw NSError(domain: "MathSkillLearningReuseAcceptance", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Normal question panel exceeded the explicit 180-second acceptance deadline"])
  }
}
