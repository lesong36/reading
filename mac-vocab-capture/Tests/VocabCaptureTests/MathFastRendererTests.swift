import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathFastRendererTests: XCTestCase {
  func testFastPayloadIsRequestScopedAndKeepsExistingAPIAndEnglish() throws {
    let configuration = AIConfiguration(baseURL: "https://example.invalid/v1", model: "fixture", apiKey: "")
    func payload(_ prefix: String) throws -> [String: Any] {
      let data = try ScreenshotQuestionClient.payload(question: prefix + "解题", context: .init(text: "题目", selectedWord: nil, imageData: nil), history: [], configuration: configuration, api: .chatCompletions)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let fast = try payload(MathStructuredSolution.fastRendererRequestPrefix)
    XCTAssertEqual(fast["diagram_scope"] as? String, "native_only")
    XCTAssertEqual(fast["solution_protocol"] as? String, "renderer_tools")
    XCTAssertTrue((fast["instructions"] as? String)?.contains("数学学习助教") == true)
    XCTAssertNil(try payload(MathStructuredSolution.rendererRequestPrefix)["diagram_scope"])
    XCTAssertNil(try payload("")["diagram_scope"])
  }

  func testExplicitDrawAndFollowupKeepFullCapability() {
    for request in ["请补图", "帮我画出线段图", "用表格整理", "draw a diagram", "请画韦恩图"] {
      XCTAssertTrue(ScreenshotQuestionPanel.explicitlyRequestsDiagram(request), request)
    }
    for request in ["不要使用方程，请解题并验算", "115平方米每月每平方米2元，求一年物业费", "不要画图，只要文字"] {
      XCTAssertFalse(ScreenshotQuestionPanel.explicitlyRequestsDiagram(request), request)
    }
    let prompt = MathStructuredSolution.prompt("解题", candidates: [], singleSubmission: true, rendererTools: true, nativeOnly: true)
    XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
    XCTAssertTrue(prompt.contains("其它题用一般解答工具完整解题及验算"))
    XCTAssertFalse(MathStructuredSolution.fastRendererDiagramContract.contains("general的quantity_plan："))
    XCTAssertTrue(MathStructuredSolution.fastRendererDiagramContract.contains("差能被9整除"))
    XCTAssertTrue(MathStructuredSolution.rendererDiagramContract.contains("general的quantity_plan："))
  }

  func testSupplementRequiresUserClickAndSwitchesOnlyThatRequestToFullTools() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    var prompts: [String] = []
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, source, _, _ in
        prompts.append(prompt)
        XCTAssertEqual(source.imageData, photo)
        return #"{"schemaVersion":1,"mode":"general","method_id":null,"visual_method_ids":[],"answer":"115×2×12=2760元，反算2760÷12÷2=115。","diagrams":[],"diagram_omission":{"status":"no_helpful_diagram","reason":"此题用两步连乘即可清楚说明，无须增加图形。"}}"#
      }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { _, _, _ in XCTFail("No extra selector request"); return .init(method: nil, reason: "") },
      singlePassAutomaticMethods: true, programArithmetic: true, singleSubmissionMath: true, rendererToolsMath: true)
    defer { panel.close() }
    panel.present()
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let views = all(try XCTUnwrap(panel.contentView))
    let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    let ask = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    let supplement = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "补图" })
    XCTAssertTrue(supplement.isHidden)
    field.stringValue = "请用小学知识解题并验算"; ask.performClick(nil)
    for _ in 0..<300 { if !panel.isAnswering && panel.history.count == 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(prompts.count, 1)
    XCTAssertTrue(prompts[0].hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
    XCTAssertFalse(supplement.isHidden)
    XCTAssertTrue(panel.history[0].answer.contains("图解说明：此题用两步连乘"))
    supplement.performClick(nil)
    for _ in 0..<300 { if !panel.isAnswering && panel.history.count == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(prompts.count, 2, "Only an explicit click sends the second request")
    XCTAssertTrue(prompts[1].hasPrefix(MathStructuredSolution.rendererRequestPrefix))
    XCTAssertFalse(prompts[1].hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
    XCTAssertTrue(prompts[1].contains("请用小学知识解题并验算"))
    XCTAssertTrue(supplement.isHidden)
    await store.close()
  }
}
