import AppKit
import ImageIO
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionAppIntegrationTests: XCTestCase {
  private func image() throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 2048, height: 32,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 2048, height: 32))
    return try XCTUnwrap(context.makeImage())
  }

  func testDirectSavePersistsFullResolutionWithNoAnswerAndAllowsLibraryViewing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    let app = makeIsolatedAppDelegate(mathQuestionStore: store)
    defer {
      app.directQuestionPanel?.close()
      app.mathQuestionLibrary?.close()
      try? FileManager.default.removeItem(at: directory)
    }
    let original = try image()
    app.showScreenshot(text: "", image: original, destination: .question)
    let panel = try XCTUnwrap(app.directQuestionPanel)
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let save = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }
        .first { $0.title == "保存题目" })
    save.performClick(nil)
    var records: [MathQuestionRecord] = []
    for _ in 0..<150 {
      records = try await store.list()
      if !records.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(record.imageWidth, 2048)
    XCTAssertEqual(record.imageHeight, 32)
    let bytes = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(bytes, MathQuestionIndexer.originalPNG(original))
    let answers = try await store.solutions(questionID: record.id)
    XCTAssertTrue(answers.isEmpty)
    XCTAssertFalse(panel.isAnswering)
    app.showMathQuestionLibrary(questionID: record.id)
    let library = try XCTUnwrap(app.mathQuestionLibrary)
    for _ in 0..<150 {
      if library.selectedID == record.id { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(library.selectedID, record.id)
    XCTAssertTrue(library.isVisible)
    // Blank screenshots retain their original despite indexing failure.
    for _ in 0..<150 {
      records = try await store.list()
      if records.first?.ocrStatus == "failed" { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(records.first?.ocrStatus, "failed")
    await store.close()
  }

  func testAppSaveUsesIndependentMathIndexAndKeepsSolution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    let app = makeIsolatedAppDelegate(mathQuestionStore: store)
    defer { try? FileManager.default.removeItem(at: directory) }
    let answer = MathQuestionSolution(question: "解题", answer: "20 × 10 = 200", model: "test")
    let record = try await app.saveMathQuestion(
      MathQuestionSaveRequest(
        captureID: "fixture",
        imageData: try XCTUnwrap(MathQuestionIndexer.originalPNG(image())),
        ocrText: "Unreliable English-only transcription", solutions: [answer]))
    XCTAssertTrue(record.ocrText.isEmpty)
    let answers = try await store.solutions(questionID: record.id)
    XCTAssertEqual(answers, [answer])
    XCTAssertEqual(MathQuestionIndexer.languages, ["zh-Hans", "en-US"])
    for _ in 0..<150 {
      if try await store.list().first?.ocrStatus == "failed" { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await store.close()
  }

  func testOpeningSavedQuestionClearsPreviousFilterAndSelectsItsOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = try XCTUnwrap(MathQuestionIndexer.originalPNG(image()))
    let first = try await store.save(MathQuestionSaveRequest(captureID: "first", imageData: data))
    let second = try await store.save(
      MathQuestionSaveRequest(
        captureID: "second", imageData: data,
        solutions: [MathQuestionSolution(question: "解题", answer: "测试完整回答", model: "test")]))
    try await store.rename(questionID: first.id, title: "Only matching title")
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.present()
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let search = try XCTUnwrap(
      views(library.contentView!).compactMap { $0 as? NSSearchField }.first)
    search.stringValue = "matching"
    library.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: search))
    for _ in 0..<100 {
      if library.records.count == 1 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(library.records.map(\.id), [first.id])
    library.present(questionID: second.id)
    for _ in 0..<100 {
      if library.selectedID == second.id { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(search.stringValue, "")
    XCTAssertEqual(library.selectedID, second.id)
    for _ in 0..<100 {
      if views(library.contentView!).compactMap({ $0 as? NSTextView }).contains(where: {
        $0.string.contains("AI 回答（尚未核实）")
      }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(
      views(library.contentView!).compactMap { $0 as? NSTextView }.contains {
        $0.string.contains("AI 回答（尚未核实）")
      })
    library.contentView?.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(search.frame.width, 200)
    await store.close()
  }

  func testLibraryMenuHasAnExplicitLocalEntry() throws {
    let app = makeIsolatedAppDelegate()
    let item = try XCTUnwrap(app.makeMenu().items.first { $0.title == "数学题库…" })
    XCTAssertEqual(item.action, NSSelectorFromString("openMathQuestionLibrary"))
    XCTAssertTrue(item.target === app)
  }
}
