import XCTest
@testable import VocabCapture

final class SelectionCaptureStateTests: XCTestCase {
  func testNewDragDiscardsOldButtonAndLateOldContext() {
    var state = SelectionCaptureState()
    let first = state.revision
    XCTAssertTrue(state.accept(SelectedText(word: "bank", context: "The river bank."), revision: first))
    let second = state.invalidate()
    XCTAssertNil(state.selection)
    XCTAssertFalse(state.accept(SelectedText(word: "bank", context: "The old bank."), revision: first))
    XCTAssertTrue(state.accept(SelectedText(word: "bank", context: "The new city bank."), revision: second))
    XCTAssertEqual(state.consume()?.context, "The new city bank.")
  }

  func testConsumedSelectionCannotBeRecreatedByDelayedRead() {
    var state = SelectionCaptureState()
    let revision = state.revision
    let selection = SelectedText(word: "curious", context: "A curious reader.")
    XCTAssertTrue(state.accept(selection, revision: revision))
    XCTAssertEqual(state.consume()?.word, "curious")
    XCTAssertFalse(state.accept(selection, revision: revision))
    XCTAssertNil(state.consume())
  }
}
