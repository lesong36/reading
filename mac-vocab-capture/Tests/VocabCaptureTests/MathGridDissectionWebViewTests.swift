import AppKit
import WebKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathGridDissectionWebViewTests: XCTestCase {
  func testSevenDistinctRectanglesSkillExampleRenders() async throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "seven-distinct-rectangles-grid" })
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "七块长方形", answer: skill.instructions)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 25)
    try await check("(()=>{let groups=Array.from(document.querySelectorAll('.math-grid [data-board=source] rect')).reduce((m,r)=>{let k=r.getAttribute('data-piece');(m[k]??=[]).push(r);return m},{});let dims=[];if(Object.keys(groups).sort().join('')!=='ABCDEFG')return false;for(let rs of Object.values(groups)){let minX=Math.min(...rs.map(r=>+r.getAttribute('x'))),maxX=Math.max(...rs.map(r=>+r.getAttribute('x') + +r.getAttribute('width'))),minY=Math.min(...rs.map(r=>+r.getAttribute('y'))),maxY=Math.max(...rs.map(r=>+r.getAttribute('y') + +r.getAttribute('height')));let w=(maxX-minX)/(+rs[0].getAttribute('width')),h=(maxY-minY)/(+rs[0].getAttribute('height'));if(Math.abs(w*h-rs.length)>.0001)return false;dims.push([Math.round(w),Math.round(h)].sort((a,b)=>a-b).join('x'))}return dims.sort().join('|')==='1x1|1x2|1x3|1x4|1x5|2x2|2x3'})()", view, true)
  }
  func testMinimumSquareTilingSkillExampleRenders() async throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "five-square-minimum-square-tiling" })
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "最少正方形", answer: skill.instructions)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 25)
  }
  func testFourPieceSquareSkillExampleRenders() async throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "three-four-five-square-dissection" })
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "四块拼正方形", answer: skill.instructions)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 25)
    try await check("document.querySelectorAll('.math-grid [data-board=target] rect').length", view, 25)
  }
  func testElongatedCrossFourCongruentPiecesRender() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_CROSS_FOUR_PIECE_PLAN"] else { throw XCTSkip("Set source elongated cross plan") }
    let plan = try String(contentsOfFile: path, encoding: .utf8)
    let view = try await loadedView()
    view.render(turns: [.init(question: "细长十字分四全等块拼方形", answer: "```math-grid\n" + plan + "\n```")], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    for board in ["source", "target"] {
      try await check("document.querySelectorAll('[data-board=\(board)] rect').length", view, 36)
      try await check("(()=>{let rs=Array.from(document.querySelectorAll('[data-board=\(board)] rect'));return ['A','B','C','D'].every(k=>rs.filter(r=>r.getAttribute('data-piece')===k).length===9)})()", view, true)
    }
    try await savePartitionSnapshot(view, key: "MATH_CROSS_FOUR_PIECE_SNAPSHOT")
  }

  func testRecordedFourPieceSquarePlanRenders() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_FOUR_PIECE_PLAN"] else { throw XCTSkip("Set four-piece plan path") }
    let plan = try String(contentsOfFile: path, encoding: .utf8)
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "三与四拼五", answer: "```math-grid\n" + plan + "\n```")], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 25)
    try await check("document.querySelectorAll('.math-grid [data-board=target] rect').length", view, 25)
  }
  func testTriangleDissectionPresetsRenderAndRejectUnsupportedInput() async throws {
    let view = try await loadedView()
    let answer = "```math-triangle-dissection\n{\"pieces\":5}\n```\n\n```math-triangle-dissection\n{\"pieces\":13}\n```\n\n```math-triangle-dissection\n{\"pieces\":6}\n```"
    view.render(turns: [ScreenshotAnswerTurn(question: "三角形分割", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-triangle-dissection').length === 3", view)
    try await check("document.querySelectorAll('.math-triangle-dissection svg').length", view, 2)
    try await check("document.querySelectorAll('.math-triangle-dissection polygon').length", view, 18)
    try await check("document.querySelectorAll('.math-triangle-dissection .render-error').length", view, 1)
  }

  func test404E03TriangleDissectionRendersFixedSourcePartition() async throws {
    let view = try await loadedView()
    let answer = "```math-triangle-dissection\n{\"case\":\"404-e03\"}\n```"
    view.render(turns: [.init(question: "404-E03三角网四块全等分割", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-triangle-dissection svg').length === 1", view)
    try await check("document.querySelectorAll('.math-triangle-dissection .render-error').length", view, 0)
    try await check("document.querySelectorAll('.math-triangle-dissection polygon').length", view, 24)
    try await check("new Set(Array.from(document.querySelectorAll('.math-triangle-dissection polygon')).map(p=>p.getAttribute('data-piece'))).size", view, 4)
    try await check("document.querySelector('.math-triangle-dissection').textContent.includes('四块各6格')", view, true)
    if ProcessInfo.processInfo.environment["MATH_E03_SNAPSHOT"] != nil {
      try await savePartitionSnapshot(view, key: "MATH_E03_SNAPSHOT")
    }
  }

  func test404E12RectangleDissectionRendersFixedSourceAndTarget() async throws {
    let view = try await loadedView()
    let answer = "原图面积144，正方形边长12。\n```math-rectangle-dissection\n{\"case\":\"404-e12\"}\n```"
    view.render(turns: [.init(question: "404-E12三块矩形拼正方形", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-rectangle-dissection svg').length === 1", view)
    try await check("document.querySelectorAll('.math-rectangle-dissection .render-error').length", view, 0)
    try await check("document.querySelectorAll('.math-rectangle-dissection [data-piece]').length", view, 6)
    try await check("document.querySelectorAll('.math-rectangle-dissection [data-outline]').length", view, 2)
    try await check("document.querySelector('.math-rectangle-dissection').textContent.includes('三块均只平移')", view, true)
  }
  func testWindmillSkillExampleRenders() async throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "square-strip-windmill-packing" })
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "纸条裁剪示例", answer: skill.instructions)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 49)
  }
  func testRecordedLiveStripAnswerRenders() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_STRIP_RECORDED_ANSWER"] else {
      throw XCTSkip("Set MATH_STRIP_RECORDED_ANSWER to a recorded real-model answer")
    }
    let answer = try String(contentsOfFile: path, encoding: .utf8)
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "原卷纸条题", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.math-grid [data-board=source] rect').length", view, 49)
    // Identical source and target describe a single partition, so the renderer
    // intentionally suppresses the duplicate second board.
    try await check("document.querySelectorAll('.math-grid [data-board=target] rect').length", view, 0)
  }
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
    "```math-grid\n" + String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self) + "\n```"
  }

  func testActualStaircaseSourcesRenderCutsSeamsAndPhysicalCellAspect() async throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rectangle-staircase-reassembly" })
    let blocks = skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().map {
      String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(blocks.count, 2)
    let view = try await loadedView()
    let answer = blocks.map { "```math-grid\n" + $0 + "\n```" }.joined(separator: "\n\n")
    view.render(turns: [ScreenshotAnswerTurn(question: "实际切拼图", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 2", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.math-grid [data-board=source]').length", view, 2)
    try await check("document.querySelectorAll('.math-grid [data-board=target]').length", view, 2)
    try await check("document.querySelectorAll('.math-grid [data-seam=true]').length > 20", view, true)
    try await check("document.querySelectorAll('.math-grid [data-seam=false]').length > 20", view, true)
    try await check("document.querySelectorAll('.grid-cell-label').length", view, 110)
    try await check("Array.from(document.querySelectorAll('.grid-dimensions')).map(x=>x.textContent).join('|')", view, "25 × 16|20 × 20|49 × 25|35 × 35")
    let ratios = try await js("Array.from(document.querySelectorAll('.math-grid svg')).map(s=>{let r=s.querySelector('rect');return Number(r.getAttribute('width'))/Number(r.getAttribute('height'))})", view) as? [Double]
    XCTAssertEqual(try XCTUnwrap(ratios)[0], 1.25, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(ratios)[1], 1.4, accuracy: 0.000001)
    try await check("document.querySelectorAll('.grid-note').length", view, 2)
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>{let bottoms=['source','target'].map(name=>Math.max(...Array.from(s.querySelectorAll('[data-board='+name+'] rect')).map(r=>Number(r.getAttribute('y'))+Number(r.getAttribute('height')))));return Math.abs(bottoms[0]-bottoms[1])<.000001})", view, true)
    if let path = ProcessInfo.processInfo.environment["MATH_GRID_RENDERER_SNAPSHOT"] {
      let measuredHeight = try await js("document.documentElement.scrollHeight", view) as? Double
      let height = try XCTUnwrap(measuredHeight)
      view.frame.size.height = height + 10
      _ = try await js("window.scrollTo(0,0)", view)
      try await Task.sleep(nanoseconds: 50_000_000)
      let config = WKSnapshotConfiguration()
      let image: NSImage = try await withCheckedThrowingContinuation { continuation in
        view.takeSnapshot(with: config) { image, error in
          if let image { continuation.resume(returning: image) }
          else { continuation.resume(throwing: error ?? NSError(domain: "grid-snapshot", code: 1)) }
        }
      }
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
  }

  private func savePartitionSnapshot(_ view: WKWebView, key: String) async throws {
    guard let path = ProcessInfo.processInfo.environment[key] else { return }
    let measuredHeight = try await js("document.documentElement.scrollHeight", view) as? Double
    let height = try XCTUnwrap(measuredHeight)
    view.frame.size.height = height + 10
    _ = try await js("window.scrollTo(0,0)", view)
    try await Task.sleep(nanoseconds: 50_000_000)
    let image: NSImage = try await withCheckedThrowingContinuation { continuation in
      view.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
        if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: error ?? NSError(domain: "partition-snapshot", code: 1)) }
      }
    }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
  }

  func testMixedSquareSizeSourcesRenderExactlyOneCompletePartitionPerBranch() async throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "nested-square-size-inventory" })
    let blocks = skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().map {
      String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(blocks.count, 5)
    let view = try await loadedView()
    let answer = "原题未给边长，图中数字是辅助份数，不是厘米。\n" + blocks.map { "```math-grid\n" + $0 + "\n```" }.joined(separator: "\n\n")
    view.render(turns: [ScreenshotAnswerTurn(question: "五个分割小问", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.grid-partition-only').length === 5", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.grid-board').length", view, 5)
    try await check("document.querySelectorAll('[data-board=target]').length", view, 0)
    try await check("document.querySelectorAll('.grid-cell-label').length", view, 49)
    try await check("Array.from(document.querySelectorAll('.grid-dimensions')).map(x=>x.textContent).join('|')", view, "3 × 3|4 × 4|6 × 6|6 × 6|12 × 12")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).map(s=>new Set(Array.from(s.querySelectorAll('rect')).map(r=>r.getAttribute('data-piece'))).size).join('|')", view, "6|7|12|12|12")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).map(s=>{let m={};s.querySelectorAll('rect').forEach(r=>{let k=r.getAttribute('data-piece');m[k]=(m[k]||0)+1});return new Set(Object.values(m)).size}).join('|')", view, "2|2|2|3|4")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>{let m={};s.querySelectorAll('rect').forEach(r=>{let k=r.getAttribute('data-piece');(m[k]||= []).push(r)});return Object.values(m).every(rs=>{let minX=Math.min(...rs.map(r=>+r.getAttribute('x'))),maxX=Math.max(...rs.map(r=>+r.getAttribute('x') + +r.getAttribute('width'))),minY=Math.min(...rs.map(r=>+r.getAttribute('y'))),maxY=Math.max(...rs.map(r=>+r.getAttribute('y') + +r.getAttribute('height')));let w=maxX-minX,h=maxY-minY,cell=rs[0];return Math.abs(w-h)<.000001 && Math.abs(w*h-rs.length*(+cell.getAttribute('width'))*(+cell.getAttribute('height')))<.0001})})", view, true)
    try await check("Array.from(document.querySelectorAll('.grid-heading')).every(x=>x.textContent.includes('分块方案'))", view, true)
    try await savePartitionSnapshot(view, key: "MATH_NESTED_SQUARE_SNAPSHOT")
  }

  func testReusedE11AndMinimumPerimeterE13RenderTheirActualSourcePlans() async throws {
    let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "Source404E11Grid", withExtension: "json", subdirectory: "Fixtures")))
    let e11 = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "grid-partition-and-tiling" })
    XCTAssertEqual(skill.version, "2")
    let blocks = skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().map {
      String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(blocks.count, 2)
    let view = try await loadedView()
    let answer = (try fenced(e11)) + "\n\n```math-grid\n" + blocks[1] + "\n```"
    view.render(turns: [ScreenshotAnswerTurn(question: "原题9×4剪拼与七矩形最小周长", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.math-grid svg').length === 2", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.grid-board').length", view, 3)
    try await check("Array.from(document.querySelectorAll('.grid-dimensions')).map(x=>x.textContent).join('|')", view, "9 × 4|6 × 6|12 × 7")
    try await check("document.querySelectorAll('.grid-partition-only').length", view, 1)
    try await check("new Set(Array.from(document.querySelectorAll('.grid-partition-only rect')).map(r=>r.getAttribute('data-piece'))).size", view, 7)
    try await check("Array.from(document.querySelectorAll('.grid-partition-only rect')).length", view, 84)
    try await check("document.querySelectorAll('.grid-reassembly rect').length", view, 12)
    try await savePartitionSnapshot(view, key: "MATH_REUSED_GRID_SNAPSHOT")
  }

  func testSource404MultiPartitionsRenderAllThirteenEqualPiecePlans() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Source404MultiPartitionGrids", withExtension: "json", subdirectory: "Fixtures"))
    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    XCTAssertEqual(entries.count, 13)
    let plans = try entries.map { try XCTUnwrap($0["plan"] as? [String: Any]) }
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "404讲十三种四等分", answer: try plans.map { try fenced($0) }.joined(separator: "\n\n"))], zoom: 1)
    try await waitFor("document.querySelectorAll('.grid-partition-only').length === 13", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.grid-board').length", view, 13)
    try await check("document.querySelectorAll('[data-board=target]').length", view, 0)
    try await check("document.querySelectorAll('.grid-cell-label').length", view, 52)
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).map(s=>s.querySelectorAll('rect').length).join('|')", view, "16|16|16|16|16|32|32|32|32|32|32|32|32")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>{let counts={};s.querySelectorAll('rect').forEach(r=>{let p=r.getAttribute('data-piece');counts[p]=(counts[p]||0)+1});return Object.keys(counts).sort().join('')==='ABCD' && new Set(Object.values(counts)).size===1})", view, true)
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>{let box=s.viewBox.baseVal;return box.width>0 && box.height>0 && Array.from(s.querySelectorAll('rect')).every(r=>['x','y','width','height'].every(k=>Number.isFinite(+r.getAttribute(k))) && +r.getAttribute('width')>0 && +r.getAttribute('height')>0)})", view, true)
    for (id, count, key) in [
      ("video:404:extension:04", 4, "MATH_MULTI_PARTITION_E4_SNAPSHOT"),
      ("video:404:advanced:01", 8, "MATH_MULTI_PARTITION_A1_SNAPSHOT")
    ] {
      guard ProcessInfo.processInfo.environment[key] != nil else { continue }
      let subset = try entries.filter { $0["id"] as? String == id }.map { try fenced(XCTUnwrap($0["plan"] as? [String: Any])) }
      XCTAssertEqual(subset.count, count)
      view.frame.size.height = 1000
      view.render(turns: [ScreenshotAnswerTurn(question: id, answer: subset.joined(separator: "\n\n"))], zoom: 1)
      try await waitFor("document.querySelector('.question')?.textContent === '你：\(id)' && document.querySelectorAll('.grid-partition-only').length === \(count)", view)
      try await check("document.querySelectorAll('.render-error').length", view, 0)
      try await savePartitionSnapshot(view, key: key)
    }
  }

  func testMarkedGridConstraintsKeepOriginalLettersSeparateFromPieceLabels() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "SourceMarkedGridConstraints", withExtension: "json", subdirectory: "Fixtures"))
    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    XCTAssertEqual(entries.count, 2)
    let answers = try entries.map { try XCTUnwrap($0["answer"] as? String) }
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "原字母约束分块", answer: answers.joined(separator: "\n\n"))], zoom: 1)
    try await waitFor("document.querySelectorAll('.grid-partition-only').length === 2", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.grid-board').length", view, 2)
    try await check("document.querySelectorAll('[data-board=target]').length", view, 0)
    try await check("document.querySelectorAll('.grid-cell-label').length", view, 8)
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).map(s=>s.querySelectorAll('rect').length).join('|')", view, "36|16")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>{let counts={};s.querySelectorAll('rect').forEach(r=>{let p=r.getAttribute('data-piece');counts[p]=(counts[p]||0)+1});return Object.keys(counts).sort().join('')==='ABCD' && new Set(Object.values(counts)).size===1})", view, true)
    try await check("document.querySelectorAll('.answer table').length", view, 2)
    let originalRows = [
      ["A|(2,3)、(3,3)、(4,3)、(4,5)", "B|(2,2)、(5,4)、(6,4)、(1,5)", "C|(3,1)、(4,2)、(1,6)、(2,6)", "D|(5,1)、(1,2)、(5,2)、(6,6)"],
      ["A|(2,1)、(4,1)、(1,2)、(4,4)", "B|(2,2)、(3,2)、(4,3)、(2,4)"]
    ]
    for (index, rows) in originalRows.enumerated() {
      try await check("Array.from(document.querySelectorAll('.answer table')[\(index)].querySelectorAll('tbody tr')).map(r=>Array.from(r.querySelectorAll('td')).map(c=>c.textContent).join('|')).join(';')", view, rows.joined(separator: ";"))
    }
    try await check("Array.from(document.querySelectorAll('.answer table')).every(t=>!t.closest('.math-grid') && t.getBoundingClientRect().width>0 && t.getBoundingClientRect().height>0)", view, true)
    try await check("document.querySelector('.answer').textContent.includes('块号只表示纸片，不替换原字母')", view, true)
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>Array.from(s.querySelectorAll('.grid-cell-label')).map(x=>x.textContent).sort().join('')==='1234')", view, true)
    try await savePartitionSnapshot(view, key: "MATH_MARKED_GRID_SNAPSHOT")
  }

  func testFixedCountReassemblySkillRendersBothSourceAndTargetWithoutDistortion() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "SourceFixedGridReassembly", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "fixed-count-grid-piece-reassembly" })
    XCTAssertEqual(skill.version, "1")
    let blocks = skill.instructions.components(separatedBy: "```math-grid\n").dropFirst().map {
      String($0.components(separatedBy: "```")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(fixtures.count, 2)
    for (block, fixture) in zip(blocks, fixtures) {
      let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(block.utf8)) as? NSDictionary)
      XCTAssertEqual(actual, fixture as NSDictionary)
    }
    let view = try await loadedView()
    let answer = blocks.map { "```math-grid\n" + $0 + "\n```" }.joined(separator: "\n\n")
    view.render(turns: [ScreenshotAnswerTurn(question: "指定块数剪拼原例", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.grid-reassembly').length === 2", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.querySelectorAll('.grid-board').length", view, 4)
    try await check("document.querySelectorAll('[data-board=source]').length", view, 2)
    try await check("document.querySelectorAll('[data-board=target]').length", view, 2)
    try await check("document.querySelectorAll('.math-grid rect').length", view, 82)
    try await check("Array.from(document.querySelectorAll('.grid-board')).map(b=>b.querySelectorAll('rect').length).join('|')", view, "16|16|25|25")
    try await check("Array.from(document.querySelectorAll('.grid-board')).map(b=>{let counts={};b.querySelectorAll('rect').forEach(r=>{let p=r.getAttribute('data-piece');counts[p]=(counts[p]||0)+1});return Object.keys(counts).sort().map(p=>p+':'+counts[p]).join(',')}).join('|')", view, "A:6,B:10|A:6,B:10|1:17,2:6,3:2|1:17,2:6,3:2")
    try await check("Array.from(document.querySelectorAll('.math-grid svg')).every(s=>s.getAttribute('data-unit-width')==='1' && s.getAttribute('data-unit-height')==='1' && Array.from(s.querySelectorAll('rect')).every(r=>{let w=+r.getAttribute('width'),h=+r.getAttribute('height');return Number.isFinite(w) && w>0 && Math.abs(w-h)<.000001}))", view, true)
    try await savePartitionSnapshot(view, key: "MATH_FIXED_GRID_SNAPSHOT")
  }

  func testInvalidPartitionsStayLocalAndCannotExecuteSuppliedText() async throws {
    let view = try await loadedView()
    let base: [String: Any] = ["title": "分块图", "unitWidth": 1, "unitHeight": 1,
      "source": [["A", "A"]], "target": [["A"], ["A"]]]
    var cases = [[String: Any]]()
    var item = base; item["target"] = [["A"]]; cases.append(item) // Missing cell.
    item = base; item["target"] = [["B", "B"]]; cases.append(item) // Unknown piece.
    item = base; item["source"] = [["A", "B"], ["B", "A"]]; item["target"] = item["source"]; cases.append(item)
    item = base; item["source"] = [["A", "A"], ["A", ""]]; item["target"] = [["A", "A", "A"]]; cases.append(item)
    item = base; item["unitWidth"] = 2; cases.append(item) // Quarter turn stretches anisotropic cells.
    item = base; item["unitHeight"] = 0; cases.append(item)
    item = base; item["unitWidth"] = 0.0000001; cases.append(item)
    item = base; item["source"] = Array(repeating: ["A"], count: 17); item["target"] = item["source"]; cases.append(item)
    item = base; item["externalImage"] = "https://example.invalid/leak"; cases.append(item)
    for (index, plan) in cases.enumerated() {
      view.render(turns: [ScreenshotAnswerTurn(question: "invalid-\(index)", answer: "前面的答案仍然保留。\n\n" + (try fenced(plan)))], zoom: 1)
      try await waitFor("document.querySelector('.question')?.textContent === '你：invalid-\(index)' && document.querySelectorAll('.render-error').length === 1", view)
      try await check("document.querySelectorAll('.math-grid svg').length", view, 0)
      try await check("document.querySelector('.answer').textContent.includes('前面的答案仍然保留')", view, true)
      try await check("document.querySelector('.math-grid pre').textContent.includes('source')", view, true)
    }
    let nonfinite = "```math-grid\n{\"title\":\"非有限\",\"unitWidth\":1e999,\"unitHeight\":1,\"source\":[[\"A\"]],\"target\":[[\"A\"]]}\n```"
    view.render(turns: [ScreenshotAnswerTurn(question: "nonfinite", answer: nonfinite)], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：nonfinite' && document.querySelectorAll('.render-error').length === 1", view)
    item = base; item["title"] = "<img src=x onerror=window.gridPwned=true>"; item["source"] = [["<script>"]]; item["target"] = [["<script>"]]
    view.render(turns: [ScreenshotAnswerTurn(question: "inert", answer: try fenced(item))], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：inert' && document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("Boolean(window.gridPwned)", view, false)
    try await check("document.querySelectorAll('#transcript img,#transcript script,#transcript [onerror],#transcript [href]').length", view, 0)
    try await check("document.querySelector('.grid-title').textContent.includes('<img')", view, true)
    try await check("document.querySelector('.grid-legend').textContent.includes('<script>')", view, true)
    try await check("performance.getEntriesByType('resource').filter(x=>x.name.startsWith('https:')).length", view, 0)
  }

  func testIncompleteFenceRemainsCodeAndLatestAnswerWins() async throws {
    let view = try await loadedView()
    let base: [String: Any] = ["title": "方格", "unitWidth": 1, "unitHeight": 1,
      "source": [["A", "A"]], "target": [["A"], ["A"]]]
    view.render(turns: [ScreenshotAnswerTurn(question: "旧图", answer: try fenced(base))], zoom: 1)
    view.render(turns: [ScreenshotAnswerTurn(question: "待完成", answer: "```math-grid\n{\"title\":\"进行中\"")], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：待完成'", view)
    try await check("document.querySelectorAll('.math-grid, .render-error').length", view, 0)
    try await check("document.querySelector('pre code').textContent.includes('进行中')", view, true)
    view.render(turns: [ScreenshotAnswerTurn(question: "新图", answer: try fenced(base))], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：新图' && document.querySelectorAll('.math-grid svg').length === 1", view)
    try await check("document.querySelectorAll('.turn').length", view, 1)
    let longerClosingFence = try fenced(base) + "`"
    view.render(turns: [ScreenshotAnswerTurn(question: "更长闭合围栏", answer: longerClosingFence)], zoom: 1)
    try await waitFor("document.querySelector('.question')?.textContent === '你：更长闭合围栏' && document.querySelectorAll('.math-grid svg').length === 1", view)
  }
  func testSevenBySevenStripConstructionDisplaysTwelveStripsAndUnusedCell() async throws {
    let rows = ["AAAABCD", "GGGGBCD", "HHHHBCD", "KLIJBCD", "KLIFFFF", "KLIEEEE", "KLIMMMM"].map { $0.map(String.init) }
    let plan: [String: Any] = ["title": "12张纸条，J为未用格", "unitWidth": 1, "unitHeight": 1, "source": rows, "target": rows]
    let view = try await loadedView()
    let answer = "J是唯一未用格，不是纸条。\n" + (try fenced(plan))
    view.render(turns: [ScreenshotAnswerTurn(question: "7×7纸条构造", answer: answer)], zoom: 1)
    try await waitFor("document.querySelectorAll('.grid-partition-only').length === 1", view)
    try await check("document.querySelectorAll('.render-error').length", view, 0)
    try await check("document.body.textContent.includes('J是唯一未用格，不是纸条')", view, true)
    try await check("document.querySelectorAll('.grid-partition-only rect').length", view, 49)
    try await check("(()=>{let m={};document.querySelectorAll('.grid-partition-only rect').forEach(r=>{let k=r.getAttribute('data-piece');(m[k]||=[]).push(r)});return Object.keys(m).length===13 && m.J?.length===1 && Object.entries(m).filter(([k])=>k!=='J').every(([k,v])=>v.length===4 && (new Set(v.map(r=>r.getAttribute('x'))).size===1 || new Set(v.map(r=>r.getAttribute('y'))).size===1))})()", view, true)
    try await savePartitionSnapshot(view, key: "MATH_STRIP_GRID_SNAPSHOT")
  }

}
