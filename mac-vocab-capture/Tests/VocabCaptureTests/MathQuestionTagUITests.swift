import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionTagUITests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  private func image() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    return try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
  }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("UI state did not settle")
  }

  func testPackagedCatalogueMatchesDraftAndSeparatesProductExtensions() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let draft = try Data(
      contentsOf: root.appendingPathComponent("docs/taxonomies/primary-math-v0.1.json"))
    let resource = try Data(
      contentsOf: root.appendingPathComponent("Sources/VocabCapture/Resources/PrimaryMathTags.json")
    )
    XCTAssertEqual(draft, resource)
    let catalogue = try MathTagCatalogue.load()
    XCTAssertEqual(catalogue.tags.count, 111)
    XCTAssertEqual(
      Set(catalogue.tags.map { $0.assignment.axis }),
      ["question_form", "curriculum_knowledge", "problem_family"])
    XCTAssertEqual(Set(catalogue.tags.map { $0.assignment.key }).count, catalogue.tags.count)
    let extensions = catalogue.tags.filter { $0.group == "扩展题型" }
    XCTAssertEqual(Set(extensions.map { $0.assignment.label }), ["数字组数", "乘积极值"])
    XCTAssertTrue(
      extensions.allSatisfy { $0.assignment.catalogueVersion == "product-math-extensions@0.1.0" })
  }

  func testEditingRetainsSelectionsAcrossAxesAndSearchAndPreservesOlderTags() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = try await store.save(.init(captureID: "tag-ui", imageData: image()))
    let old = MathQuestionTag(
      axis: "problem_family", tagID: "legacy", catalogueVersion: "old@1",
      label: "旧题型", origin: "teacher", status: "suggested")
    try await store.updateClassification(questionID: record.id, grade: nil, tags: [old])
    var applied = false
    let editor = MathTagEditor(store: store, record: record) { _, _ in applied = true }
    defer { editor.panel.close() }
    let views = descendants(editor.panel.contentView!)
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存标签" })
    try await settle { save.isEnabled }
    let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    let checkbox = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
    let selectedForm = checkbox.title
    checkbox.performClick(nil)
    let axes = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
    axes.selectedSegment = 2
    axes.sendAction(axes.action, to: axes.target)
    let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
    search.stringValue = "乘积极值"
    search.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: search))
    XCTAssertEqual(table.numberOfRows, 1)
    let typeCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    try XCTUnwrap(descendants(typeCell).compactMap { $0 as? NSButton }.first).performClick(nil)
    let grade = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
    grade.selectItem(at: 4)
    let custom = try XCTUnwrap(
      views.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString?.hasPrefix("新增自定义") == true
      })
    custom.stringValue = "周末复习"
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "添加" }).performClick(nil)
    save.performClick(nil)
    try await settle { applied }
    let tags = try await store.tags(questionID: record.id)
    XCTAssertEqual(tags.count, 4)
    XCTAssertTrue(tags.contains(old))
    XCTAssertTrue(tags.contains { $0.label == selectedForm && $0.axis == "question_form" })
    XCTAssertTrue(tags.contains { $0.label == "乘积极值" })
    XCTAssertTrue(tags.contains { $0.label == "周末复习" && $0.axis == "custom" })
    let records = try await store.list(grade: 4)
    XCTAssertEqual(records.map(\.id), [record.id])
    await store.close()
  }

  func testFilterSheetDoesNotModifyQuestionAndDirectOpenClearsGradeFilter() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = try await store.save(.init(captureID: "filter-ui", imageData: image()))
    var appliedGrade: Int?
    let editor = MathTagEditor(store: store) { grade, _ in appliedGrade = grade }
    let views = descendants(editor.panel.contentView!)
    let apply = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "应用筛选" })
    try await settle { apply.isEnabled }
    try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first).selectItem(at: 4)
    apply.performClick(nil)
    XCTAssertEqual(appliedGrade, 4)
    let unchanged = try await store.list()
    XCTAssertNil(unchanged.first?.grade)
    let tags = try await store.tags(questionID: record.id)
    XCTAssertTrue(tags.isEmpty)
    let library = MathQuestionLibrary(store: store, reindex: { _ in })
    defer { library.close() }
    library.present(questionID: record.id)
    let libraryViews = descendants(library.contentView!)
    let grade = try XCTUnwrap(libraryViews.compactMap { $0 as? NSPopUpButton }.first)
    grade.selectItem(at: 4)
    grade.sendAction(grade.action, to: grade.target)
    let edit = try XCTUnwrap(
      libraryViews.compactMap { $0 as? NSPopUpButton }.first {
        $0.identifier?.rawValue == "MathQuestion.recordGrade"
      })
    try await settle { !edit.isEnabled }
    library.present(questionID: record.id)
    try await settle { edit.isEnabled }
    XCTAssertEqual(grade.indexOfSelectedItem, 0)
    await store.close()
  }

  func testLegacyIdentifiersRemainIndependentInSelector() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = MathQuestionStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = MathQuestionTag(
      axis: "custom", tagID: "a\u{1f}b", catalogueVersion: "c", label: "甲")
    let second = MathQuestionTag(
      axis: "custom", tagID: "a", catalogueVersion: "b\u{1f}c", label: "乙")
    var applied: [MathQuestionTag] = []
    let editor = MathTagEditor(store: store, tags: [first, second]) { _, tags in applied = tags }
    defer { editor.panel.close() }
    let views = descendants(editor.panel.contentView!)
    let apply = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "应用筛选" })
    let clear = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "清除条件" })
    XCTAssertFalse(clear.isEnabled)
    try await settle { apply.isEnabled }
    XCTAssertTrue(clear.isEnabled)
    let axes = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
    axes.selectedSegment = 3
    axes.sendAction(axes.action, to: axes.target)
    let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
    XCTAssertEqual(table.numberOfRows, 2)
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first).performClick(nil)
    apply.performClick(nil)
    XCTAssertEqual(applied, [second])
    await store.close()
  }
}
