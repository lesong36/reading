import AppKit
import WebKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathCubePathWebViewTests: XCTestCase {
  func testSixRoutesAndInvalidInputRenderWithoutLosingText() async throws {
    _ = NSApplication.shared
    let view = ScreenshotAnswerWebView()
    view.frame = NSRect(x: 0, y: 0, width: 1020, height: 1000)
    var ready = false
    view.onReady = { ready = $0 }
    for _ in 0..<200 where !ready { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(ready)
    let paths = (0...5).map { "```math-cube-path\n{\"title\":\"路径示意\",\"edge\":\($0)}\n```" }
    let invalid = "```math-cube-path\n{\"title\":\"非法\",\"edge\":6}\n```"
    let duplicate = "```math-cube-path\n{\"title\":\"重复\",\"edge\":0,\"edge\":1}\n```"
    view.render(turns: [ScreenshotAnswerTurn(question: "说明路线", answer: "文字保留\n\n" + (paths + [invalid, duplicate]).joined(separator: "\n\n"))], zoom: 1)
    func js(_ code: String) async throws -> Any? {
      try await withCheckedThrowingContinuation { c in
        view.evaluateJavaScript(code) { value, error in
          if let error { c.resume(throwing: error) } else { c.resume(returning: value) }
        }
      }
    }
    for _ in 0..<200 {
      if try await js("document.querySelectorAll('.math-cube-path').length === 8") as? Bool == true { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let diagrams = try await js("document.querySelectorAll('.math-cube-path svg').length") as? Int
    let errors = try await js("document.querySelectorAll('.math-cube-path .render-error').length") as? Int
    let textPresent = try await js("document.body.innerText.includes('文字保留')") as? Bool
    XCTAssertEqual(diagrams, 6)
    XCTAssertEqual(errors, 2)
    XCTAssertEqual(textPresent, true)
    _ = try await js("window.scrollTo(0,0)")
    try await Task.sleep(nanoseconds: 100_000_000)
    let shot: NSImage = try await withCheckedThrowingContinuation { c in
      view.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
        if let image { c.resume(returning: image) } else { c.resume(throwing: error ?? NSError(domain: "cube-snapshot", code: 1)) }
      }
    }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(shot.tiffRepresentation)))
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cube-path-render.png"))
    for index in 0...5 {
      _ = try await js("document.querySelectorAll('.math-cube-path')[\(index)].scrollIntoView({block:'start'})")
      try await Task.sleep(nanoseconds: 100_000_000)
      let image: NSImage = try await withCheckedThrowingContinuation { c in
        view.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
          if let image { c.resume(returning: image) } else { c.resume(throwing: error ?? NSError(domain: "cube-snapshot", code: 1)) }
        }
      }
      let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cube-path-\(index).png"))
    }
  }
}
