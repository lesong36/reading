import AppKit
import XCTest
@testable import VocabCapture

final class MathDiagramRendererTests: XCTestCase {
  func testDifferenceRatioShowsExtraPartsBeyondTheSmallerQuantity() throws {
    let answer = """
    ```math-diagrams
    {"schemaVersion":1,"diagrams":[{"id":"ratio","title":"差倍关系","kind":"difference_ratio","difference":{"value":72,"unit":"","evidence":"原题差72"},"multiplier":{"value":10,"evidence":"原题乘10"}}]}
    ```
    """
    let diagram = try XCTUnwrap(MathDiagramAnswer.parse(answer).diagrams.first)
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(diagram, width: width)
      let bars = layout.elements.filter { if case .box = $0.shape { return true }; return false }
      XCTAssertEqual(bars.count, 3)
      XCTAssertEqual(bars[0].frame.minX, bars[1].frame.minX, accuracy: 0.01)
      XCTAssertEqual(bars[2].frame.minX, bars[0].frame.maxX, accuracy: 0.01)
      XCTAssertEqual(bars[2].frame.maxX, bars[1].frame.maxX, accuracy: 0.01)
      XCTAssertEqual(bars[0].frame.width * 10, bars[1].frame.width, accuracy: 0.01)
      XCTAssertEqual(bars[0].frame.width * 9, bars[2].frame.width, accuracy: 0.01)
    }
  }
  func testValidatedExactDecimalsDoNotDisplayBinaryFloatingPointNoise() throws {
    let answer = """
    ```math-diagrams
    {"schemaVersion":1,"diagrams":[{"id":"ratio","title":"差倍关系","kind":"difference_ratio","difference":{"value":1,"unit":"千克","evidence":"原题差1千克"},"multiplier":{"value":6,"evidence":"原题6倍"}}]}
    ```
    """
    let diagram = try XCTUnwrap(MathDiagramAnswer.parse(answer).diagrams.first)
    let layout = try MathDiagramRenderer.layout(diagram)
    let labels = layout.elements.compactMap { if case .text(let value, _, _) = $0.shape { return value }; return nil }
    XCTAssertTrue(labels.contains { $0.contains("1.2千克") })
    XCTAssertFalse(labels.contains { $0.contains("000000000") })
  }
  func testTinyNonzeroQuantityIsNotSilentlyDisplayedAsZero() throws {
    var diagram = MathDiagramFixtures.bar
    for index in diagram.facts.indices {
      diagram.facts[index].unit = ""
      diagram.facts[index].value = (diagram.facts[index].value ?? 0) * 1e-6
    }
    let layout = try MathDiagramRenderer.layout(diagram)
    let labels = layout.elements.compactMap { if case .text(let value, _, _) = $0.shape { return value }; return nil }
    XCTAssertFalse(labels.contains { $0.hasSuffix("· 0") })
    XCTAssertTrue(labels.contains { $0.contains("0.000045") })
  }
  func testIntervalRendersAllThirteenGapsAtWideWidthAndExplicitOmissionAtNarrowWidths() throws {
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(MathDiagramFixtures.interval, width: width)
      let points = layout.elements.filter { if case .point = $0.shape { return true }; return false }
      let gapLines = layout.elements.filter { element in
        if case .line = element.shape { return element.frame.height == 0 && element.frame.width > 0 }
        return false
      }
      let labels = layout.elements.compactMap { if case .text(let value, _, _) = $0.shape { return value }; return nil }
      XCTAssertEqual(points.count, width == 900 ? 14 : 6)
      // The final horizontal line is the bracket spanning the entire interval path.
      XCTAssertEqual(gapLines.count, width == 900 ? 14 : 5)
      XCTAssertTrue(labels.contains("起点楼层：1")); XCTAssertTrue(labels.contains("终点楼层：14"))
      XCTAssertTrue(labels.contains("共 13 个间隔"))
      XCTAssertTrue(labels.contains { $0.contains("每段台阶数") && $0.contains("21级") })
      XCTAssertTrue(labels.contains { $0.contains("台阶总数") && $0.contains("273级") })
      XCTAssertTrue(labels.contains { width == 900 ? $0.contains("完整画出 13 个间隔") : $0.contains("省略 9 个间隔") })
      XCTAssertNotNil(NSBitmapImageRep(data: try MathDiagramRenderer.renderPNG(MathDiagramFixtures.interval, width: width)))
    }
  }
  func testIntervalSupportsOneGapAndLargeCountsWithoutInventingPoints() throws {
    var single = MathDiagramFixtures.interval
    single.facts[1].value = 2; single.facts[2].value = 1; single.facts[4].value = 21
    let one = try MathDiagramRenderer.layout(single, width: 360)
    XCTAssertEqual(one.elements.filter { if case .point = $0.shape { return true }; return false }.count, 2)
    var large = MathDiagramFixtures.interval
    large.facts[1].value = 1001; large.facts[2].value = 1000; large.facts[4].value = 21000
    let many = try MathDiagramRenderer.layout(large, width: 900)
    let labels = many.elements.compactMap { if case .text(let value, _, _) = $0.shape { return value }; return nil }
    XCTAssertEqual(many.elements.filter { if case .point = $0.shape { return true }; return false }.count, 6)
    XCTAssertTrue(labels.contains { $0.contains("省略 996 个间隔") })
    XCTAssertTrue(labels.contains("共 1000 个间隔"))
  }
  func testOptionalPreviewArtifacts() throws {
    guard let directory = ProcessInfo.processInfo.environment["MATH_DIAGRAM_PREVIEW_DIRECTORY"] else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for diagram in MathDiagramFixtures.all {
      try MathDiagramRenderer.renderPNG(diagram).write(to: url.appendingPathComponent(diagram.id + ".png"))
    }
    var long = MathDiagramFixtures.state
    long.title = "长中文标注与窄窗口排版验证"
    long.facts = long.facts.map { fact in var copy = fact; copy.label = "四年级同学在这个阶段对应的实际人数：" + fact.label; return copy }
    try MathDiagramRenderer.renderPNG(long, width: 360).write(to: url.appendingPathComponent("long-chinese-360.png"))
  }
  func testFiveTemplatesRenderDecodablePNGsWithExpectedDimensions() throws {
    for diagram in MathDiagramFixtures.all {
      let size = try MathDiagramRenderer.size(diagram, width: 900)
      let data = try MathDiagramRenderer.renderPNG(diagram, width: 900, scale: 2)
      let image = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertEqual(image.pixelsWide, 1800)
      XCTAssertEqual(image.pixelsHigh, Int(ceil(size.height * 2)))
      XCTAssertGreaterThan(data.count, 5000)
    }
  }
  func testLongChineseLabelsWrapWithinNarrowAndWideLayouts() throws {
    for source in MathDiagramFixtures.all {
      var diagram = source
      diagram.title = String(repeating: "四年级数学图解：数量关系", count: 4)
      diagram.facts = diagram.facts.map { fact in
        var fact = fact; fact.label = String(repeating: "同一组学生在分配方案中对应的数量", count: 4); return fact
      }
      for width: CGFloat in [360, 640, 900, 1500] {
        let layout = try MathDiagramRenderer.layout(diagram, width: width)
        let bounds = CGRect(origin: .zero, size: layout.size)
        XCTAssertTrue(layout.elements.allSatisfy { bounds.insetBy(dx: -0.1, dy: -0.1).contains($0.frame) })
        XCTAssertLessThan(layout.size.height, 8000)
      }
    }
  }
  func testPhysicalRectangleUsesLegibleTrueAspectRatioAndMarksFallbackSketch() throws {
    var diagram = MathDiagramFixtures.area
    diagram.parts = []
    diagram.facts[0].value = 10
    diagram.facts[1].value = 8
    diagram.facts[2].value = 80
    let layout = try MathDiagramRenderer.layout(diagram)
    let box = try XCTUnwrap(layout.elements.first { if case .box = $0.shape { return true }; return false })
    XCTAssertEqual(Double(box.frame.width / box.frame.height), 1.25, accuracy: 0.000001)
    let captions = layout.elements.compactMap { if case .text(let text, _, _) = $0.shape { return text }; return nil }
    XCTAssertTrue(captions.contains { $0.contains("按边长比例绘制") })
    diagram.facts[1].value = 0.001
    diagram.facts[2].value = 0.01
    let flat = try MathDiagramRenderer.layout(diagram)
    let notes = flat.elements.compactMap { if case .text(let text, _, _) = $0.shape { return text }; return nil }
    XCTAssertTrue(notes.contains { $0.contains("不按边长比例") })
    XCTAssertNoThrow(try MathDiagramRenderer.renderPNG(diagram))
  }

  func testLongAreaCaptionExpandsFlatRectangleInsteadOfClipping() throws {
    var diagram = MathDiagramFixtures.area
    diagram.parts = []
    diagram.facts[1].value = 0.1; diagram.facts[2].value = 1.4
    diagram.facts[2].label = String(repeating: "完整面积说明", count: 15)
    let layout = try MathDiagramRenderer.layout(diagram, width: 360)
    XCTAssertGreaterThan(layout.size.height, 250)
    XCTAssertNoThrow(try MathDiagramRenderer.renderPNG(diagram, width: 360))
  }
  func testUnknownBarsDoNotLeakAssumedValuesOrHaveDifferentNumericLengths() throws {
    let layout = try MathDiagramRenderer.layout(MathDiagramFixtures.unknown)
    let bars = layout.elements.filter { if case .box = $0.shape { return true }; return false }
    XCTAssertEqual(bars.count, 2)
    XCTAssertEqual(bars[0].frame.width, bars[1].frame.width)
    let texts = layout.elements.compactMap { if case .text(let text, _, _) = $0.shape { return text }; return nil }
    XCTAssertTrue(texts.contains { $0.contains("仅作示意") })
    XCTAssertTrue(texts.contains { $0.contains("待求 · ？") })
  }
  func testRenderingIsDeterministicAndDoesNotMutateContextState() throws {
    let diagram = MathDiagramFixtures.area
    XCTAssertEqual(try MathDiagramRenderer.renderPNG(diagram), try MathDiagramRenderer.renderPNG(diagram))
    let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 13, y: 17)
    let before = context.ctm
    try MathDiagramRenderer.draw(diagram, in: context, rect: CGRect(x: 20, y: 30, width: 600, height: 500))
    XCTAssertEqual(context.ctm, before)
  }
  func testRejectsUnsupportedDimensionsAndUnreadableAreaCells() {
    for width: CGFloat in [0, .nan, 2000] { XCTAssertThrowsError(try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar, width: width)) }
    XCTAssertThrowsError(try MathDiagramRenderer.renderPNG(MathDiagramFixtures.bar, scale: 10))
    var tiny = MathDiagramFixtures.area; tiny.parts = [1, 1]
    XCTAssertThrowsError(try MathDiagramRenderer.renderPNG(tiny, width: 360))
  }
  func testVectorPDFDrawingProducesPDF() throws {
    let bytes = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
    for diagram in MathDiagramFixtures.all {
      var page = CGRect(x: 0, y: 0, width: 612, height: 792)
      context.beginPage(mediaBox: &page)
      try MathDiagramRenderer.draw(diagram, in: context, rect: page.insetBy(dx: 24, dy: 24), layoutWidth: page.width - 48)
      context.endPage()
    }
    context.closePDF()
    let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!))
    XCTAssertEqual(pdf.numberOfPages, MathDiagramFixtures.all.count)
  }
}
