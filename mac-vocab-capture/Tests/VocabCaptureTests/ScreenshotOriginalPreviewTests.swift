import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class ScreenshotOriginalPreviewTests: XCTestCase {
  private func photo(width: Int, color: CGColor) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 100, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
    return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
  }
  private func button(_ panel: ScreenshotQuestionPanel) throws -> NSButton {
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    return try XCTUnwrap(views(XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }
      .first { $0.title == "查看原截图" })
  }
  func testPreviewUsesFullOriginalWithoutSubmittingOrSavingAndClosesOnNewCapture() throws {
    _ = NSApplication.shared
    let original = try photo(width: 1200, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let model = try photo(width: 20, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    var submitted = 0, saved = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: model),
      answer: { _,_,_,_ in submitted += 1; return "answer" }, originalImageData: original,
      saveQuestion: { _ in saved += 1; throw CancellationError() })
    defer { panel.close() }
    let control = try button(panel)
    XCTAssertFalse(control.isHidden)
    control.performClick(nil)
    let preview = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "原截图 · 1200 × 100" })
    let view = try XCTUnwrap(preview.contentView as? NSImageView)
    let image = try XCTUnwrap(view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(image.width, 1200)
    XCTAssertEqual(view.imageScaling, .scaleProportionallyDown)
    XCTAssertEqual(submitted, 0); XCTAssertEqual(saved, 0)
    panel.updateContext(.init(text: "next", selectedWord: nil, imageData: nil))
    XCTAssertFalse(preview.isVisible)
    XCTAssertTrue(control.isHidden, "A reduced model image must not be relabelled as the original")
  }
  func testMissingOriginalHasNoPreviewAndClosingParentClosesPreview() throws {
    _ = NSApplication.shared
    let original = try photo(width: 900, color: CGColor(gray: 1, alpha: 1))
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: original), answer: { _,_,_,_ in "" })
    XCTAssertTrue(try button(panel).isHidden)
    panel.updateContext(.init(text: "new", selectedWord: nil, imageData: original), originalImageData: original)
    try button(panel).performClick(nil)
    let preview = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "原截图 · 900 × 100" })
    panel.close()
    XCTAssertFalse(preview.isVisible)
  }
}
