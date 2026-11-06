import AppKit
import WebKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathCenterCutWebViewTests: XCTestCase {
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

  private func fenced(_ plan: [String: Any]) throws -> String {
    "```math-center-cut\n" + String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self) + "\n```"
  }


  private var plan: [String: Any] {
    ["title": "正方形挖孔一刀平分", "outerWidth": 10, "outerHeight": 10,
     "hole": ["x": 1.5, "y": 1.5, "width": 3, "height": 3]]
  }

  func testGeometryAndActualSnapshot() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "挖孔后的一刀切割", answer: try fenced(plan))], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-center-cut svg').length === 1", view)
    try await check("document.querySelectorAll('[data-cut=paper]').length", view, 2)
    try await check("document.querySelectorAll('[data-cut=empty]').length", view, 1)
    try await check("document.querySelectorAll('[data-cut=aid]').length", view, 2)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("""
      (()=>{let s=document.querySelector('.math-center-cut svg'),p=k=>{let e=s.querySelector('[data-point='+k+']');return [+e.getAttribute('cx'),+e.getAttribute('cy')]},a=p('A'),b=p('B'),o=p('O'),c=p('C'),cross=p=>(b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0]);let r=s.querySelector('[data-geometry=outer]'),x=+r.getAttribute('x'),y=+r.getAttribute('y'),w=+r.getAttribute('width'),h=+r.getAttribute('height');return Math.abs(cross(o))<1e-7&&Math.abs(cross(c))<1e-7&&[a,b].every(p=>p[0]>=x&&p[0]<=x+w&&p[1]>=y&&p[1]<=y+h&&(Math.abs(p[0]-x)<1e-7||Math.abs(p[0]-x-w)<1e-7||Math.abs(p[1]-y)<1e-7||Math.abs(p[1]-y-h)<1e-7))})()
      """, view, true)
    try await check("""
      (()=>{let s=document.querySelector('svg'),h=s.querySelector('[data-geometry=hole]'),x=+h.getAttribute('x'),y=+h.getAttribute('y'),w=+h.getAttribute('width'),height=+h.getAttribute('height'),ls=Array.from(s.querySelectorAll('[data-cut=paper]')),e=s.querySelector('[data-cut=empty]');return ls.every(l=>{let a=(+l.getAttribute('x1') + +l.getAttribute('x2'))/2,b=(+l.getAttribute('y1') + +l.getAttribute('y2'))/2;return !(a>x&&a<x+w&&b>y&&b<y+height)&&l.getAttribute('stroke-dasharray')==='none'})&&e.getAttribute('stroke-dasharray')!=='none'&&+ls[0].getAttribute('x2')===+e.getAttribute('x1')&&+ls[1].getAttribute('x1')===+e.getAttribute('x2')})()
      """, view, true)
    _ = try await js("window.scrollTo(0,0)", view)
    try await Task.sleep(nanoseconds: 100_000_000)
    let image: NSImage = try await withCheckedThrowingContinuation { continuation in
      view.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
        if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: error ?? NSError(domain: "center-cut-snapshot", code: 1)) }
      }
    }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/center-cut-render.png"))
  }

  func testRectangularHorizontalAndVerticalCutsRemainClipped() async throws {
    let view = try await loadedView()
    let holes: [[String: Double]] = [
      ["x": 4, "y": 1, "width": 4, "height": 2],
      ["x": 1, "y": 3, "width": 2, "height": 2],
      ["x": 7, "y": 1, "width": 3, "height": 2]
    ]
    let answers = try holes.map { hole -> String in
      var p = plan; p["outerWidth"] = 12; p["outerHeight"] = 8; p["hole"] = hole
      return try fenced(p)
    }
    view.render(turns: [ScreenshotAnswerTurn(question: "rectangles", answer: answers.joined(separator: "\n\n"))], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-center-cut svg').length === 3", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("Array.from(document.querySelectorAll('.math-center-cut svg')[0].querySelectorAll('[data-cut=paper],[data-cut=empty]')).every(l=>l.getAttribute('x1')===l.getAttribute('x2'))", view, true)
    try await check("Array.from(document.querySelectorAll('.math-center-cut svg')[1].querySelectorAll('[data-cut=paper],[data-cut=empty]')).every(l=>l.getAttribute('y1')===l.getAttribute('y2'))", view, true)
    try await check("Array.from(document.querySelectorAll('.math-center-cut svg')).every(s=>{let h=s.querySelector('[data-geometry=hole]'),e=s.querySelector('[data-cut=empty]'),x=+h.getAttribute('x'),y=+h.getAttribute('y'),w=+h.getAttribute('width'),height=+h.getAttribute('height');return [1,2].every(i=>{let a=+e.getAttribute('x'+i),b=+e.getAttribute('y'+i);return a>=x-1e-7&&a<=x+w+1e-7&&b>=y-1e-7&&b<=y+height+1e-7&&(Math.abs(a-x)<1e-7||Math.abs(a-x-w)<1e-7||Math.abs(b-y)<1e-7||Math.abs(b-y-height)<1e-7)})})", view, true)
  }

  func testInvalidPlansAreLocalAndInert() async throws {
    let view = try await loadedView()
    var invalid = [[String: Any]]()
    var p = plan; p["extra"] = "svg"; invalid.append(p)
    p = plan; p.removeValue(forKey: "title"); invalid.append(p)
    p = plan; p["title"] = "<img src=x onerror=window.cutPwned=true>"; invalid.append(p)
    p = plan; p["title"] = ["not": "text"]; invalid.append(p)
    for h in [["x":0,"y":1,"width":3,"height":3], ["x":8,"y":1,"width":3,"height":3], ["x":7,"y":1,"width":3,"height":3], ["x":1,"y":1,"width":0,"height":3], ["x":1,"y":1,"width":3,"height":-1], ["x":1,"y":1,"width":3,"height":3,"extra":1]] {
      p = plan; p["hole"] = h; invalid.append(p)
    }
    p = plan; p["outerWidth"] = 1001; invalid.append(p)
    p = plan; p["outerWidth"] = 0.00001; invalid.append(p)
    let answers = try invalid.map { try fenced($0) } + ["```math-center-cut\n{\"title\":\"bad\",\"outerWidth\":1e999,\"outerHeight\":10,\"hole\":{\"x\":1,\"y\":1,\"width\":1,\"height\":1}}\n```", "```math-center-cut\nnot JSON\n```"]
    for (i, answer) in answers.enumerated() {
      view.render(turns: [ScreenshotAnswerTurn(question: "bad-\(i)", answer: "保留答案\n\n" + answer)], zoom: 1)
      try await waitFor("document.querySelector('.question')?.textContent === '你：bad-\(i)' && document.querySelectorAll('.render-error').length === 1", view)
      try await check("document.querySelectorAll('.math-center-cut svg').length", view, 0)
      try await check("document.querySelector('.answer').textContent.includes('保留答案') && document.querySelector('.math-center-cut pre').textContent.length>0", view, true)
    }
    try await check("Boolean(window.cutPwned)", view, false)
    try await check("document.querySelectorAll('#transcript img,#transcript script,#transcript [onerror]').length", view, 0)
  }

  func testStreamingTwoTurnsAndConcentricHorizontal() async throws {
    let view = try await loadedView()
    let answer = try fenced(plan)
    view.render(turns: [ScreenshotAnswerTurn(question: "partial", answer: "```math-center-cut\n{\"title\":\"进行中\"")], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：partial'", view)
    try await check("document.querySelectorAll('.math-center-cut,.render-error').length", view, 0)
    try await check("document.querySelector('pre code').textContent.includes('进行中')", view, true)
    var concentric = plan; concentric["hole"] = ["x": 3.5, "y": 3.5, "width": 3, "height": 3]
    let turns = [ScreenshotAnswerTurn(question: "first", answer: answer), ScreenshotAnswerTurn(question: "second", answer: try fenced(concentric))]
    view.render(turns: turns, zoom: 1)
    view.render(turns: turns, zoom: 1)
    try await waitFor("document.querySelectorAll('.math-center-cut svg').length === 2", view)
    try await check("document.querySelectorAll('.turn').length", view, 2)
    try await check("Array.from(document.querySelectorAll('.math-center-cut svg')[1].querySelectorAll('[data-cut=paper],[data-cut=empty]')).every(l=>l.getAttribute('y1')===l.getAttribute('y2'))", view, true)
    try await check("document.querySelectorAll('.center-cut-note').length", view, 2)
  }
}
