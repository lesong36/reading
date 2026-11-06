import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionSelectionFailureUITests: XCTestCase {
  func testReopenedLibraryShowsMethodRefusalAndPendingAnswerIndependently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "blocked", imageData: MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar), solutions: [
      .init(question: "原提示词", answer: "正常回答保留", model: "fixture", selectionFailure: "方法前提复核未通过，本次未自动套用。本题分组前提不成立")
    ]))
    await store.close()
    let reopened = MathQuestionStore(directory: directory)
    let library = MathQuestionLibrary(store: reopened, reindex: { _ in })
    defer { library.close() }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    library.present(questionID: record.id)
    var detail = ""
    for _ in 0..<200 {
      detail = views(try XCTUnwrap(library.contentView)).compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n")
      if detail.contains("本题分组前提不成立") { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for marker in ["自动选法记录（未套用方法）", "方法前提复核未通过", "本次未自动套用", "本题分组前提不成立", "未审核（可选）", "正常回答保留"] {
      XCTAssertTrue(detail.contains(marker), marker)
    }
    XCTAssertFalse(detail.contains("参考方法建议（未确认采用）："))
    XCTAssertFalse(detail.contains("用户已确认"))
    await reopened.close()
  }
}
