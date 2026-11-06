import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathDiagramSystemDeliveryTests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func attachments(_ panel: ScreenshotQuestionPanel) -> Int {
    views(panel.contentView!).compactMap { $0 as? NSTextView }.reduce(0) { count, text in
      var result = count
      text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) {
        value, _, _ in if value is NSTextAttachment { result += 1 }
      }
      return result
    }
  }
  private func submit(_ panel: ScreenshotQuestionPanel, _ request: String) throws {
    panel.present()
    let all = views(panel.contentView!)
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = request
    all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }?.state = .on
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
  }
  private func settle(_ panel: ScreenshotQuestionPanel) async throws {
    for _ in 0..<250 {
      if !panel.isAnswering && panel.history.count == 1 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Question did not finish")
  }
  func testSourceRepairRequiresIndependentDerivationWithoutEchoingRejectedData() {
    let prompt = MathDiagramAnswer.repairPrompt(question: "请画时间比较表", views: [.table],
      failure: "原题数值来源缺失 private-id-secret 31.5")
    XCTAssertTrue(prompt.contains("每张图各自声明原题输入及完整运算链"))
    XCTAssertTrue(prompt.contains("不能把上一张图的结果复制"))
    XCTAssertFalse(prompt.contains("private-id-secret"))
    XCTAssertFalse(prompt.contains("31.5"))
  }
  func testVisualPrimaryInActualBundledCategoryTriggersCommonProtocol() {
    for title in ["线段图", "面积图", "状态图", "列表法", "韦恩图", "周期图", "部分整体", "平均移量"] {
      let method = MathTeachingMethod(id: title, versionID: "1", title: title, category: "计数、图形和推理", instructions: "画出关系", createdAt: Date())
      XCTAssertTrue(ScreenshotQuestionPanel.requestsDiagram("说明这道题", using: method, visualMethods: []), title)
      let prompt = ScreenshotQuestionPanel.question("说明这道题", using: method)
      XCTAssertTrue(prompt.contains("quantity_plan"))
      XCTAssertFalse(prompt.contains("\"origin\":"))
      XCTAssertFalse(ScreenshotQuestionPanel.requestsDiagram("不要画图，请解题", using: method, visualMethods: []))
    }
    let method = MathTeachingMethod(id: "sum", versionID: "1", title: "和差问题", category: "数量关系", instructions: "先算和与差", createdAt: Date())
    XCTAssertTrue(ScreenshotQuestionPanel.requestsDiagram("请解题", using: method, visualMethods: []), "Missing visual selection must not silently disable math drawing")
  }
  func testTargetedRepairContainsOnlyRelevantGeometryAndNoFailedAnswerValues() {
    let hints = ["单位错误 secret 123", "间隔错误 secret 123", "状态错误 secret 123", "韦恩错误 secret 123", "其他错误 secret 123"]
    for hint in hints {
      let repair = MathDiagramAnswer.repairPrompt(question: "只解第六题，请画面积图", views: [.area], failure: hint)
      XCTAssertTrue(repair.contains("view:area"))
      XCTAssertFalse(repair.contains("view:venn"))
      XCTAssertFalse(repair.contains("secret"))
      XCTAssertFalse(repair.contains("123"))
    }
    XCTAssertEqual(ScreenshotQuestionPanel.diagramViews("画面积图", method: nil, visualMethods: []), [.area])
    XCTAssertEqual(ScreenshotQuestionPanel.diagramViews("画比较线段图", method: nil, visualMethods: []), [.barComparison])
  }
  func testJourneyGuidanceExplainsSameDistanceAndDeadlineInsteadOfForcingRectangle() {
    let prompt = MathDiagramAnswer.prompt(views: [.table, .partWhole])
    XCTAssertTrue(prompt.contains("两行路程引用同一distance"))
    XCTAssertTrue(prompt.contains("totalTime=sum(outTime,returnTime)"))
    XCTAssertTrue(prompt.contains("excess=difference(totalTime,limit)"))
    XCTAssertTrue(prompt.contains("时间分段则全部使用时间单位"))
    XCTAssertFalse(prompt.contains("优先只画返程矩形"))
    let explicitArea = MathDiagramAnswer.prompt(views: [.area])
    XCTAssertTrue(explicitArea.contains("view:area"))
    XCTAssertTrue(explicitArea.contains("用户指定面积图时不可替换"))
  }

  func testTableRepairsExplainTheActualProtocolFailureWithoutLeakingValues() {
    for failure in ["关系不能将输出自身作为输入。 secret 987", "表格名称或列数不一致。 secret 987", "图形数量关系的算术不成立。 secret 987", "数量关系的输入数目无效。 secret 987"] {
      let prompt = MathDiagramAnswer.repairPrompt(question: "请解题", views: [.table], failure: failure)
      XCTAssertTrue(prompt.contains("label自动显示"))
      XCTAssertTrue(prompt.contains("factIDs数目必须等于columns"))
      XCTAssertTrue(prompt.contains("checks只验证已经声明的结果"))
      XCTAssertTrue(prompt.contains("equal必须且只能有一个输入"))
      XCTAssertFalse(prompt.contains("secret"))
      XCTAssertFalse(prompt.contains("987"))
      XCTAssertFalse(prompt.contains("view:area"))
    }
  }
  func testAreaRepairMatchesRateSkillAndInverseQuantityProtocol() {
    for failure in ["面积图缺少长乘宽等于面积的关系。 secret 987", "乘除关系的单位不一致。 secret 987"] {
      let prompt = MathDiagramAnswer.repairPrompt(question: "请解题", views: [.area], failure: failure)
      XCTAssertTrue(prompt.contains("速度×时间=路程"))
      XCTAssertTrue(prompt.contains("单价×数量=总价"))
      XCTAssertTrue(prompt.contains("inputs:[乘积,已知因子]"))
      XCTAssertTrue(prompt.contains("无需额外product检查"))
      XCTAssertFalse(prompt.contains("长宽单位cm或厘米"))
      XCTAssertFalse(prompt.contains("secret"))
      XCTAssertFalse(prompt.contains("987"))
    }
  }
  func testCapturedPartialDrawingRemainsVisibleWithoutAutomaticRepair() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "RateRectanglePartialResponse", withExtension: "txt", subdirectory: "Fixtures"))
    let response = try String(contentsOf: url)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: nil), answer: { _, _, _, _ in
      calls += 1
      return response
    })
    try submit(panel, "请用面积图解题")
    try await settle(panel)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(attachments(panel), 2)
    XCTAssertEqual(panel.history.first?.answer, MathDiagramAnswer.displayText(response))
    panel.close()
  }
  func testMissingDiagramDoesNotConsumeReturnedRepairPayload() async throws {
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: nil), answer: { _, _, _, _ in
      calls += 1
      XCTAssertEqual(calls, 1, "A missing figure must not trigger a hidden second request")
      return "原来的解答"
    })
    try submit(panel, "请用面积图解题")
    try await settle(panel)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(attachments(panel), 0)
    XCTAssertEqual(panel.history.first?.answer, "原来的解答")
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("图解未生成") })
    panel.close()
  }
  func testPartialDiagramFailureAndCheckedPicturesPersistTogetherWithoutRepair() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "RateRectanglePartialResponse", withExtension: "txt", subdirectory: "Fixtures"))
    let response = try String(contentsOf: url)
    let parsed = MathDiagramAnswer.parse(response)
    XCTAssertEqual(parsed.diagrams.count, 2)
    XCTAssertNotNil(parsed.failure)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.area)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: photo), answer: { _, _, _, _ in
      calls += 1
      return response
    }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store)
    defer { panel.close() }
    try submit(panel, "请用面积图解题")
    try await settle(panel)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(attachments(panel), 2)
    XCTAssertEqual(panel.history.first?.answer, parsed.text)
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    for _ in 0..<250 { if panel.savedQuestionID != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(solutions.first?.diagrams, parsed.diagrams)
    XCTAssertEqual(solutions.first?.diagramFailure, parsed.failure)
    XCTAssertEqual(solutions.first?.verificationStatus, "unverified")
    let originalPhoto = try await store.originalImage(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(originalPhoto, photo)
    await store.close()
  }
  func testOrdinaryTableListAndPeriodRequestsDoNotTriggerMathDrawing() {
    for request in ["请翻译这个表格中的英文", "解释这个列表", "解释英文表格中的周期参数"] {
      XCTAssertFalse(ScreenshotQuestionPanel.requestsDiagram(request, using: nil, visualMethods: []))
      XCTAssertEqual(ScreenshotQuestionPanel.question(request, using: nil), request)
    }
    for request in ["请画面积图", "请画表格", "绘制周期图"] {
      XCTAssertTrue(ScreenshotQuestionPanel.requestsDiagram(request, using: nil, visualMethods: []))
    }
  }
  func testFirstAnswerPreservesSolutionAndOriginalForEveryExistingNativeView() async throws {
    for diagram in MathDiagramFixtures.all {
      let photo = try MathDiagramRenderer.renderPNG(diagram)
      let body = "未核验的原解答：\(diagram.id)"
      let payload = body + "\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(String(decoding: try JSONEncoder().encode(diagram), as: UTF8.self))]}\n```"
      var calls = 0
      let panel = ScreenshotQuestionPanel(context: .init(text: "原题文字", selectedWord: nil, imageData: photo),
        answer: { prompt, source, history, partial in
          calls += 1
          XCTAssertEqual(source.imageData, photo)
          XCTAssertTrue(history.isEmpty)
          XCTAssertTrue(prompt.contains("quantity_plan"))
          XCTAssertFalse(prompt.contains(body))
          partial(payload)
          return payload
        }, originalImageData: photo)
      try submit(panel, diagram.id == "unknown" ? "请画图示意" : "请画图解题")
      try await settle(panel)
      XCTAssertEqual(calls, 1, diagram.id)
      XCTAssertEqual(panel.history.first?.answer, body)
      XCTAssertGreaterThan(attachments(panel), 0, diagram.id)
      panel.close()
    }
  }
  func testValidReturnedDiagramAcceptedEvenWithoutPreselectedVisualAndTextOnlyWins() async throws {
    let diagram = MathDiagramFixtures.bar
    let payload = "原解答\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(String(decoding: try JSONEncoder().encode(diagram), as: UTF8.self))]}\n```"
    for (request, expected) in [("解释这段话", true), ("只要文字，不要画图", false)] {
      var calls = 0
      let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: nil),
        answer: { _, _, _, _ in calls += 1; return payload })
      try submit(panel, request)
      try await settle(panel)
      XCTAssertEqual(calls, 1)
      XCTAssertEqual(attachments(panel) > 0, expected)
      XCTAssertEqual(panel.history.first?.answer, "原解答")
      panel.close()
    }
  }

  func testWrongViewIsRejectedWithoutRetryAndPersistsFailure() async throws {
    let wrong = "正文\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(String(decoding: try JSONEncoder().encode(MathDiagramFixtures.bar), as: UTF8.self))]}\n```"
    var calls = 0
    var saved: MathQuestionSaveRequest?
    let image = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.area)
    let panel = ScreenshotQuestionPanel(context: .init(text: "面积题", selectedWord: nil, imageData: image),
      answer: { prompt, _, _, _ in
        calls += 1
        XCTAssertTrue(prompt.contains("view:area"))
        return wrong
      }, originalImageData: image, saveQuestion: { request in
        saved = request
        throw NSError(domain: "isolated", code: 1)
      })
    defer { panel.close() }
    try submit(panel, "请解题并画面积图")
    try await settle(panel)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(attachments(panel), 0)
    XCTAssertEqual(panel.history.first?.answer, "正文")
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    for _ in 0..<100 { if saved != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertEqual(saved?.solutions.first?.diagrams.map(\.kind), [])
    XCTAssertNotNil(saved?.solutions.first?.diagramFailure)
    XCTAssertEqual(saved?.imageData, image)
  }

  func testLateAnswerAfterStopOrClosureCannotStartRepair() async throws {
    for closes in [false, true] {
      var calls = 0
      var continuation: CheckedContinuation<String, Never>?
      let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: nil),
        answer: { _, _, _, _ in
          calls += 1
          return await withCheckedContinuation { continuation = $0 }
        })
      try submit(panel, "请解题并画面积图")
      for _ in 0..<100 { if continuation != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
      let pending = try XCTUnwrap(continuation)
      if closes { panel.close() }
      else { try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "停止" }).performClick(nil) }
      pending.resume(returning: "供应器忽略取消而迟到的答案")
      try await Task.sleep(nanoseconds: 30_000_000)
      XCTAssertEqual(calls, 1)
      XCTAssertTrue(panel.history.isEmpty)
      XCTAssertEqual(attachments(panel), 0)
      panel.close()
    }
  }
}
