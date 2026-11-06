import AppKit
import XCTest

@testable import VocabCapture

final class MathIsolatedReviewTests: XCTestCase {
  func testOnlyFreshTemporaryChildDirectoryIsAccepted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertEqual(try MathIsolatedReview.directory(path: root.path), root.resolvingSymlinksInPath())
    for path in ["relative", "/", NSHomeDirectory(), FileManager.default.temporaryDirectory.path,
                 root.appendingPathComponent("missing-parent/child").path] {
      XCTAssertThrowsError(try MathIsolatedReview.directory(path: path), path)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try MathIsolatedReview.directory(path: root.path))
    let link = root.appendingPathComponent("home-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: NSHomeDirectory())
    XCTAssertThrowsError(try MathIsolatedReview.directory(path: link.appendingPathComponent("new-review").path))
  }

  @MainActor
  func testIsolatedDelegateLoadsRealLibraryAndOnlyIsolatedSkills() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let delegate = try MathIsolatedReview.makeDelegate(path: root.path)
    let data = try Data(contentsOf: root.appendingPathComponent("launch-scope.json"))
    let scope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let suite = try XCTUnwrap(scope["defaultsSuite"] as? String)
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    XCTAssertEqual(scope["normalStartupAcceptance"] as? Bool, false)
    XCTAssertEqual(scope["credentialsAvailable"] as? Bool, false)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    for _ in 0..<200 {
      if delegate.mathQuestionLibrary != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(delegate.mathQuestionLibrary)
    delegate.mathQuestionLibrary?.close()
    let store = MathQuestionStore(directory: root.appendingPathComponent("math"))
    let methods = try await store.automaticMethods()
    XCTAssertFalse(methods.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("math/questions.sqlite").path))
    await store.close()
  }
}
