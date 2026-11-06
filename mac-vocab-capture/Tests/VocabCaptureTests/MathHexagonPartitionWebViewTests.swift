import AppKit
import WebKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathHexagonPartitionWebViewTests: XCTestCase {
  private func loadedView() async throws -> ScreenshotAnswerWebView {
    _ = NSApplication.shared
    let view = ScreenshotAnswerWebView()
    view.frame = NSRect(x: 0, y: 0, width: 1020, height: 1000)
    var ready: Bool?
    view.onReady = { ready = $0 }
    for _ in 0..<200 {
      if let ready { XCTAssertTrue(ready); return view }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Offline renderer did not load")
    return view
  }

  private func js(_ code: String, _ view: WKWebView) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript(code) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value) }
      }
    }
  }

  private func check(_ expression: String, _ view: WKWebView, _ expected: AnyHashable) async throws {
    let actual = try await js(expression, view) as? AnyHashable
    XCTAssertEqual(actual, expected, expression)
  }

  private func waitFor(_ expression: String, _ view: WKWebView) async throws {
    for _ in 0..<200 {
      if try await js(expression, view) as? Bool == true { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Renderer condition timed out: \(expression)")
  }

  func testThreeConstructionsHaveExactCutsAndLabels() async throws {
    let view = try await loadedView()
    let answer = [3,4,5].map { "```math-hexagon-partition\n{\"sides\":\($0)}\n```" }.joined(separator: "\n\n")
    XCTAssertTrue(ScreenshotQuestionPanel.hasDeferredHexagonPresentation(in: answer))
    view.render(turns: [.init(question: "三种等分", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-hexagon-partition svg').length === 3", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("JSON.stringify(Array.from(document.querySelectorAll('.math-hexagon-partition svg')).map(s=>s.querySelectorAll('polygon').length))", view, "[6,3,3]")
    try await check("Array.from(document.querySelectorAll('.math-hexagon-partition svg')).every(s=>s.querySelectorAll('line[data-cut]').length===3)", view, true)
    try await check("JSON.stringify(Array.from(document.querySelectorAll('.math-hexagon-partition svg')).map(s=>s.querySelectorAll('circle[data-point]').length))", view, "[7,7,10]")
    try await check("Array.from(document.querySelectorAll('.math-hexagon-partition svg')).every((s,i)=>Array.from(s.querySelectorAll('polygon')).every(p=>p.getAttribute('points').split(' ').length===i+3))", view, true)
  }
  func testActualConstructionSnapshots() async throws {
    let view = try await loadedView()
    for sides in [3,4,5] {
      view.render(turns: [.init(question: "正六边形等分", answer: "```math-hexagon-partition\n{\"sides\":\(sides)}\n```")], zoom: 1)
      try await waitFor("document.querySelectorAll('.math-hexagon-partition svg').length === 1", view)
      let image: NSImage = try await withCheckedThrowingContinuation { continuation in
        view.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
          if let image { continuation.resume(returning: image) }
          else { continuation.resume(throwing: error ?? NSError(domain: "hexagon-snapshot", code: 1)) }
        }
      }
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/hexagon-partition-\(sides).png"))
    }
  }

  func testInvalidPlansAreRejected() async throws {
    let view = try await loadedView()
    for value in ["{}", "{\"sides\":6}", "{\"sides\":true}", "{\"sides\":3,\"sides\":5}"] {
      let answer = "```math-hexagon-partition\n" + value + "\n```"
      XCTAssertFalse(ScreenshotQuestionPanel.hasDeferredHexagonPresentation(in: answer))
      view.render(turns: [.init(question: "invalid", answer: answer)], zoom: 1)
      try await waitFor("document.querySelectorAll('.render-error').length === 1", view)
      try await check("document.querySelectorAll('.math-hexagon-partition svg').length", view, 0)
    }
  }
}
