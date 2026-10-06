import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class ScreenshotRegionCaptureTests: XCTestCase {
  func testPermissionDeniedNeverStartsProcess() {
    var ran = false
    let capture = ScreenshotRegionCapture(permission: { false }, runner: { _, _ in ran = true })
    var error: ScreenshotRegionError?
    capture.capture { if case .failure(let value) = $0 { error = value } }
    XCTAssertEqual(error, .permissionDenied)
    XCTAssertFalse(ran)
    XCTAssertFalse(capture.isRunning)
  }

  func testEscapeOnlyIsQuietCancel() {
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { _, finish in
      finish(.success(ScreenshotProcessResult(status: 1, diagnostic: "")))
    })
    var cancelled = false
    capture.capture { if case .success(nil) = $0 { cancelled = true } }
    XCTAssertTrue(cancelled)
    XCTAssertFalse(capture.isRunning)
  }

  func testModernSystemEscapeWithZeroStatusAndNoFileIsQuietCancel() {
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { _, finish in
      finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "")))
    })
    var cancelled = false
    capture.capture { if case .success(nil) = $0 { cancelled = true } }
    XCTAssertTrue(cancelled)
    XCTAssertFalse(capture.isRunning)
  }

  func testZeroStatusWithoutFileButWithDiagnosticRemainsFailure() {
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { _, finish in
      finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "capture failed")))
    })
    var error: ScreenshotRegionError?
    capture.capture { if case .failure(let value) = $0 { error = value } }
    XCTAssertEqual(error, .invalidImage)
  }

  func testDiagnosticAndUnexpectedExitAreVisibleFailures() {
    for value in [ScreenshotProcessResult(status: 1, diagnostic: "permission failure"),
      ScreenshotProcessResult(status: 2, diagnostic: "")] {
      let capture = ScreenshotRegionCapture(permission: { true }, runner: { _, finish in finish(.success(value)) })
      var error: ScreenshotRegionError?
      capture.capture { if case .failure(let value) = $0 { error = value } }
      XCTAssertEqual(error, .captureFailed(value.status))
    }
  }

  func testCorruptImageAndLaunchFailureAreDistinct() {
    let missing = ScreenshotRegionCapture(permission: { true }, runner: { url, finish in
      try! Data("not a PNG".utf8).write(to: url)
      finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "")))
    })
    var error: ScreenshotRegionError?
    missing.capture { if case .failure(let value) = $0 { error = value } }
    XCTAssertEqual(error, .invalidImage)
    let failed = ScreenshotRegionCapture(permission: { true }, runner: { _, finish in
      finish(.failure(URLError(.cannotOpenFile)))
    })
    failed.capture { if case .failure(let value) = $0 { error = value } }
    XCTAssertEqual(error, .launchFailed)
  }

  func testInjectedRunnerLoadsImageAndRemovesTemporaryFile() throws {
    var file: URL?
    let capture = ScreenshotRegionCapture(permission: { true }, runner: { url, finish in
      file = url
      let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
      try! image.representation(using: .png, properties: [:])!.write(to: url)
      finish(.success(ScreenshotProcessResult(status: 0, diagnostic: "")))
    })
    var width: Int?
    capture.capture { if case .success(let image) = $0 { width = image?.width } }
    XCTAssertEqual(width, 4)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(file).path))
  }
}
