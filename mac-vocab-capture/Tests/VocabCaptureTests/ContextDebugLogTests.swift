import Foundation
import XCTest
@testable import VocabCapture

final class ContextDebugLogTests: XCTestCase {
  func testRawExpiryRemovesPersistedFixtureAndReturnsToMetadata() async throws {
    // The suite must provide the isolated path; never clear the user's log.
    guard ProcessInfo.processInfo.environment["VOCAB_CAPTURE_DIAGNOSTICS_DIR"] != nil else {
      throw XCTSkip("Set VOCAB_CAPTURE_DIAGNOSTICS_DIR to a disposable test directory")
    }
    ContextDebugLog.clear()
    ContextDebugLog.enableRawDiagnostics(for: 0.15)
    ContextDebugLog.write("fixture", word: "SYNTHETIC_SECRET", context: "SYNTHETIC_CONTEXT")
    for _ in 0..<10 {
      if let text = try? String(contentsOf: ContextDebugLog.fileURL), text.contains("SYNTHETIC_SECRET") { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(try String(contentsOf: ContextDebugLog.fileURL).contains("SYNTHETIC_SECRET"))
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(ContextDebugLog.isRawDiagnosticsEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ContextDebugLog.fileURL.path))
    ContextDebugLog.write("after expiry", word: "SYNTHETIC_SECRET", context: "SYNTHETIC_CONTEXT")
    for _ in 0..<30 where !FileManager.default.fileExists(atPath: ContextDebugLog.fileURL.path) {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let text = try String(contentsOf: ContextDebugLog.fileURL)
    XCTAssertFalse(text.contains("SYNTHETIC_SECRET"))
    XCTAssertFalse(text.contains("SYNTHETIC_CONTEXT"))
    ContextDebugLog.disableRawDiagnostics()
  }
}
