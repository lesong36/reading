import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionReadingLayoutTests: XCTestCase {
  func testLongAnswerUsesOneContinuousScrollAtNormalWindow() async throws {
    try await verifyReadingLayout(size: NSSize(width: 1040, height: 800), name: "normal")
  }

  func testLongAnswerUsesOneContinuousScrollAtLargeWindow() async throws {
    try await verifyReadingLayout(size: NSSize(width: 1600, height: 1200), name: "large")
  }

  private func verifyReadingLayout(size: NSSize, name: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1500,
      pixelsHigh: 150, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let answer = (1...65).map {
      "步骤\($0)：每月物业费115×2＝230元。一年有12个月，230×12＝2760元。逐项检查数量和单位，保留完整解答过程。"
    }.joined(separator: "\n\n") + "\n末尾验算：2760÷12÷2＝115，核对完毕。"
    let record = try await store.save(.init(captureID: UUID().uuidString, imageData: image,
      solutions: [.init(question: "解题", answer: answer, model: "isolated-layout-fixture")]))
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.setContentSize(size)
    library.present(questionID: record.id)
    let root = try XCTUnwrap(library.contentView)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    var detail: NSTextView?
    for _ in 0..<200 {
      detail = all(root).compactMap { $0 as? NSTextView }.first { $0.string.contains("末尾验算") }
      if detail != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let text = try XCTUnwrap(detail)
    root.layoutSubtreeIfNeeded()
    root.layoutSubtreeIfNeeded()
    // A real window may be constrained to the current display on presentation.
    // Test the space it actually received, rather than an off-screen request.
    let presentedSize = root.bounds.size
    let scroll = try XCTUnwrap(all(root).compactMap { $0 as? NSScrollView }.first {
      $0.accessibilityLabel() == "题目完整详情"
    })
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertFalse(text.superview is NSClipView, "Answer must not be trapped in a nested scroll view")
    XCTAssertEqual(all(document).compactMap { $0 as? NSScrollView }.count, 0)
    XCTAssertGreaterThan(text.frame.height, 1000, "Long answer expands to its complete natural height")
    XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
    XCTAssertGreaterThan(scroll.contentSize.height, presentedSize.height * 0.50)
    XCTAssertGreaterThanOrEqual(scroll.frame.width, presentedSize.width - 300)
    XCTAssertGreaterThanOrEqual(text.frame.width, scroll.contentSize.width - 30)
    let container = try XCTUnwrap(text.textContainer)
    let manager = try XCTUnwrap(text.layoutManager)
    manager.ensureLayout(for: container)
    XCTAssertGreaterThanOrEqual(text.bounds.height + 1,
      manager.usedRect(for: container).height + 2 * text.textContainerInset.height)
    let preview = try XCTUnwrap(all(document).compactMap { $0 as? NSImageView }.first {
      $0.accessibilityLabel() == "题目原图预览"
    })
    XCTAssertLessThanOrEqual(preview.frame.height, 180)
    XCTAssertEqual(preview.frame.height, ceil(min(150, preview.bounds.width / 10)), accuracy: 1)
    XCTAssertTrue(all(document).compactMap { $0 as? NSButton }.contains { $0.title == "查看原图" })
    let heading = try XCTUnwrap(all(document).compactMap { $0 as? NSTextField }.first {
      $0.placeholderString == "题目标题（回车保存）"
    })
    XCTAssertLessThan(heading.frame.height, 40, "Header must not absorb tall window whitespace")
    let lastCharacter = NSRange(location: (text.string as NSString).length - 1, length: 1)
    let glyphRange = manager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
    let lastLine = manager.boundingRect(forGlyphRange: glyphRange, in: container)
    let lastLineInDocument = text.convert(lastLine.offsetBy(dx: text.textContainerInset.width,
      dy: text.textContainerInset.height), to: document)
    document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxY + 1, lastLineInDocument.maxY,
      "The final answer line must be reachable in the single outer scroll")
    document.scroll(.zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    if let path = ProcessInfo.processInfo.environment["MATH_READING_LAYOUT_ARTIFACTS"] {
      let destination = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try snapshot(root, to: destination.appendingPathComponent("\(name)-start.png"))
      let answerBottom = text.convert(NSRect(x: 0, y: 0, width: 1, height: text.bounds.height), to: document)
      document.scroll(NSPoint(x: 0, y: max(0, answerBottom.maxY - scroll.contentSize.height)))
      scroll.reflectScrolledClipView(scroll.contentView)
      try snapshot(root, to: destination.appendingPathComponent("\(name)-end.png"))
    }
    let originalTextWidth = text.bounds.width
    let originalTextHeight = text.bounds.height
    library.setContentSize(NSSize(width: presentedSize.width - 120, height: presentedSize.height))
    root.layoutSubtreeIfNeeded()
    root.layoutSubtreeIfNeeded()
    XCTAssertLessThan(text.bounds.width, originalTextWidth)
    XCTAssertGreaterThanOrEqual(text.bounds.height, originalTextHeight,
      "Resizing must rewrap the complete answer instead of clipping it")
    manager.ensureLayout(for: container)
    XCTAssertGreaterThanOrEqual(text.bounds.height + 1,
      manager.usedRect(for: container).height + 2 * text.textContainerInset.height)
    await store.close()
  }

  private func snapshot(_ view: NSView, to destination: URL) throws {
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
  }
}
