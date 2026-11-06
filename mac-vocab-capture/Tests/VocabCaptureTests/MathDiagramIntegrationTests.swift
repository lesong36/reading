import AppKit
import PDFKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathDiagramIntegrationTests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<250 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("UI operation did not settle")
  }
  private func hasImage(_ text: NSTextView) -> Bool {
    var found = false
    text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in
      found = found || value is NSTextAttachment
    }
    return found
  }
  private func begin(_ panel: ScreenshotQuestionPanel, question: String = "不用方程，请画出关系并解题") throws {
    panel.present()
    let all = views(panel.contentView!)
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = question
    if let image = all.compactMap({ $0 as? NSButton }).first(where: { $0.title == "参考原截图" }), !image.isHidden {
      image.state = .on
    }
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
  }

  func testInvalidDifferenceRatioRetainsTextAndSavesFailureWithoutAutomaticRepair() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let primary = try await store.saveMethod(title: "差倍问题", category: "两个未知数", instructions: "差除以倍数减一；同一两人年龄差不变。")
    let visual = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "用等份表达倍数与差。")
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let body = "第44题：小明15岁，爸爸45岁；同一两人的年龄差30岁不变。第61题：原数90，乘10后900，多810。"
    let original = body + "\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[{\"id\":\"broken\",\"title\":\"年龄\",\"kind\":\"equal_parts\",\"facts\":[],\"relations\":[{\"operation\":\"difference\",\"inputIDs\":[\"father\",\"child\"]}]}]}\n```"
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, source, _, _ in
        calls += 1
        XCTAssertEqual(source.imageData, photo)
        XCTAssertFalse(prompt.contains("kind: bar_comparison"))
        return original
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in .init(method: primary, visualMethods: [visual], reason: "两道题独立使用差倍关系") })
    defer { panel.close() }
    try begin(panel)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.history.first?.answer, body)
    XCTAssertFalse(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("图解未生成") })
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let solutions = try await store.solutions(questionID: id)
    XCTAssertEqual(solutions.first?.answer, body)
    XCTAssertEqual(solutions.first?.diagrams, [])
    XCTAssertNotNil(solutions.first?.diagramFailure)
    XCTAssertEqual(solutions.first?.verificationStatus, "unverified")
    let originalPhoto = try await store.originalImage(questionID: id)
    XCTAssertEqual(originalPhoto, photo)
    await store.close()
  }

  func testExplicitDiagramFollowupPreservesUserScopeAcrossFollowupsAndExcludesEarlierAnswers() {
    let history = [ScreenshotQuestionTurn(question: "只解第44题", answer: "SECRET_UNVERIFIED_ANSWER"),
      ScreenshotQuestionTurn(question: "不要用方程", answer: "另一个未核验答案")]
    let scope = ScreenshotQuestionPanel.diagramRequestScope("补个图", history: history)
    XCTAssertTrue(scope.contains("只解第44题"))
    XCTAssertTrue(scope.contains("不要用方程"))
    XCTAssertTrue(scope.contains("本次用户请求：\n补个图"))
    XCTAssertFalse(scope.contains("SECRET_UNVERIFIED_ANSWER"))
    XCTAssertFalse(scope.contains("另一个未核验答案"))
    XCTAssertEqual(ScreenshotQuestionPanel.diagramRequestScope("只解第61题", history: []), "只解第61题")
  }

  func testNegatedDifferenceRatioDoesNotRouteAnUnrelatedProblemToRecipeRepair() {
    XCTAssertFalse(ScreenshotQuestionPanel.usesDifferenceRatioRecipe(nil, answer: "这不是差倍问题。"))
    XCTAssertFalse(ScreenshotQuestionPanel.usesDifferenceRatioRecipe(nil, answer: "本题不适合差倍法。"))
    XCTAssertTrue(ScreenshotQuestionPanel.usesDifferenceRatioRecipe(nil, answer: "实际采用主解法：差倍问题。"))
  }

  func testSumRatioMethodIsNotOverriddenByDifferenceInItsExplanation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let method = try await store.saveMethod(title: "和倍问题", category: "数量关系", instructions: "用和除以总份数")
    XCTAssertFalse(ScreenshotQuestionPanel.usesDifferenceRatioRecipe(method, answer: "甲乙共48人，甲是乙3倍，甲36人、乙12人，相差24人。"))
    await store.close()
  }

  func testExplicitDrawingWorksWithoutSelectedMethodAndHonorsTextOnlyRequests() {
    XCTAssertTrue(ScreenshotQuestionPanel.question("请画线段图解题", using: nil).contains("```math-diagrams"))
    let plain = "请解释这个英文句子的结构"
    XCTAssertEqual(ScreenshotQuestionPanel.question(plain, using: nil, automaticSelectionFailed: true), plain)
    for request in ["只要文字解题", "不用画图，请解题", "不需要画图", "不画线段图", "不要画线段图", "不用线段图", "不要图解"] {
      XCTAssertFalse(ScreenshotQuestionPanel.requestsDiagram(request, using: nil, visualMethods: [], automaticSelectionFailed: true))
    }
    XCTAssertTrue(ScreenshotQuestionPanel.requestsDiagram("请解题", using: nil, visualMethods: [], automaticSelectionFailed: true))
  }

  func testFailedAutomaticSelectionStillRendersFirstAnswerDiagramWithoutExtraCall() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let body = "爸爸年龄是小明3倍，同一两人的年龄差30岁不变，小明15岁。"
    let payload = """
    ```math-diagrams
    {"schemaVersion":1,"diagrams":[{"id":"q44","title":"年龄差倍","kind":"difference_ratio","difference":{"value":30,"unit":"岁","evidence":"原题同一两人年龄差30岁不变"},"multiplier":{"value":3,"unit":"","evidence":"原题爸爸年龄是小明3倍"}}]}
    ```
    """
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, source, history, partial in
        calls += 1
        XCTAssertEqual(source.imageData, photo)
        XCTAssertTrue(prompt.contains("```math-diagrams"))
        XCTAssertTrue(history.isEmpty)
        partial(body + "\n" + payload)
        return body + "\n" + payload
      }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { _, _, _ in throw MathMethodMatchError.invalidOutput })
    defer { panel.close() }
    try begin(panel, question: "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。")
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.history.first?.answer, body)
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    await store.close()
  }

  func testFirstAnswerDiagramPersistsDisplayedFigureIntoLibraryAndPDF() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let method = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "对齐公共部分，标明差。")
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let data = try JSONEncoder().encode(MathDiagramFixtures.bar)
    let complete = "先比较，再求和。\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(String(decoding: data, as: UTF8.self))]}\n```"
    var calls: [String] = []
    let panel = ScreenshotQuestionPanel(context: .init(text: "甲45人乙27人", selectedWord: nil, imageData: photo),
      answer: { prompt, _, _, partial in
        calls.append(prompt)
        let result = complete
        partial(result)
        return result
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in .init(method: nil, visualMethods: [method], reason: "比较两量") })
    defer { panel.close() }
    try begin(panel)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(panel.history.first?.answer, "先比较，再求和。")
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let solutions = try await store.solutions(questionID: id)
    XCTAssertEqual(solutions.first?.diagrams, [MathDiagramFixtures.bar])
    XCTAssertNil(solutions.first?.diagramFailure)
    XCTAssertEqual(solutions.first?.verificationStatus, "unverified")
    let original = try await store.originalImage(questionID: id)
    XCTAssertEqual(original, photo)
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.present(questionID: id)
    try await settle { self.views(library.contentView!).compactMap { $0 as? NSTextView }.contains(where: self.hasImage) }
    let records = try await store.list()
    let pdf = root.appendingPathComponent("answers.pdf")
    let pages = try await MathQuestionPDFExporter.export(records: records, store: store, to: pdf, options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: pdf))
    XCTAssertGreaterThanOrEqual(pages, 3)
    XCTAssertTrue(document.string?.contains("答案图解") == true)
    XCTAssertTrue(document.string?.contains(MathDiagramFixtures.bar.title) == true)
    XCTAssertTrue(document.string?.contains("尚未核验") == true)
    let practice = root.appendingPathComponent("practice.pdf")
    _ = try await MathQuestionPDFExporter.export(records: records, store: store, to: practice)
    XCTAssertFalse(PDFDocument(url: practice)?.string?.contains("答案图解") == true)
    if let location = ProcessInfo.processInfo.environment["MATH_DIAGRAM_INTEGRATION_ARTIFACTS"] {
      let destination = URL(fileURLWithPath: location)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: pdf, to: destination.appendingPathComponent("integration-answer.pdf"))
      let figurePage = try XCTUnwrap(document.page(at: document.pageCount - 1))
      let image = figurePage.thumbnail(of: NSSize(width: 900, height: 1273), for: .mediaBox)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("integration-pdf.png"))
    }
    await store.close()
  }

  func testInvalidDiagramRetainsOriginalPhotoAndDoesNotRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let method = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "比较甲乙人数，标明差。")
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    var invalid = MathDiagramFixtures.bar
    invalid.relations[0] = .init(operation: .difference, inputIDs: ["a", "missing-b"], outputID: "difference")
    let invalidData = try JSONEncoder().encode(invalid)
    let original = "甲乙人数相差18人。\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(String(decoding: invalidData, as: UTF8.self))]}\n```"
    let rejected = MathDiagramAnswer.parse(original)
    XCTAssertNotNil(rejected.failure)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "甲45人乙27人", selectedWord: nil, imageData: photo),
      answer: { _, source, turns, _ in
        calls += 1
        XCTAssertEqual(source.imageData, photo)
        XCTAssertTrue(turns.isEmpty)
        return original
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in .init(method: nil, visualMethods: [method], reason: "比较两量") })
    defer { panel.close() }
    try begin(panel)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(panel.history.first?.answer, "甲乙人数相差18人。")
    XCTAssertFalse(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("图解未生成") })
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(solutions.first?.diagrams, [])
    XCTAssertEqual(solutions.first?.diagramFailure, rejected.failure)
    await store.close()
  }

  func testExplicitDiagramFollowupUsesOriginalPhotoAndUserScopeWithoutEarlierAIFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    let diagram = String(decoding: try JSONEncoder().encode(MathDiagramFixtures.bar), as: UTF8.self)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "原题", selectedWord: nil, imageData: photo),
      answer: { prompt, source, history, _ in
        calls += 1
        XCTAssertEqual(source.imageData, photo)
        if calls == 1 { return "SECRET_UNVERIFIED_ANSWER" }
        XCTAssertTrue(prompt.contains("只解第44题"))
        XCTAssertTrue(prompt.contains("本次用户请求：\n补图"))
        XCTAssertFalse(prompt.contains("SECRET_UNVERIFIED_ANSWER"))
        XCTAssertTrue(history.isEmpty)
        return "第44题图解\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":[\(diagram)]}\n```"
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store)
    defer { panel.close() }
    try begin(panel, question: "只解第44题，请画线段图")
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1, "Missing diagram must not start an automatic request")
    try begin(panel, question: "补图")
    try await settle { !panel.isAnswering && panel.history.count == 2 }
    XCTAssertEqual(calls, 2, "One call for each explicit user request")
    XCTAssertEqual(panel.history.first?.answer, "SECRET_UNVERIFIED_ANSWER")
    XCTAssertEqual(panel.history.last?.answer, "第44题图解")
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let solutions = try await store.solutions(questionID: id)
    XCTAssertEqual(solutions.count, 2)
    let missing = try XCTUnwrap(solutions.first { $0.answer == "SECRET_UNVERIFIED_ANSWER" })
    XCTAssertNotNil(missing.diagramFailure)
    XCTAssertTrue(missing.diagrams.isEmpty)
    let completed = try XCTUnwrap(solutions.first { $0.answer == "第44题图解" })
    XCTAssertEqual(completed.diagrams, [MathDiagramFixtures.bar])
    XCTAssertNil(completed.diagramFailure)
    let savedPhoto = try await store.originalImage(questionID: id)
    XCTAssertEqual(savedPhoto, photo)
    await store.close()
  }

  func testMissingDiagramRetainsTextAndShowsFailureWithoutRetryWhilePhotoRemainsSavable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let method = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "画比较关系。")
    let photo = try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar)
    var count = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "题目", selectedWord: nil, imageData: photo), answer: { _, _, _, _ in count += 1; return "有效文字回答" }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in .init(method: nil, visualMethods: [method], reason: "适用") })
    defer { panel.close() }
    try begin(panel)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(count, 1)
    XCTAssertEqual(panel.history.first?.answer, "有效文字回答")
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("图解未生成") })
    try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let solutions = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(solutions.first?.diagrams, [])
    XCTAssertNotNil(solutions.first?.diagramFailure)
    await store.close()
  }

  func testExplicitNoDiagramOverridesVisualMethodWithoutRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let method = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "画图")
    var count = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "题目", selectedWord: nil, imageData: nil), answer: { prompt, _, _, _ in
      count += 1
      XCTAssertFalse(prompt.contains("```math-diagrams"))
      return "文字回答"
    }, mathStore: store, selectMethodAutomatically: { _, _, _ in .init(method: nil, visualMethods: [method], reason: "适用") })
    defer { panel.close() }
    try begin(panel, question: "这次不要画图，只要文字")
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(count, 1)
    XCTAssertFalse(views(panel.contentView!).compactMap { $0 as? NSTextView }.contains(where: hasImage))
    await store.close()
  }

  func testClosingDuringFirstAnswerIgnoresLateAnswerAndCannotSaveIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let method = try await store.saveMethod(title: "线段图", category: "数形结合", instructions: "画比较关系")
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "题目", selectedWord: nil, imageData: nil), answer: { _, _, _, partial in
      calls += 1
      try? await Task.sleep(nanoseconds: 400_000_000)
      partial("关闭后的迟到内容")
      return "关闭后的迟到内容"
    }, mathStore: store, selectMethodAutomatically: { _, _, _ in .init(method: nil, visualMethods: [method], reason: "适用") })
    try begin(panel)
    try await settle { calls == 1 }
    panel.close()
    try await Task.sleep(nanoseconds: 450_000_000)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertFalse(panel.isAnswering)
    let records = try await store.list()
    XCTAssertTrue(records.isEmpty)
    await store.close()
  }
}
