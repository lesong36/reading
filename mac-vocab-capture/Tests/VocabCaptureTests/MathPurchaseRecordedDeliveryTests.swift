import AppKit
import PDFKit
import XCTest
@testable import VocabCapture

/// Replay a recorded real-model response. This proves delivery, not a new
/// provider call or a fresh latency measurement. The question image is generated.
@MainActor
final class MathPurchaseRecordedDeliveryTests: XCTestCase {
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Recorded response delivery did not settle")
  }
  func testActualReturnedPurchasePayloadDisplaysWithoutPrimaryAndSurvivesSaveReopenPDF() async throws {
    let response = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "RealPurchaseOffersResponse", withExtension: "txt", subdirectory: "Fixtures")), encoding: .utf8)
    let photo = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "GeneratedPurchaseOffersQuestion", withExtension: "png", subdirectory: "Fixtures")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { prompt, source, _, _ in
        calls += 1
        XCTAssertEqual(source.imageData, photo)
        XCTAssertTrue(prompt.contains("purchase_comparison"))
        XCTAssertTrue(prompt.contains("不强行命名解法"))
        return response
      }, originalImageData: photo, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in .init(method: nil, reason: "没有直接适用的主技能，不强行归类。") })
    defer { panel.close() }
    panel.present()
    let all = views(try XCTUnwrap(panel.contentView))
    let input = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    input.stringValue = "不要使用方程，使用小学知识解题并验算。"
    all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }?.state = .on
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    try await wait { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    var attachmentCount = 0
    for text in all.compactMap({ $0 as? NSTextView }) {
      text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in
        if value is NSTextAttachment { attachmentCount += 1 }
      }
      XCTAssertFalse(text.string.contains("图解未生成"))
    }
    XCTAssertEqual(attachmentCount, 1)
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    try await wait { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    await store.close()
    let reopened = MathQuestionStore(directory: root)
    let solutions = try await reopened.solutions(questionID: id)
    let solution = try XCTUnwrap(solutions.first)
    XCTAssertNil(solution.method)
    XCTAssertNil(solution.diagramFailure)
    XCTAssertEqual(solution.verificationStatus, "unverified")
    XCTAssertEqual(solution.diagrams.first?.fact("offer_1_payment")?.value, 2505)
    XCTAssertEqual(solution.diagrams.first?.fact("offer_2_payment")?.value, 2616)
    let original = try await reopened.originalImage(questionID: id)
    XCTAssertEqual(original, photo)
    let records = try await reopened.list()
    let pdf = root.appendingPathComponent("recorded-purchase.pdf")
    let pages = try await MathQuestionPDFExporter.export(records: records, store: reopened,
      to: pdf, options: .init(includeSolutions: true))
    XCTAssertGreaterThan(pages, 1)
    let document = try XCTUnwrap(PDFDocument(url: pdf))
    let text = try XCTUnwrap(document.string).components(separatedBy: .whitespacesAndNewlines).joined()
    // These labels occur in the vector-rendered diagram, not only the answer.
    XCTAssertTrue(text.contains("A书店实际支付"))
    XCTAssertTrue(text.contains("B书店实际支付"))
    XCTAssertTrue(text.contains("两方案支付差额"))
    XCTAssertFalse(text.contains("用户已确认"))
    if let directory = ProcessInfo.processInfo.environment["MATH_RECORDED_PURCHASE_ARTIFACTS"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: pdf, to: destination.appendingPathComponent("recorded-purchase.pdf"))
      let page = try XCTUnwrap(document.page(at: document.pageCount - 1))
      let size = page.bounds(for: .mediaBox)
      let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      bitmap.scaleBy(x: 2, y: 2)
      bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(size)
      page.draw(with: .mediaBox, to: bitmap)
      let image = try XCTUnwrap(bitmap.makeImage())
      try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        .write(to: destination.appendingPathComponent("pdf-diagram-page.png"))
    }
    await reopened.close()
  }
}
