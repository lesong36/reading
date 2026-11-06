import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionPDFExportPanelTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  private func records() -> [MathQuestionRecord] {
    (0..<3).map {
      .init(
        id: "\($0)", title: "题目\($0)", createdAt: Date(), imageWidth: 100,
        imageHeight: 100, ocrText: "", ocrStatus: "pending")
    }
  }
  private func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Export UI did not settle")
  }

  func testDefaultExportsAllVisibleRecordsWithoutSolutions() async throws {
    let records = records()
    var received: [String] = []
    var includeSolutions = true
    var completed = false
    let editor = MathQuestionPDFExportPanel(
      store: .init(), records: records, selected: [records[1]],
      export: { rows, _, options in
        received = rows.map(\.id)
        includeSolutions = options.includeSolutions
        return 3
      }, destination: { _ in URL(fileURLWithPath: "/tmp/export-test.pdf") },
      onComplete: { _, pages, count in completed = pages == 3 && count == 3 })
    defer { editor.panel.close() }
    let views = descendants(editor.panel.contentView!)
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存 PDF…" })
    save.performClick(nil)
    try await settle { completed }
    XCTAssertEqual(received, records.map(\.id))
    XCTAssertFalse(includeSolutions)
  }

  func testSelectedScopeAndOptionalSolutionsArePassedExactly() async throws {
    let records = records()
    var received: [String] = []
    var includeSolutions = false
    let editor = MathQuestionPDFExportPanel(
      store: .init(), records: records, selected: [records[1]],
      export: { rows, _, options in
        received = rows.map(\.id)
        includeSolutions = options.includeSolutions
        return 2
      },
      destination: { _ in URL(fileURLWithPath: "/tmp/export-test.pdf") })
    defer { editor.panel.close() }
    let views = descendants(editor.panel.contentView!)
    try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first).selectItem(at: 1)
    let checkbox = try XCTUnwrap(
      views.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("附上 AI") })
    checkbox.state = .on
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存 PDF…" })
      .performClick(nil)
    try await settle { !received.isEmpty }
    XCTAssertEqual(received, [records[1].id])
    XCTAssertTrue(includeSolutions)
  }

  func testCancelledDestinationDoesNotExportAndAllowsRetry() async throws {
    var calls = 0
    let editor = MathQuestionPDFExportPanel(
      store: .init(), records: records(), selected: [],
      export: { _, _, _ in
        calls += 1
        return 1
      }, destination: { _ in nil })
    defer { editor.panel.close() }
    let views = descendants(editor.panel.contentView!)
    let scope = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
    XCTAssertEqual(scope.lastItem?.isEnabled, false)
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存 PDF…" })
    save.performClick(nil)
    try await settle {
      views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("已取消保存") }
    }
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(save.isEnabled)
  }
}
