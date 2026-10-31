import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class OCRImageOverlayViewTests: XCTestCase {
  func testAspectFitAndVisionBottomLeftCoordinateConversion() {
    let imageRect = OCROverlayLayout.imageRect(for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600))
    XCTAssertEqual(imageRect, CGRect(x: 0, y: 150, width: 600, height: 300))
    let token = OCROverlayLayout.rect(for: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2), imageRect: imageRect)
    XCTAssertEqual(token, CGRect(x: 60, y: 210, width: 120, height: 60))
  }

  func testScaledImageRectPreservesCenterAndDoublesTargetSize() {
    let base = OCROverlayLayout.imageRect(
      for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600))
    let zoomed = OCROverlayLayout.imageRect(
      for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600), scale: 2)
    XCTAssertEqual(base.midX, zoomed.midX)
    XCTAssertEqual(base.midY, zoomed.midY)
    XCTAssertEqual(zoomed.size, CGSize(width: base.width * 2, height: base.height * 2))
  }

  func testImageRectOffsetMovesTheOCRCoordinateSpaceTogether() {
    let centered = OCROverlayLayout.imageRect(
      for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600), scale: 2)
    let shifted = OCROverlayLayout.imageRect(
      for: CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 600, height: 600),
      scale: 2, offset: CGPoint(x: -40, y: 25))
    XCTAssertEqual(shifted.minX, centered.minX - 40)
    XCTAssertEqual(shifted.minY, centered.minY + 25)
  }

  func testImageOverlayAcceptsTokensAndUsesStableAspectFitFrame() {
    let image = NSImage(size: NSSize(width: 100, height: 50))
    let view = OCRImageOverlayView(image: image, tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    XCTAssertEqual(OCROverlayLayout.imageRect(for: image.size, in: view.bounds).size, CGSize(width: 300, height: 150))
    XCTAssertEqual(view.tokens.map(\.text), ["word"])
  }

  func testMultiLineTokensUseReadingOrderAndPreserveLowConfidenceMetadata() {
    let tokens = [
      OCROverlayToken(text: "second", boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.1), confidence: 0.2),
      OCROverlayToken(text: "first", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), confidence: 0.99),
    ]
    XCTAssertEqual(tokens.map(\.confidence), [0.2, 0.99])
    XCTAssertGreaterThan(tokens[0].boundingBox.minY, 0)
    XCTAssertGreaterThan(tokens[1].confidence, tokens[0].confidence)
  }

  func testDragSelectionReturnsReadingOrderAcrossLines() {
    let imageRect = CGRect(x: 0, y: 0, width: 400, height: 200)
    let tokens = [
      OCROverlayToken(text: "second", boundingBox: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.15), confidence: 1),
      OCROverlayToken(text: "first", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.15), confidence: 1),
    ]
    let indices = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: imageRect, selectionRect: CGRect(x: 0, y: 0, width: 400, height: 200), point: .zero)
    XCTAssertEqual(indices, [1, 0])
  }

  func testTinyTokenGetsMinimumClickTargetWithoutChangingVisualRect() {
    let visual = CGRect(x: 20, y: 30, width: 2, height: 3)
    let hit = OCROverlayLayout.hitRect(for: visual)
    XCTAssertEqual(visual, CGRect(x: 20, y: 30, width: 2, height: 3))
    XCTAssertGreaterThanOrEqual(hit.width, 12)
    XCTAssertGreaterThanOrEqual(hit.height, 12)
    XCTAssertTrue(hit.contains(CGPoint(x: 21, y: 31.5)))
  }

  func testLowConfidenceTokenRemainsRepresentedInOverlayModel() {
    let token = OCROverlayToken(text: "uncertain", boundingBox: .zero, confidence: 0.2)
    XCTAssertLessThan(token.confidence, OCROverlayLayout.lowConfidenceThreshold)
    XCTAssertEqual(token.text, "uncertain")
  }

  func testClickChoosesNearestTokenWhenMinimumHitTargetsOverlap() {
    let tokens = [
      OCROverlayToken(text: "left", boundingBox: CGRect(x: 0.20, y: 0.4, width: 0.02, height: 0.05), confidence: 1),
      OCROverlayToken(text: "right", boundingBox: CGRect(x: 0.24, y: 0.4, width: 0.02, height: 0.05), confidence: 1),
    ]
    let indices = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      selectionRect: CGRect(x: 23, y: 53, width: 0, height: 0), point: CGPoint(x: 23, y: 53))
    XCTAssertEqual(indices.count, 1)
  }

  func testHoverAndClickShareNearestTokenHitResolution() {
    let tokens = [
      OCROverlayToken(text: "left", boundingBox: CGRect(x: 0.20, y: 0.4, width: 0.02, height: 0.05), confidence: 1),
      OCROverlayToken(text: "right", boundingBox: CGRect(x: 0.24, y: 0.4, width: 0.02, height: 0.05), confidence: 1),
    ]
    let point = CGPoint(x: 23, y: 53)
    let click = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      selectionRect: .zero, point: point)
    let hover = OCROverlayLayout.selectedTokenIndices(
      tokens: tokens, imageRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      selectionRect: .zero, point: point)
    XCTAssertEqual(hover, click)
  }

  func testKeyboardNavigationConfirmsFocusedToken() {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [
        .init(text: "first", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), confidence: 1),
        .init(text: "second", boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1), confidence: 1),
      ])
    var selected: ([Int], String)?
    view.onSelectionWithIndices = { text, indices in selected = (indices, text) }
    let right = try! XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "→", charactersIgnoringModifiers: "→", isARepeat: false, keyCode: 124))
    view.keyDown(with: right)
    XCTAssertEqual(view.accessibilityValue() as? String, "first")
    let enter = try! XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.keyDown(with: enter)
    XCTAssertEqual(selected?.0, [0])
    XCTAssertEqual(selected?.1, "first")
  }

  func testVerticalKeyboardNavigationMovesToAdjacentLine() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [
        .init(text: "top", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1), confidence: 1),
        .init(text: "bottom", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.1), confidence: 1),
      ])
    var selected = ""
    view.onSelection = { selected = $0 }
    let down = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "↓", charactersIgnoringModifiers: "↓", isARepeat: false, keyCode: 125))
    view.keyDown(with: down)
    let enter = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.keyDown(with: enter)
    XCTAssertEqual(selected, "bottom")
  }

  func testHomeAndEndJumpAcrossLongOCRResults() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [
        .init(text: "first", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), confidence: 1),
        .init(text: "last", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), confidence: 1),
      ])
    var selected = ""
    view.onSelection = { selected = $0 }
    let end = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 119))
    view.keyDown(with: end)
    let enter = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    view.keyDown(with: enter)
    XCTAssertEqual(selected, "last")
  }

  func testBecomingFirstResponderFocusesFirstOCRToken() {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [
        .init(text: "second", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), confidence: 1),
        .init(text: "first", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1), confidence: 1),
      ])
    XCTAssertTrue(view.becomeFirstResponder())
    XCTAssertEqual(view.accessibilityValue() as? String, "first")
  }

  func testReplacingTokensClearsTransientSelectionState() {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "old", boundingBox: .zero, confidence: 1)])
    view.tokens = [.init(text: "new", boundingBox: .zero, confidence: 1)]
    XCTAssertEqual(view.tokens.map(\.text), ["new"])
    XCTAssertEqual(view.toolTip, "点击单词或拖选词组")
  }

  func testEscapeCancelsActiveDragBeforeSelectionCallback() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "word", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), confidence: 1)])
    var callbacks = 0
    view.onSelection = { _ in callbacks += 1 }
    let down = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    view.mouseDown(with: down)
    let escape = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    view.keyDown(with: escape)
    let up = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseUp, location: CGPoint(x: 80, y: 80), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    view.mouseUp(with: up)
    XCTAssertEqual(callbacks, 0)
  }

  func testPointerSelectionUpdatesAccessibilityValue() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let down = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    view.mouseDown(with: down)
    let up = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseUp, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    view.mouseUp(with: up)
    XCTAssertEqual(view.accessibilityValue() as? String, "word")
    XCTAssertEqual(view.toolTip, "已选择：word")
  }

  func testCommandCCopiesTheSelectedOCRText() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "copied", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let down = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseUp, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    let copy = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
      context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    view.keyDown(with: copy)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copied")
    XCTAssertEqual(view.toolTip, "已复制：copied")
  }

  func testCommandASelectsAllOCRTextWithoutStartingLookup() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [
        .init(text: "second", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), confidence: 1),
        .init(text: "first", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1), confidence: 1),
      ])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var selected = false
    view.onSelection = { _ in selected = true }
    let selectAll = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    view.keyDown(with: selectAll)
    XCTAssertFalse(selected)
    XCTAssertEqual(view.accessibilityValue() as? String, "first second")
    XCTAssertEqual(view.toolTip, "已全选：first second；按 ⌘C 复制")
  }

  func testContextMenuOffersQueryAndCopyForOCRTarget() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .rightMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let menu = try XCTUnwrap(view.menu(for: event))
    XCTAssertEqual(menu.items.map(\.title), ["查询“word”", "", "复制识别文字"])
    XCTAssertEqual(view.accessibilityValue() as? String, "word")
  }

  func testDoubleClickOnOCRTargetStillSelectsTheWord() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var selected = ""
    view.onSelection = { selected = $0 }
    let down = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseUp, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 2, clickCount: 2, pressure: 0))
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    XCTAssertEqual(selected, "word")
  }

  func testZoomedEmptyImageContextMenuOffersRestore() throws {
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: "word", boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let plus = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24))
    view.keyDown(with: plus)
    XCTAssertEqual(view.accessibilityValue() as? String, "当前缩放 125%")
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .rightMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let menu = try XCTUnwrap(view.menu(for: event))
    XCTAssertEqual(menu.items.map(\.title), ["恢复整图"])
  }

  func testContextMenuTruncatesVeryLongOCRLabel() throws {
    let longText = String(repeating: "longword ", count: 8).trimmingCharacters(in: .whitespaces)
    let view = OCRImageOverlayView(
      image: NSImage(size: NSSize(width: 100, height: 100)),
      tokens: [.init(text: longText, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)])
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .rightMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let title = try XCTUnwrap(view.menu(for: event)?.items.first?.title)
    XCTAssertLessThanOrEqual(title.count, 36)
    XCTAssertTrue(title.contains("…"))
  }
}
