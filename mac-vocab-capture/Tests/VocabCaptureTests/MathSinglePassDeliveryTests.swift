import AppKit
import XCTest
@testable import VocabCapture

/// Recorded response exercises one model boundary and real native delivery;
/// it is not a fresh provider latency measurement.
@MainActor
final class MathSinglePassDeliveryTests: XCTestCase {
  func testGridRoutePresentationRejectsInvalidCoordinatesAndJumps() {
    func check(_ json: String) -> Bool {
      ScreenshotQuestionPanel.hasDeferredGridRoutePresentation(in: "```math-grid-route\n\(json)\n```")
    }
    XCTAssertTrue(check(#"{"width":3,"height":3,"points":[[0,0],[0,1],[1,1]],"stars":[[1,1]]}"#))
    XCTAssertFalse(check(#"{"width":3,"height":3,"points":[[0,0],[1,1]],"stars":[]}"#))
    XCTAssertFalse(check(#"{"width":3,"height":3,"points":[[0,0],[0,1]],"stars":[[4,1]]}"#))
    XCTAssertFalse(check(#"{"width":true,"height":3,"points":[[0,0],[0,1]],"stars":[]}"#))
    XCTAssertFalse(check(#"{"width":3,"height":3,"points":[[0,0],[0,1]],"stars":[],"extra":"x"}"#))
  }
  func testOriginalTriangleCropInjectsSkillIntoSingleSubmission() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_TRIANGLE_ORIGINAL_IMAGE"] else { throw XCTSkip("Set original crop path") }
    let photo = try Data(contentsOf: URL(fileURLWithPath: path))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let answer = "分割示意。\n```math-triangle-dissection\n{\"pieces\":5}\n```\n```math-triangle-dissection\n{\"pieces\":13}\n```"
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { question, _, _, _ in
        calls += 1
        XCTAssertTrue(question.contains("全等直角三角形分割构造"))
        XCTAssertTrue(question.contains("inline_triangle"))
        let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
          "visual_method_ids":[],"answer":answer,"diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(panel.history[0].answer.contains("math-triangle-dissection"))
    panel.close(); await store.close()
  }
  func testTriangleAnswerPersistsFromMockSubmission() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let answer = "五块与十三块分割示意。\n```math-triangle-dissection\n{\"pieces\":5}\n```\n```math-triangle-dissection\n{\"pieces\":13}\n```"
    let panel = ScreenshotQuestionPanel(context: .init(text: "三角形分成5块和13块", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in
        let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
          "visual_method_ids":[],"answer":answer,"diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题并画图"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertTrue(panel.history[0].answer.contains("math-triangle-dissection"))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertTrue(saved.answer.contains("math-triangle-dissection"))
    XCTAssertNil(saved.diagramFailure)
    XCTAssertEqual(saved.verificationStatus, "unverified")
    panel.close(); await store.close()
  }
  func testTrianglePresentationIsAcceptedOnlyForSupportedPresets() {
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredTrianglePresentation(in: "```math-triangle-dissection\n{\"pieces\":5}\n```"))
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredTrianglePresentation(in: "```math-triangle-dissection\n{\"pieces\":13}\n```"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredTrianglePresentation(in: "```math-triangle-dissection\n{\"pieces\":6}\n```"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredTrianglePresentation(in: "```math-triangle-dissection\n{\"pieces\":true}\n```"))
  }
  func testSevenBySevenStripAnswerPersistsFromFastSubmission() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let rows = ["AAAABCD", "GGGGBCD", "HHHHBCD", "KLIJBCD", "KLIFFFF", "KLIEEEE", "KLIMMMM"].map { $0.map(String.init) }
    let plan: [String: Any] = ["title":"12张纸条，J为未用格", "unitWidth":1, "unitHeight":1, "source":rows, "target":rows]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)
    let answer = "最多12张；J是唯一未用格，不是纸条。\n```math-grid\n" + json + "\n```"
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "7×7正方形剪4×1纸条，最多几张并画图？", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in
        calls += 1
        let response: [String: Any] = ["schemaVersion":1, "mode":"general", "method_id":NSNull(),
          "visual_method_ids":[], "answer":answer, "diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题并画图"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(panel.history[0].answer.contains("J是唯一未用格"))
    XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertTrue(saved.answer.contains("```math-grid"))
    XCTAssertNil(saved.diagramFailure)
    panel.close(); await store.close()
  }
  func testCubeAnswerSurvivesSingleSubmissionAndSaving() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let answer = "两面展开，经过共同棱中点。\n```math-cube-path\n{\"title\":\"路线示意\",\"edge\":0}\n```"
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "正方体对顶点表面最短路径", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in
        calls += 1
        let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
          "visual_method_ids":[],"answer":answer,"diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题并画图"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(panel.history[0].answer.contains("```math-cube-path"))
    XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertTrue(saved.answer.contains("```math-cube-path"))
    XCTAssertNil(saved.diagramFailure)
    XCTAssertEqual(saved.verificationStatus, "unverified")
    panel.close(); await store.close()
  }
  func testCubePathPresentationRequiresBoundedValidObject() {
    func fence(_ text: String) -> String { "```math-cube-path\n" + text + "\n```" }
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredCubePathPresentation(in: fence(#"{"title":"展开示意","edge":0}"#)))
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredCubePathPresentation(in: fence(#"{"title":"展开示意","edge":5}"#)))
    for invalid in [#"{"title":"图","edge":6}"#, #"{"title":"图","edge":true}"#,
      #"{"title":"图","edge":1.5}"#, #"{"title":"<svg>","edge":0}"#,
      #"{"title":"图","edge":0,"x":1}"#] {
      XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredCubePathPresentation(in: fence(invalid)))
    }
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func settle(_ predicate: () -> Bool) async throws {
    // This bounds asynchronous UI completion, not provider performance.
    // Keep timing assertions on the injected clock separate from suite load.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    repeat {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    } while clock.now < deadline
    _ = try XCTUnwrap(predicate() ? true : nil, "Single-pass native delivery did not settle")
  }
  func testDeferredGridDeclarationIsBoundedAndNotAMathApproval() throws {
    let good = #"{"title":"分块","unitWidth":5,"unitHeight":4,"source":[["A","B"]],"target":[["A"],["B"]]}"#
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "```math-grid\n" + good + "\n```"))
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "~~~math-grid\n" + good + "\n~~~~"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "```math-grid\n" + good))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "```math-grid\n{}\n```"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "````text\n```math-grid\n" + good + "\n```\n````"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "~~~text\n```math-grid\n" + good + "\n```\n~~~"))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "```math-grid\n" + good.replacingOccurrences(of: "\"unitWidth\":5", with: "\"unitWidth\":true") + "\n```"))
    // Presence does not certify this anisotropic quarter-turn; WebView rejects it.
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: "```math-grid\n" + good.replacingOccurrences(of: "\"B\"", with: "\"A\"") + "\n```"))
  }

  func testDeferredGeometryDeclarationIsBoundedSchematicAndSeparateFromGrid() throws {
    let good = #"{"title":"中心示意","outerWidth":10,"outerHeight":8,"hole":{"x":1,"y":2,"width":2,"height":3}}"#
    func fence(_ payload: String) -> String { "```math-center-cut\n" + payload + "\n```" }
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredGeometryPresentation(in: fence(good)))
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredPresentation(in: fence(good)))
    XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGridPresentation(in: fence(good)))
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredGeometryPresentation(in: "~~~math-center-cut\r\n" + good + "\r\n~~~~"))
    for text in ["```math-center-cut\n" + good, "````text\n" + fence(good) + "\n````",
      fence("{}"), fence(good) + "\n```math-center-cut\n{}",
      fence(good) + "\n```math-center-cut\n{}\n```", fence(good.replacingOccurrences(of: "\"x\":1", with: "\"x\":0")),
      fence(good.replacingOccurrences(of: "\"width\":2", with: "\"width\":9")),
      fence(good.replacingOccurrences(of: "\"outerWidth\":10", with: "\"outerWidth\":true")),
      fence(good.replacingOccurrences(of: "\"outerWidth\":10", with: "\"outerWidth\":1001")),
      fence(good.replacingOccurrences(of: "中心示意", with: "bad\\nline")),
      fence(good.replacingOccurrences(of: "中心示意", with: "<b>title</b>")),
      fence(good.replacingOccurrences(of: "\"x\":1", with: "\"x\":0.0001")),
      fence(good.replacingOccurrences(of: "\"outerHeight\":8", with: "\"outerHeight\":1000")),
      "```math-center-cut\n" + String(repeating: " ", count: 2001) + "\n```"] {
      XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredGeometryPresentation(in: text), text)
    }
  }

  func testCenterCutPromptContractKeepsNativeOnlyScopeExplicit() {
    let general = MathStructuredSolution.prompt("解题", candidates: [], singleSubmission: true, rendererTools: true)
    XCTAssertTrue(general.contains("inline_geometry"))
    XCTAssertTrue(general.contains("候选技能明确提供约定"))
    XCTAssertTrue(general.contains("不是原题测量数据"))
    let native = MathStructuredSolution.prompt("解题", candidates: [], singleSubmission: true, rendererTools: true, nativeOnly: true)
    XCTAssertTrue(native.contains("可用inline_grid"))
    XCTAssertFalse(native.contains("inline_geometry"))
  }

  func testGridAnswerPersistsWithoutFalseNativeMissingButKeepsRequestedViewBoundary() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "rectangle-staircase-reassembly" })
    let data = try XCTUnwrap(skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().first)
      .components(separatedBy: "```")[0]
    let answer = "按原块平移，分块图仅在显示时检查，题意仍待核验。\n```math-grid\n" + data + "\n```"
    for (question, missing) in [("解题并画分块图解", false), ("解题并画线段图", true)] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = MathQuestionStore(directory: directory)
      var calls = 0
      let panel = ScreenshotQuestionPanel(context: .init(text: "长方形25×16剪两块拼成正方形", selectedWord: nil, imageData: photo),
        answer: { _, _, _, _ in
          calls += 1
          let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
            "visual_method_ids":[],"answer":answer,"diagrams":[]]
          return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
        selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
        singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
      panel.present()
      let all = views(try XCTUnwrap(panel.contentView))
      try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = question
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
      try await settle { !panel.isAnswering && panel.history.count == 1 }
      XCTAssertEqual(calls, 1)
      XCTAssertTrue(panel.history[0].answer.contains("```math-grid"))
      XCTAssertEqual(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") }, missing)
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
      try await settle { panel.savedQuestionID != nil }
      let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
      let saved = try XCTUnwrap(solutions.first)
      XCTAssertEqual(saved.diagramFailure != nil, missing, saved.diagramFailure ?? "no failure")
      XCTAssertTrue(saved.answer.contains("```math-grid"))
      XCTAssertEqual(saved.verificationStatus, "unverified")
      panel.close(); await store.close()
    }
  }

  func testOrdinarySolveWithGridCandidateUsesFullToolScopeInOneCall() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let catalogue = try MathSkillCatalogue.load()
    _ = try await store.importBundledMathSkills(catalogue)
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rectangle-staircase-reassembly" })
    let data = try XCTUnwrap(skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().first)
      .components(separatedBy: "```")[0]
    let answer = "两块平移，完整切线和接缝如下；答案待核验。\n```math-grid\n" + data + "\n```"
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "长25厘米宽16厘米的长方形，剪成两块，再拼成一个正方形。", selectedWord: nil, imageData: nil),
      answer: { prompt, _, _, _ in
        calls += 1
        XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.rendererRequestPrefix))
        XCTAssertFalse(prompt.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
        XCTAssertTrue(prompt.contains("inline_grid"))
        let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
          "visual_method_ids":[],"answer":answer,"diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题并验算。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(panel.history[0].answer.contains("```math-grid"))
    XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    panel.close(); await store.close()
  }

  func testCenterCutCandidateOpensFullScopeAndPersistsWithoutHiddenRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let declaration = #"{"title":"中心切割示意","outerWidth":10,"outerHeight":8,"hole":{"x":1,"y":2,"width":2,"height":3}}"#
    let answer = "归一化示意，仍须核对原题。\n```math-center-cut\n" + declaration + "\n```"
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "图4-2是一个挖掉一个小正方形的大正方形纸片，O是大正方形的中心，画一条经过O的线段，把这张纸片分成面积相等的两部分。", selectedWord: nil, imageData: nil),
      answer: { prompt, _, _, _ in
        calls += 1
        XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.rendererRequestPrefix))
        XCTAssertFalse(prompt.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
        XCTAssertTrue(prompt.contains("inline_geometry"))
        let response: [String: Any] = ["schemaVersion":1,"mode":"general","method_id":NSNull(),
          "visual_method_ids":[],"answer":answer,"diagrams":[]]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题并验算。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.history[0].answer, answer)
    XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let saved = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(saved.first?.answer, answer)
    XCTAssertNil(saved.first?.diagramFailure)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    await store.close()
  }

  func testUserClockIncludesCapabilityAndModelSnapshotPreparation() async throws {
    var clock: TimeInterval = 100
    let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: nil),
      answer: { _, _, _, _ in clock += 1; return "待核验回答" }, now: { clock },
      solutionModel: { clock += 3; return "fixture" },
      canUseMathRendererTools: { clock += 2; return false })
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(try XCTUnwrap(panel.performance?.elapsed), 6, accuracy: 0.001)
  }

  func testRendererCapabilityIsRecheckedForEachSubmission() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    var supported = false
    var prompts: [String] = []
    var selections = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "原来有100人", selectedWord: nil, imageData: nil),
      answer: { prompt, _, _, _ in
        prompts.append(prompt)
        if supported {
          return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"原题信息不足。","diagrams":[],"diagram_omission":{"status":"unreadable_or_insufficient","reason":"没有提供人数变化条件。"}}"#
        }
        return "原题信息不足。"
      }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in selections += 1; return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true,
      rendererToolsMath: true, canUseMathRendererTools: { supported })
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    let input = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    let ask = try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    input.stringValue = "解题"; ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertFalse(try XCTUnwrap(prompts.first).hasPrefix(MathStructuredSolution.rendererRequestPrefix))
    supported = true
    input.stringValue = "解题"; ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 2 }
    XCTAssertTrue(try XCTUnwrap(prompts.last).hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
    XCTAssertEqual(prompts.count, 2)
    XCTAssertEqual(selections, 1)
    await store.close()
  }

  func testAutomaticVisualClaimCannotHideValidAreaButExplicitUserViewStillApplies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    // This verifies claimed-view handling, independently of which two visual
    // slots a full catalogue retrieval happens to rank for this rectangle.
    let entries = try MathSkillCatalogue.load().importEntries().filter {
      ["和差问题", "线段图"].contains($0.title)
    }
    _ = try await store.importMethods(entries)
    let methods = try await store.automaticMethods()
    let visual = try XCTUnwrap(methods.first { $0.title == "线段图" })
    let main = try XCTUnwrap(methods.first { $0.title == "和差问题" })
    let response = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "mode": "native_recipe", "method_id": main.id,
      "visual_method_ids": [visual.id], "answer": "长宽由和与差确定。",
      "diagrams": [["id": "rect", "title": "长方形", "kind": "rectangle_sum_difference",
        "rectangle_evidence": "长方形长和宽之和18厘米，长比宽多2厘米。",
        "total_sides": ["value": 18, "unit": "厘米", "evidence": "长和宽之和18厘米"],
        "difference": ["value": 2, "unit": "厘米", "evidence": "长比宽多2厘米"]]]])
    let image = NSImage(size: NSSize(width: 200, height: 60))
    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 60).fill(); image.unlockFocus()
    let photo = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
    for explicitView in [false, true] {
      let panel = ScreenshotQuestionPanel(context: .init(text: "长方形长和宽之和是18厘米，长比宽多2厘米。求长方形面积。", selectedWord: nil, imageData: photo),
        answer: { prompt, _, _, _ in
          if !explicitView {
            if let output = ProcessInfo.processInfo.environment["MATH_PREPARATION_DIAGNOSTICS_DIR"] {
              let directory = URL(fileURLWithPath: output, isDirectory: true)
              try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
              try prompt.write(to: directory.appendingPathComponent("rectangle-regression-prompt.txt"), atomically: true, encoding: .utf8)
            }
            XCTAssertTrue(prompt.contains("名称：" + visual.title), "Regression must include the actual claimed visual candidate")
            XCTAssertTrue(prompt.contains(visual.instructions), "Keep the full exact visual snapshot despite request-local handles")
          }
          return String(decoding: response, as: UTF8.self)
        }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
        selectMethodAutomatically: { _, _, _ in XCTFail("No selector call"); return .init(method: nil, reason: "") },
        singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
      panel.present()
      let all = views(try XCTUnwrap(panel.contentView))
      // Empty re-OCR must preserve the already recognized problem text.
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
      try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = explicitView ? "不要使用方程，请使用小学生的知识领域解题，请画线段图。" : "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
      try await settle { !panel.isAnswering && panel.history.count == 1 }
      let transcript = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
      var attachments = 0
      transcript.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: transcript.textStorage?.length ?? 0)) { value, _, _ in
        if value is NSTextAttachment { attachments += 1 }
      }
      if explicitView { XCTAssertEqual(attachments, 0) }
      else {
        XCTAssertGreaterThan(attachments, 0); XCTAssertTrue(panel.history[0].answer.contains("80"))
        let storage = try XCTUnwrap(transcript.textStorage)
        var firstAttachment: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
          if value is NSTextAttachment { firstAttachment = range; stop.pointee = true }
        }
        let attachmentRange = try XCTUnwrap(firstAttachment)
        let answerRange = (storage.string as NSString).range(of: "回答：")
        XCTAssertLessThan(attachmentRange.location, answerRange.location,
          "The actual graph must precede the full calculation explanation")
        XCTAssertNotNil(panel.performance?.firstTokenLatency,
          "A completed non-streaming answer must have a visible-output timestamp")
        let layout = try XCTUnwrap(transcript.layoutManager)
        let container = try XCTUnwrap(transcript.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: attachmentRange, actualCharacterRange: nil)
        let diagramTop = layout.boundingRect(forGlyphRange: glyphs, in: container).minY + transcript.textContainerOrigin.y
        let scroll = try XCTUnwrap(transcript.enclosingScrollView)
        XCTAssertEqual(scroll.contentView.bounds.minY, diagramTop, accuracy: 2,
          "Completion must reveal the top of the graph, not scroll to the final footnote")
        if let directory = ProcessInfo.processInfo.environment["MATH_PRESENTATION_PREVIEW_DIR"],
          let content = panel.contentView,
          let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: bitmap)
          let output = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
          try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("diagram-first-native-panel.png"))
        }
        try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
        try await settle { panel.savedQuestionID != nil }
        let saved = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
        let solution = try XCTUnwrap(saved.first)
        XCTAssertTrue(solution.visualMethods.isEmpty)
        XCTAssertTrue(solution.methodClaimWarning?.contains("画法与实际图解不一致") == true)
        XCTAssertEqual(solution.verificationStatus, "unverified")
        XCTAssertEqual(solution.diagrams.first?.kind, .area)
        XCTAssertEqual(solution.method?.id, main.id)
      }
      panel.close()
    }
    await store.close()
  }

  func testOneAnswerWithNoNamedMethodStillDrawsAndPersistsUnverified() async throws {
    try await delivery(programArithmetic: false)
  }
  func testShortRelationshipResponseReceivesCompleteNativeArithmeticAndDiagram() async throws {
    try await delivery(programArithmetic: true)
  }
  func testSingleSubmissionToolNormalizedAnswerDrawsWithNullablePurchaseMethod() async throws {
    try await delivery(programArithmetic: true, singleSubmission: true)
  }
  func testSubmissionFlagDoesNotChangePlainSinglePass() async throws {
    try await delivery(programArithmetic: false, singleSubmission: true)
  }
  func testTextOnlyRequestBypassesSingleSubmissionTool() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo), answer: { prompt, _, _, _ in
      calls += 1
      XCTAssertFalse(prompt.hasPrefix(MathStructuredSolution.submissionRequestPrefix))
      XCTAssertFalse(prompt.hasPrefix(MathStructuredSolution.requestPrefix))
      XCTAssertFalse(prompt.contains(MathDiagramAnswer.marker))
      return "按各店优惠分别计算，比较实付款。\n```math-methods\n{\"method_id\":null,\"visual_method_ids\":[]}\n```"
    }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No extra selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "解题，只要文字，不画图。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.history[0].answer, "按各店优惠分别计算，比较实付款。")
    await store.close()
  }

  func testRequiredDiagramMissingIsVisibleAndPersistedWithoutAnotherModelCall() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text:"", selectedWord:nil, imageData:photo),
      answer: { prompt, _, _, _ in
        calls += 1
        XCTAssertTrue(prompt.contains("本次同时要求实际图解"))
        return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"原图条件不足，尚不能确定图中数量。","diagrams":[]}"#
      }, originalImageData:photo, saveQuestion:{ try await store.save($0) }, mathStore:store,
      selectMethodAutomatically:{ _, _, _ in XCTFail("No second routing call"); return .init(method:nil, reason:"") },
      singlePassAutomaticMethods:true, programArithmetic:true)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    let input = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    input.stringValue = "使用小学知识解题并验算。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls,1)
    XCTAssertEqual(panel.history[0].answer,"原图条件不足，尚不能确定图中数量。")
    XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertNotNil(saved.diagramFailure); XCTAssertTrue(saved.diagrams.isEmpty)
    XCTAssertEqual(saved.verificationStatus,"unverified")
    await store.close()
  }
  func testRendererExplicitUnhelpfulDiagramReasonDoesNotBecomeMissingPictureFailure() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, _, _, _ in
        calls += 1
        XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
        return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"原图的拓展题可按路径逐边核对。\n\n图解说明：目前没有能准确表达这类路径的图形工具。","diagrams":[],"diagram_omission":{"status":"no_helpful_diagram","reason":"目前没有能准确表达这类路径的图形工具。"}}"#
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "使用小学知识解题并验算。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(panel.history[0].answer.contains("没有能准确表达"))
    XCTAssertFalse(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertNil(saved.diagramFailure); XCTAssertTrue(saved.diagrams.isEmpty)
    XCTAssertEqual(saved.verificationStatus, "unverified")
    await store.close()
  }
  func testRendererBadDiagramStillPreservesTextAndPersistsActualFailure() async throws {
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { _, _, _, _ in
        calls += 1
        return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"按原题逐边核对，路径为E→F→G→H→I→E→G。","diagrams":[],"diagram_submission_failure":"submission_shape"}"#
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No hidden selector"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "使用小学知识解题并验算。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1); XCTAssertTrue(panel.history[0].answer.contains("E→F→G"))
    XCTAssertTrue(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("图解未生成") })
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let saved = try XCTUnwrap(solutions.first)
    XCTAssertTrue(saved.answer.contains("E→F→G")); XCTAssertTrue(saved.diagrams.isEmpty)
    XCTAssertTrue(saved.diagramFailure?.contains("图解参数") == true)
    XCTAssertEqual(saved.verificationStatus, "unverified")
    await store.close()
  }
  private func delivery(programArithmetic: Bool, singleSubmission: Bool = false) async throws {
    var response = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "RealPurchaseOffersResponse", withExtension: "txt", subdirectory: "Fixtures")), encoding: .utf8)
      .replacingOccurrences(of: MathDiagramAnswer.marker,
        with: "```math-methods\n{\"method_id\":null,\"visual_method_ids\":[]}\n```\n" + MathDiagramAnswer.marker)
    if programArithmetic {
      let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "real-purchase-offers-20261013", withExtension: "json", subdirectory: "Fixtures")))
      let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let recipe = try XCTUnwrap((envelope["diagrams"] as? [[String: Any]])?.first)
      response = String(decoding: try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "mode": "native_recipe", "method_id": NSNull(),
        "visual_method_ids": [], "answer": "先按各店优惠规则算实际付款，再比较。", "diagrams": [recipe]
      ]), as: UTF8.self)
    }
    let modelResponse = response
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    var answerCalls = 0, selectorCalls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, source, _, partial in
        answerCalls += 1
        XCTAssertEqual(source.imageData, photo)
        XCTAssertEqual(prompt.hasPrefix(MathStructuredSolution.submissionRequestPrefix), programArithmetic && singleSubmission)
        if programArithmetic && singleSubmission {
          XCTAssertTrue(prompt.contains("submit_math_solution"))
          XCTAssertFalse(prompt.contains("六字段响应"))
          XCTAssertFalse(prompt.contains("恰有schemaVersion"))
        }
        XCTAssertTrue(prompt.contains(programArithmetic ? "尚未采用" : "不是已选方法"))
        XCTAssertTrue(prompt.contains(programArithmetic ? "可以没有已有主方法" : "主方法允许null"))
        XCTAssertTrue(prompt.contains("purchase_comparison"))
        partial(modelResponse)
        return modelResponse
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in
        selectorCalls += 1
        XCTFail("Single-pass path must not invoke a separate selector")
        return .init(method: nil, reason: "must not run")
      }, singlePassAutomaticMethods: true, programArithmetic: programArithmetic, singleSubmissionMath: singleSubmission)
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    let input = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    input.stringValue = "不要使用方程，使用小学知识解题并验算。"
    all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }?.state = .on
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(answerCalls, 1); XCTAssertEqual(selectorCalls, 0)
    if let output = ProcessInfo.processInfo.environment["MATH_PREPARATION_DIAGNOSTICS_DIR"] {
      let directory = URL(fileURLWithPath:output,isDirectory:true)
      try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
      let evidence: [String:Any] = ["providerCalls":0,"recordedAnswerReplay":true,
        "programArithmetic":programArithmetic,"preparationSeconds":panel.singlePassPreparationDurations,
        "userAnswerSeconds":panel.performance?.elapsed.map { $0 as Any } ?? NSNull()]
      try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys])
        .write(to:directory.appendingPathComponent(programArithmetic ? "program-native.json" : "plain-single-pass.json"))
    }
    XCTAssertFalse(panel.history[0].answer.contains("math-methods"))
    if programArithmetic {
      XCTAssertTrue(panel.history[0].answer.contains("程序计算"))
      for value in ["2505", "2616", "111"] { XCTAssertTrue(panel.history[0].answer.contains(value)) }
      XCTAssertTrue(panel.history[0].answer.contains("仍需用户核验"))
    }
    var attachments = 0
    for view in all.compactMap({ $0 as? NSTextView }) {
      view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, _, _ in
        if value is NSTextAttachment { attachments += 1 }
      }
      XCTAssertFalse(view.string.contains("图解未生成"))
    }
    XCTAssertEqual(attachments, 1)
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    await store.close()
    let reopened = MathQuestionStore(directory: root)
    let savedSolutions = try await reopened.solutions(questionID: id)
    let solution = try XCTUnwrap(savedSolutions.first)
    XCTAssertNil(solution.method); XCTAssertNil(solution.selectionFailure)
    XCTAssertNil(solution.diagramFailure); XCTAssertEqual(solution.diagrams.count, 1)
    XCTAssertEqual(solution.verificationStatus, "unverified")
    let savedPhoto = try await reopened.originalImage(questionID: id)
    XCTAssertEqual(savedPhoto, photo)
    await reopened.close()
  }
}
