import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathQuestionInlineTagsTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  private func settle(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("UI did not settle")
  }

  func testAllTagsAndEmptyDimensionsStayVisibleAndEditable() throws {
    let rows = MathQuestionTagRows()
    let tags = (0..<9).map {
      MathQuestionTag(
        axis: "curriculum_knowledge", tagID: "k\($0)", catalogueVersion: "test@1", label: "知识点\($0)"
      )
    }
    rows.set(grade: 4, tags: tags, editable: true)
    let buttons = descendants(rows).compactMap { $0 as? NSButton }
    for tag in tags { XCTAssertTrue(buttons.contains { $0.title == tag.label && $0.isEnabled }) }
    for (_, title) in MathQuestionTagRows.dimensions {
      XCTAssertTrue(buttons.contains { $0.title == title })
    }
    XCTAssertFalse(buttons.contains { $0.title == "编辑标签…" })
    XCTAssertEqual(rows.gradePicker.indexOfSelectedItem, 4)
    var clickedAxis: String?
    rows.onEdit = { axis, _ in clickedAxis = axis }
    try XCTUnwrap(buttons.first { $0.title == "知识点8" }).performClick(nil)
    XCTAssertEqual(clickedAxis, "curriculum_knowledge")
    rows.set(grade: 4, tags: tags, editable: false)
    XCTAssertFalse(rows.gradePicker.isEnabled)
    XCTAssertTrue(descendants(rows).compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled })
  }

  func testChipsWrapWithinNarrowDimensionWidthWithoutDroppingTags() {
    let flow = MathTagFlowView(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    let buttons = (0..<12).map { NSButton(title: "课程知识点\($0)", target: nil, action: nil) }
    flow.setButtons(buttons)
    flow.layoutSubtreeIfNeeded()
    XCTAssertEqual(flow.subviews.count, 12)
    XCTAssertGreaterThan(flow.intrinsicContentSize.height, 24)
    for button in buttons {
      XCTAssertLessThanOrEqual(button.frame.maxX, 180)
      XCTAssertLessThanOrEqual(button.frame.maxY, flow.intrinsicContentSize.height)
    }
    flow.setFrameSize(NSSize(width: 500, height: 24))
    flow.needsLayout = true
    flow.layoutSubtreeIfNeeded()
    XCTAssertLessThan(flow.intrinsicContentSize.height, 12 * 29)
  }

  func testPopoverOnlyShowsClickedDimensionAndSavePreservesOtherTags() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "popover-test", imageData: image))
    let knowledge = MathQuestionTag(
      axis: "curriculum_knowledge", tagID: "old", catalogueVersion: "test@1", label: "保留的知识点",
      origin: "ai", status: "suggested")
    try await store.updateClassification(questionID: record.id, grade: 4, tags: [knowledge])
    var saved = false
    let editor = MathTagAxisPopover(store: store, questionID: record.id, axis: "question_form") {
      saved = true
    }
    let views = descendants(try XCTUnwrap(editor.popover.contentViewController?.view))
    XCTAssertFalse(views.contains { $0 is NSSegmentedControl })
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
    try await settle { save.isEnabled }
    let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
    let catalogue = try MathTagCatalogue.load()
    XCTAssertEqual(
      table.numberOfRows, catalogue.tags.filter { $0.assignment.axis == "question_form" }.count)
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    let check = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
    let selected = check.title
    check.performClick(nil)
    save.performClick(nil)
    try await settle { saved }
    let tags = try await store.tags(questionID: record.id)
    XCTAssertTrue(tags.contains(knowledge))
    XCTAssertTrue(
      tags.contains { $0.axis == "question_form" && $0.label == selected && $0.origin == "user" })
    let records = try await store.list()
    XCTAssertEqual(records.first?.grade, 4)
    await store.close()
  }

  func testCancelDiscardsDraftAndUnchangedAutomaticTagsKeepTheirOrigin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(
      .init(
        captureID: "cancel-test",
        imageData: XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))))
    let tag = try XCTUnwrap(MathTagCatalogue.load().tags.first).assignment
    let automatic = MathQuestionTag(
      axis: tag.axis, tagID: tag.tagID, catalogueVersion: tag.catalogueVersion, label: tag.label,
      origin: "ai", status: "suggested")
    try await store.updateClassification(questionID: record.id, grade: nil, tags: [automatic])
    let editor = MathTagAxisPopover(store: store, questionID: record.id, axis: tag.axis) {}
    let views = descendants(try XCTUnwrap(editor.popover.contentViewController?.view))
    let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
    try await settle { save.isEnabled }
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "清除此维度" }).performClick(
      nil)
    try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "取消" }).performClick(nil)
    let unchanged = try await store.tags(questionID: record.id)
    XCTAssertEqual(unchanged, [automatic])
    var saved = false
    let second = MathTagAxisPopover(store: store, questionID: record.id, axis: tag.axis) {
      saved = true
    }
    let secondSave = try XCTUnwrap(
      descendants(second.popover.contentViewController!.view).compactMap { $0 as? NSButton }.first {
        $0.title == "保存"
      })
    try await settle { secondSave.isEnabled }
    secondSave.performClick(nil)
    try await settle { saved }
    let retained = try await store.tags(questionID: record.id)
    XCTAssertEqual(retained, [automatic])
    await store.close()
  }
}
