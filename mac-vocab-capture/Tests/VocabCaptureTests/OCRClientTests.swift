import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class OCRClientTests: XCTestCase {
  func testBlankAndTinyImagesThrowWithoutResumingTwice() async throws {
    for size in [(1, 1), (2, 1), (64, 64)] {
      let image = try makeImage(width: size.0, height: size.1)
      do {
        _ = try await OCRClient.recognize(image)
        XCTFail("An image without text must fail")
      } catch {
        XCTAssertFalse(error is CancellationError)
      }
    }
  }

  func testSyntheticEnglishImageIsRecognized() async throws {
    let image = try makeImage(
      width: 1200, height: 180, text: "A curious reader explores unfamiliar words.")
    let result = try await OCRClient.recognize(image)
    XCTAssertEqual(result, "A curious reader explores unfamiliar words.")
  }

  func testSyntheticEnglishImageReturnsNormalizedLayoutObservations() async throws {
    let image = try makeImage(width: 1200, height: 180, text: "A curious reader explores unfamiliar words.")
    let result = try await OCRClient.recognizeWithLayout(image)
    XCTAssertEqual(result.text, "A curious reader explores unfamiliar words.")
    let observation = try XCTUnwrap(result.observations.first)
    XCTAssertGreaterThan(result.observations.count, 3)
    XCTAssertFalse(observation.text.isEmpty)
    XCTAssertGreaterThan(observation.boundingBox.width, 0)
    XCTAssertGreaterThan(observation.boundingBox.height, 0)
    XCTAssertGreaterThanOrEqual(observation.boundingBox.minX, 0)
    XCTAssertLessThanOrEqual(observation.boundingBox.maxX, 1)
    XCTAssertGreaterThanOrEqual(observation.boundingBox.minY, 0)
    XCTAssertLessThanOrEqual(observation.boundingBox.maxY, 1)
  }

  func testAlreadyCancelledTaskDoesNotRecognize() async throws {
    let image = try makeImage(width: 1200, height: 180, text: "A curious reader.")
    let task = Task {
      try await OCRClient.recognize(image)
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled OCR must fail")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  private func makeImage(width: Int, height: Int, text: String? = nil) throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let text {
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      (text as NSString).draw(
        at: NSPoint(x: 20, y: 60),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black,
        ])
    }
    return try XCTUnwrap(context.makeImage())
  }
}
