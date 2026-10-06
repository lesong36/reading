import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class FloatingSelectionInteractionTests: XCTestCase {
  private var delegate: AppDelegate!
  private let externalProcess: pid_t = -1

  override func setUp() {
    _ = NSApplication.shared
    delegate = makeIsolatedAppDelegate()
  }

  override func tearDown() {
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    delegate.selectionPreview?.dismiss()
    delegate.floatingSelectionPanel?.orderOut(nil)
    delegate = nil
  }

  private func show(_ selection: SelectedText) throws -> NSPanel {
    delegate.showFloatingSelectionButtonIfNeeded(
      selection: selection, revision: delegate.floatingState.revision,
      frontmostProcessIdentifier: externalProcess)
    return try XCTUnwrap(delegate.floatingSelectionPanel)
  }

  private func send(_ type: CGEventType, at location: CGPoint) {
    delegate.handleMouseEvent(
      type, location: location, frontmostProcessIdentifier: externalProcess)
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  func testFloatingButtonGlobalDownAndUpPreserveSelectionForItsActualAction() throws {
    let selection = SelectedText(word: "curious", context: "A curious reader explores the world.")
    let panel = try show(selection)
    let revision = delegate.floatingState.revision
    let button = try XCTUnwrap(
      views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first)
    let point = CGPoint(x: panel.frame.midX, y: panel.frame.midY)

    send(.leftMouseDown, at: point)
    send(.leftMouseUp, at: point)

    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(delegate.floatingSelectionPanel === panel)
    XCTAssertEqual(delegate.floatingState.revision, revision)
    XCTAssertEqual(delegate.floatingState.selection?.context, selection.context)
    button.performClick(nil)

    let preview = try XCTUnwrap(delegate.selectionPreview)
    XCTAssertTrue(preview.isVisible)
    XCTAssertFalse(panel.isVisible)
    XCTAssertNil(delegate.floatingState.selection)
    XCTAssertNotEqual(delegate.floatingState.revision, revision)
    XCTAssertTrue(
      views(try XCTUnwrap(preview.contentView)).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue == selection.word
      })
    // Cancel before the asynchronous dictionary operation; no provider or user store is touched.
    preview.dismiss()
  }

  func testExternalNewDragInvalidatesPanelAndRejectsLateOldSelection() throws {
    let first = SelectedText(word: "bank", context: "A river bank borders the water.")
    let panel = try show(first)
    let oldRevision = delegate.floatingState.revision
    let outside = CGPoint(x: panel.frame.minX - 10, y: panel.frame.minY - 10)

    send(.leftMouseDown, at: outside)

    XCTAssertFalse(panel.isVisible)
    XCTAssertNil(delegate.floatingSelectionPanel)
    XCTAssertNil(delegate.floatingState.selection)
    XCTAssertNotEqual(delegate.floatingState.revision, oldRevision)
    delegate.showFloatingSelectionButtonIfNeeded(
      selection: first, revision: oldRevision, frontmostProcessIdentifier: externalProcess)
    XCTAssertNil(delegate.floatingSelectionPanel)

    let second = SelectedText(word: "bank", context: "The city bank accepts deposits.")
    _ = try show(second)
    XCTAssertEqual(delegate.floatingState.selection?.context, second.context)
  }

  func testPanelMouseUpDoesNotCompleteAnEarlierExternalDrag() throws {
    send(.leftMouseDown, at: CGPoint(x: -100, y: -100))
    let panel = try show(SelectedText(word: "curious", context: "A curious reader explores."))
    let revision = delegate.floatingState.revision
    let point = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
    send(.rightMouseDown, at: point)
    send(.leftMouseUp, at: point)
    XCTAssertTrue(delegate.floatingSelectionPanel === panel)
    XCTAssertEqual(delegate.floatingState.revision, revision)
    XCTAssertEqual(delegate.floatingState.selection?.word, "curious")
    XCTAssertNil(delegate.floatingReadTask)
  }
}
