import AppKit
import ImageIO
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotOCRPipelineTests: XCTestCase {
  private let publicText = "Streaming is crucial for enhancing responsiveness."
  private var appDelegate: AppDelegate?

  override func setUp() {
    _ = NSApplication.shared
  }

  override func tearDown() {
    appDelegate?.ocrPanel?.close()
    appDelegate?.directQuestionPanel?.close()
    appDelegate = nil
  }

  func testGeneratedPNGFixtureContainsReadableEnglish() async throws {
    let data = try publicPNG()
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let recognized = try await OCRClient.recognize(image)
    XCTAssertEqual(recognized, publicText)
  }

  func testCaptureDecodedImageRetainsEnglishAfterTemporaryFileRemoval() async throws {
    let png = try publicPNG()
    var temporaryImageURL: URL?
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { url, finish in
      temporaryImageURL = url
      do {
        try png.write(to: url)
        finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "")))
      } catch {
        finish(.failure(error))
      }
    })
    var capturedImage: CGImage?
    capture.capture { if case .success(let image) = $0 { capturedImage = image } }
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryImageURL).path))
    let recognized = try await OCRClient.recognize(try XCTUnwrap(capturedImage))
    XCTAssertEqual(recognized, publicText)
  }

  func testScreenshotWordActionShowsRecognizedOriginalAfterTemporaryImageIsRemoved() async throws {
    let delegate = try makeCaptureDelegate()
    XCTAssertTrue(NSApp.sendAction(
      NSSelectorFromString("captureScreenTextAction"), to: delegate, from: nil))
    try await wait { delegate.ocrPanel != nil }
    let panel = try XCTUnwrap(delegate.ocrPanel)
    XCTAssertTrue(panel.isVisible)
    let original = try XCTUnwrap(
      views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextView }.first)
    XCTAssertEqual(original.string, publicText)
  }

  func testScreenshotQuestionActionShowsRecognizedContextWithoutSubmittingAnAnswer() async throws {
    let delegate = try makeCaptureDelegate()
    XCTAssertTrue(NSApp.sendAction(
      NSSelectorFromString("captureScreenQuestionAction"), to: delegate, from: nil))
    try await wait { delegate.directQuestionPanel != nil }
    let panel = try XCTUnwrap(delegate.directQuestionPanel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(
      views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue == publicText
      })
    XCTAssertFalse(panel.isAnswering)
    XCTAssertTrue(panel.history.isEmpty)
  }

  func testScreenshotQuestionActionRetainsReadableOriginalImage() async throws {
    let delegate = try makeCaptureDelegate()
    XCTAssertTrue(NSApp.sendAction(
      NSSelectorFromString("captureScreenQuestionAction"), to: delegate, from: nil))
    try await wait { delegate.directQuestionPanel != nil }
    let panel = try XCTUnwrap(delegate.directQuestionPanel)
    // Inspect the retained context without submitting to the production answer service.
    let context = try XCTUnwrap(
      Mirror(reflecting: panel).children.first { $0.label == "context" }?.value
        as? ScreenshotQuestionContext)
    let data = try XCTUnwrap(context.imageData)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 1_400)
    XCTAssertEqual(image.height, 180)
    let recognized = try await OCRClient.recognize(image)
    XCTAssertEqual(recognized, publicText)
  }

  private func makeCaptureDelegate() throws -> AppDelegate {
    let png = try publicPNG()
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { url, finish in
      do {
        try png.write(to: url)
        finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "")))
      } catch {
        finish(.failure(error))
      }
    })
    let delegate = makeIsolatedAppDelegate(regionCapture: capture)
    appDelegate = delegate
    return delegate
  }

  private func publicPNG() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1_400, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1_400, height: 180))
    do {
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      (publicText as NSString).draw(
        at: NSPoint(x: 20, y: 60),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black,
        ])
    }
    let image = try XCTUnwrap(context.makeImage())
    return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  }

  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition(), Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition(), "Screenshot action did not present its OCR result within 10 seconds")
  }
}
