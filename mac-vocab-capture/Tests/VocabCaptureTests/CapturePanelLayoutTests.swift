import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class CapturePanelLayoutTests: XCTestCase {
  func testOriginalTextUsesAdditionalWindowHeight() throws {
    _ = NSApplication.shared
    let panel = OCRLookupPanel(
      text: String(repeating: "A curious reader explores the world. ", count: 40),
      lookup: { _, _ in throw CancellationError() }, save: { _, _ in "" })
    defer { panel.close() }
    let root = try XCTUnwrap(panel.contentView)
    panel.setContentSize(NSSize(width: 540, height: 620))
    root.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(views(root).compactMap { $0 as? NSScrollView }.first)
    let initialHeight = scroll.frame.height
    panel.setContentSize(NSSize(width: 540, height: 820))
    root.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(scroll.frame.height, initialHeight + 150)
    for button in views(root).compactMap({ $0 as? NSButton }) where !button.isHidden {
      let frame = button.convert(button.bounds, to: root)
      XCTAssertGreaterThanOrEqual(frame.minX, 16)
      XCTAssertLessThanOrEqual(frame.maxX, root.bounds.width - 16)
    }
  }

  func testQuestionControlsFitAtMinimumWidthAndLargestReadingZoom() throws {
    _ = NSApplication.shared
    let suite = "CapturePanelLayoutTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ScreenshotQuestionPreferences(
      defaults: defaults, readProfileAPIKey: { _ in "" }, saveProfileAPIKey: { _, _ in })
    let panel = ScreenshotQuestionPanel(
      context: ScreenshotQuestionContext(
        text: String(repeating: "Streaming improves responsiveness. ", count: 20),
        selectedWord: nil, imageData: Data([1])),
      answer: { _, _, _, _ in "" }, onModelSettings: {}, modelPreferences: preferences,
      interfaceDefaults: defaults, webAnswer: { _, _, _, _, _, _, _ in "" },
      onSearchSettings: {})
    defer { panel.close() }
    for _ in 0..<5 { panel.zoomIn(nil) }
    panel.setFrame(NSRect(origin: .zero, size: panel.minSize), display: false)
    let root = try XCTUnwrap(panel.contentView)
    root.layoutSubtreeIfNeeded()
    for button in views(root).compactMap({ $0 as? NSButton })
    where !button.isHiddenOrHasHiddenAncestor {
      let frame = button.convert(button.bounds, to: root)
      XCTAssertGreaterThanOrEqual(frame.minX, 16)
      XCTAssertLessThanOrEqual(frame.maxX, root.bounds.width - 16)
      XCTAssertGreaterThanOrEqual(frame.minY, 16)
    }
    let input = try XCTUnwrap(views(root).compactMap { $0 as? NSTextField }.first {
      $0.accessibilityLabel() == "提问内容"
    })
    XCTAssertGreaterThan(input.frame.width, 400)
    let transcript = try XCTUnwrap(views(root).compactMap { $0 as? NSTextView }.first)
    XCTAssertEqual(
      transcript.textContainer?.containerSize.width ?? 0,
      transcript.frame.width - 2 * transcript.textContainerInset.width, accuracy: 1)
  }

  private func views(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(views)
  }
}
