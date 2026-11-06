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

  func testFormalScreenshotEntrySubmitsOnceAndRendersUnverifiedMath() async throws {
    try await verifyMathEntry(fromOCR: false)
  }

  func testWordWindowQuestionEntrySubmitsOnceAndRendersUnverifiedMath() async throws {
    try await verifyMathEntry(fromOCR: true)
  }

  func testSonnetFormalAndWordEntriesUseSameSingleSubmissionProtocol() async throws {
    try await verifyMathEntry(fromOCR: false, sonnet: true)
    try await verifyMathEntry(fromOCR: true, sonnet: true)
  }

  private func verifyMathEntry(fromOCR: Bool, sonnet: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: root)
    var prompts: [String] = []
    let suite = "MathQuestionAppIntegration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    if sonnet {
      let preferences = ScreenshotQuestionPreferences(defaults: defaults,
        readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
      let id = try preferences.saveProfile(name: "Sonnet fixture",
        configuration: .init(baseURL: "https://example.invalid", model: "claude-sonnet-5-5", apiKey: ""),
        api: .anthropicMessages)
      preferences.selectProfile(id)
    }
    let app = makeIsolatedAppDelegate(defaults: defaults, mathQuestionStore: store,
      questionWebAnswerOverride: { prompt, context, history, search, _, _, _ in
        prompts.append(prompt)
        XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.fastRendererRequestPrefix))
        XCTAssertNotNil(context.imageData)
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(search)
        return #"{"schemaVersion":1,"mode":"native_recipe","method_id":null,"visual_method_ids":[],"answer":"按人数变化先减再加。","diagrams":[{"id":"visitors","title":"人数变化","kind":"state_changes","initial":{"value":100,"unit":"人","evidence":"原来有100人"},"changes":[{"direction":"decrease","amount":{"value":30,"unit":"人","evidence":"离开30人"}},{"direction":"increase","amount":{"value":20,"unit":"人","evidence":"又到来20人"}}]}]}"#
      })
    defer { app.directQuestionPanel?.close(); app.ocrPanel?.close(); try? FileManager.default.removeItem(at: root) }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let original = try image()
    let previousWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    app.showScreenshot(text: "原来有100人，离开30人，又到来20人。", image: original, destination: fromOCR ? .word : .question)
    let panel: ScreenshotQuestionPanel
    if fromOCR {
      let ocr = try XCTUnwrap(app.ocrPanel)
      try XCTUnwrap(views(try XCTUnwrap(ocr.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "问一问…" }).performClick(nil)
      panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? ScreenshotQuestionPanel }.first { !previousWindows.contains(ObjectIdentifier($0)) })
    } else { panel = try XCTUnwrap(app.directQuestionPanel) }
    defer { panel.close() }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "请用小学知识解题，不用方程。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<500 {
      if !panel.isAnswering { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(prompts.count, 1)
    XCTAssertEqual(panel.history.count, 1)
    XCTAssertTrue(panel.history.first?.answer.contains("90") == true)
    let transcript = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    var attachments = 0
    transcript.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: transcript.textStorage?.length ?? 0)) { value, _, _ in
      if value is NSTextAttachment { attachments += 1 }
    }
    XCTAssertGreaterThan(attachments, 0)
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
    for _ in 0..<300 {
      if panel.savedQuestionID != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let id = try XCTUnwrap(panel.savedQuestionID)
    let solutions = try await store.solutions(questionID: id)
    let solution = try XCTUnwrap(solutions.first)
    XCTAssertEqual(solution.verificationStatus, "unverified")
    XCTAssertEqual(solution.diagrams.first?.fact("final")?.value, 90)
    let bytes = try await store.originalImage(questionID: id)
    XCTAssertEqual(bytes, MathQuestionIndexer.originalPNG(original))
    await store.close()
  }

  func testFormalScreenshotEntryKeepsElementaryEnglishOutsideMathRouting() async throws {
    var prompts: [String] = []
    let app = makeIsolatedAppDelegate(questionWebAnswerOverride: { prompt, _, _, _, _, _, _ in
      prompts.append(prompt)
      return "This sentence describes a school."
    })
    defer { app.directQuestionPanel?.close() }
    app.showScreenshot(text: "This is my school.", image: try image(), destination: .question)
    let panel = try XCTUnwrap(app.directQuestionPanel)
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true }).stringValue = "请解释这段小学英语。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<300 {
      if !panel.isAnswering { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(prompts, ["请解释这段小学英语。"])
    XCTAssertEqual(panel.history.first?.answer, "This sentence describes a school.")
  }

  func testReopeningAppWithNoWindowPresentsLibraryAndReusesIt() {
    let app = makeIsolatedAppDelegate()
    XCTAssertTrue(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    let library = app.mathQuestionLibrary
    XCTAssertNotNil(library)
    XCTAssertTrue(library?.isVisible == true)
    XCTAssertTrue(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    XCTAssertTrue(app.mathQuestionLibrary === library)
    library?.close()
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
    // Verify the terminal indexing contract, not Vision cold-start latency.
    // A full UI suite can delay the background recognizer beyond 1.5 seconds.
    let clock = ContinuousClock()
    let indexingDeadline = clock.now.advanced(by: .seconds(10))
    repeat {
      records = try await store.list()
      if records.first?.ocrStatus == "failed" { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    } while clock.now < indexingDeadline
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

  func testRestoreRejectsOldSaveCallbacksAndAcceptsNewCapture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backupStore = MathQuestionStore(directory: directory.appendingPathComponent("source"))
    let current = MathQuestionStore(directory: directory.appendingPathComponent("current"))
    let photo = try XCTUnwrap(MathQuestionIndexer.originalPNG(image()))
    let restored = try await backupStore.save(.init(captureID: "backup-question", imageData: photo))
    let backup = directory.appendingPathComponent("backup")
    try await backupStore.backup(to: backup)
    await backupStore.close()
    let app = makeIsolatedAppDelegate(mathQuestionStore: current)
    let oldSave = app.saveMathQuestion
    _ = try await app.restoreMathLibrary(from: backup)
    do {
      _ = try await oldSave(.init(captureID: "closed-window-late-save", imageData: photo))
      XCTFail("A pre-restore callback must not mutate the restored library")
    } catch { XCTAssertTrue(error.localizedDescription.contains("重新保存")) }
    let afterOldSave = try await current.list()
    XCTAssertEqual(afterOldSave.map(\.id), [restored.id])
    let fresh = try await app.saveMathQuestion(.init(captureID: "new-capture", imageData: photo))
    XCTAssertNotEqual(fresh.id, restored.id)
    let afterFreshSave = try await current.list()
    XCTAssertEqual(afterFreshSave.count, 2)
    await current.close()
  }
}
