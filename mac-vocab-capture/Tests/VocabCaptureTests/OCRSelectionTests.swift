import XCTest

@testable import VocabCapture

final class OCRSelectionTests: XCTestCase {
  func testClickKeepsSingleLetterAndHyphenatedWords() {
    let model = OCRSelection(text: "I read a well-known book.")
    XCTAssertEqual(model.wordRange(at: 0), NSRange(location: 0, length: 1))
    XCTAssertEqual(model.selection(in: NSRange(location: 11, length: 4))?.word, "well-known")
    XCTAssertNil(model.wordRange(at: 1))
  }

  func testDragKeepsPhrasePunctuationAndWraps() {
    let model = OCRSelection(text: "We work,\nlearn and grow.")
    let selected = model.selection(in: NSRange(location: 4, length: 8))
    XCTAssertEqual(selected?.word, "work, learn")
    XCTAssertEqual(selected?.context, "We work, learn and grow.")
  }

  func testRepeatedWordUsesSelectedSentenceWithUTF16Offsets() {
    let text = "🙂 中文. The bank is closed. We sat by the bank."
    let range = (text as NSString).range(of: "bank", options: .backwards)
    let selected = OCRSelection(text: text).selection(in: range)
    XCTAssertEqual(selected?.word, "bank")
    XCTAssertEqual(selected?.context, "We sat by the bank.")
  }

  func testInvalidAndPunctuationOnlySelectionsAreIgnored() {
    let model = OCRSelection(text: "Word!")
    XCTAssertNil(model.selection(in: NSRange(location: NSNotFound, length: 1)))
    XCTAssertNil(model.selection(in: NSRange(location: 4, length: 1)))
    XCTAssertNil(model.selection(in: NSRange(location: 0, length: 100)))
    XCTAssertNil(model.selection(in: NSRange(location: 0, length: 0)))
  }
}
