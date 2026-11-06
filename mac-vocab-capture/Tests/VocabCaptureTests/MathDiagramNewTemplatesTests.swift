import AppKit
import XCTest
@testable import VocabCapture

/// Independent arithmetic examples exercise native geometry, screen attachments and PDF paths.
enum MathDiagramNewFixtures {
  static let whole = MathDiagram(id: "joined-parts", title: "两段路合起来是一整段", kind: .partWhole,
    facts: [MathDiagramFixtures.given("total", "全程", 600, "米"),
      MathDiagramFixtures.given("first", "先走的路", 225, "米"), MathDiagramFixtures.derived("rest", "剩下的路", 375, "米")],
    relations: [.init(operation: .difference, inputIDs: ["total", "first"], outputID: "rest"),
      .init(operation: .sum, inputIDs: ["first", "rest"], outputID: "total")], factIDs: ["total", "first", "rest"])
  static let venn = MathDiagram(id: "overlapping-groups", title: "两项活动的人数不能重复计数", kind: .venn,
    facts: [MathDiagramFixtures.given("left", "只参加绘画", 24), MathDiagramFixtures.given("both", "两项都参加", 12),
      MathDiagramFixtures.given("right", "只参加音乐", 18), MathDiagramFixtures.derived("union", "至少参加一项", 54),
      MathDiagramFixtures.given("outside", "两项都不参加", 6), MathDiagramFixtures.derived("total", "全班", 60)],
    relations: [.init(operation: .sum, inputIDs: ["left", "both", "right"], outputID: "union"),
      .init(operation: .sum, inputIDs: ["union", "outside"], outputID: "total")], factIDs: ["left", "both", "right", "union", "outside", "total"])
  static let balance = MathDiagram(id: "moving-to-average", title: "移多少才能一样多", kind: .balance,
    facts: [MathDiagramFixtures.given("high", "甲班", 45), MathDiagramFixtures.given("low", "乙班", 27),
      .init(id: "two", label: "平分两份", value: 2, origin: .constant, evidence: "两个班平分总人数"),
      MathDiagramFixtures.derived("sum", "总人数", 72), MathDiagramFixtures.derived("difference", "人数差", 18),
      MathDiagramFixtures.derived("mean", "平均人数", 36), MathDiagramFixtures.derived("transfer", "移去人数", 9)],
    relations: [.init(operation: .sum, inputIDs: ["high", "low"], outputID: "sum"),
      .init(operation: .difference, inputIDs: ["high", "low"], outputID: "difference"),
      .init(operation: .quotient, inputIDs: ["sum", "two"], outputID: "mean"),
      .init(operation: .quotient, inputIDs: ["difference", "two"], outputID: "transfer")], factIDs: ["high", "low", "mean", "transfer"])
  static let cycle = MathDiagram(id: "ordered-pattern", title: "红黄蓝绿按顺序重复", kind: .cycle,
    facts: [MathDiagramFixtures.given("total", "总项数", 30, ""), MathDiagramFixtures.given("period", "每周期项数", 4, ""),
      MathDiagramFixtures.derived("cycles", "完整周期数", 7, ""), MathDiagramFixtures.derived("remainder", "余项数", 2, "")],
    relations: [.init(operation: .floorQuotient, inputIDs: ["total", "period"], outputID: "cycles"),
      .init(operation: .remainder, inputIDs: ["total", "period"], outputID: "remainder")],
    factIDs: ["total", "period", "cycles", "remainder"], columns: ["红色", "黄色", "蓝色", "绿色"])
  static let all = [whole, venn, balance, cycle]
}

final class MathDiagramNewTemplatesTests: XCTestCase {
  private func texts(_ layout: MathDiagramRenderer.Layout) -> [String] {
    layout.elements.compactMap { if case .text(let value, _, _) = $0.shape { return value }; return nil }
  }
  private func boxes(_ layout: MathDiagramRenderer.Layout) -> [MathDiagramRenderer.Element] {
    layout.elements.filter { if case .box = $0.shape { return true }; return false }
  }
  func testJoinedSegmentsHaveCorrectProportionsAndShareAnEntireWholeBracket() throws {
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(MathDiagramNewFixtures.whole, width: width)
      let segments = boxes(layout)
      XCTAssertEqual(segments.count, 2)
      XCTAssertEqual(segments[0].frame.maxX, segments[1].frame.minX, accuracy: 0.001)
      XCTAssertEqual(segments[0].frame.width / segments[1].frame.width, 0.6, accuracy: 0.001)
      XCTAssertTrue(layout.elements.contains { element in
        if case .line(let end) = element.shape {
          return element.frame.minX == segments[0].frame.minX && end.x == segments[1].frame.maxX && element.frame.height == 0
        }; return false
      })
      XCTAssertTrue(texts(layout).contains { $0.contains("全程") && $0.contains("600米") })
    }
  }
  func testUnknownJoinedSegmentsUseEqualWidthsAndExplicitSchematicNotice() throws {
    var unknown = MathDiagramNewFixtures.whole
    unknown.facts[1] = .init(id: "first", label: "先走的路", unit: "米", origin: .unknown)
    unknown.facts[2] = .init(id: "rest", label: "剩下的路", unit: "米", origin: .unknown)
    let layout = try MathDiagramRenderer.layout(unknown, width: 360)
    let segments = boxes(layout)
    XCTAssertEqual(segments[0].frame.width, segments[1].frame.width)
    XCTAssertTrue(texts(layout).contains { $0.contains("不按数值比例") })
    XCTAssertFalse(texts(layout).contains { $0.contains("225") || $0.contains("375") })
  }
  func testVennUsesTwoIntersectingCirclesWithDisjointRegionNumbersAndOutsideCount() throws {
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(MathDiagramNewFixtures.venn, width: width)
      let circles = layout.elements.filter { if case .ellipse = $0.shape { return true }; return false }
      XCTAssertEqual(circles.count, 2)
      XCTAssertTrue(circles[0].frame.intersects(circles[1].frame))
      XCTAssertLessThan(circles[0].frame.minX, circles[1].frame.minX)
      for value in ["24人", "12人", "18人", "54人", "6人", "60人"] {
        XCTAssertTrue(texts(layout).contains { $0.contains(value) })
      }
      XCTAssertTrue(texts(layout).contains { $0.contains("交叠处只计一次") })
    }
  }
  func testBalanceUsesProportionalVerticalBarsAnAverageLineAndTransferArrow() throws {
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(MathDiagramNewFixtures.balance, width: width)
      let bars = boxes(layout)
      XCTAssertEqual(bars.count, 2)
      XCTAssertEqual(bars[0].frame.maxY, bars[1].frame.maxY)
      XCTAssertEqual(bars[0].frame.height / bars[1].frame.height, 45.0 / 27.0, accuracy: 0.001)
      let meanY = bars[0].frame.maxY - bars[0].frame.height * 36 / 45
      XCTAssertTrue(layout.elements.contains { element in
        if case .line(let end) = element.shape { return abs(element.frame.minY - meanY) < 0.001 && end.x > bars[1].frame.maxX }; return false
      })
      XCTAssertEqual(layout.elements.filter { if case .arrow = $0.shape { return true }; return false }.count, 1)
      XCTAssertTrue(texts(layout).contains { $0.contains("移去人数") && $0.contains("9人") })
    }
  }
  func testCycleDrawsThreeCompletePeriodsPlusOnlyActualRemainderAndMarksOmission() throws {
    for width: CGFloat in [360, 507.28, 900] {
      let layout = try MathDiagramRenderer.layout(MathDiagramNewFixtures.cycle, width: width)
      XCTAssertEqual(boxes(layout).count, 14)
      XCTAssertTrue(texts(layout).contains { $0.contains("省略 4 个完整周期") })
      XCTAssertTrue(texts(layout).contains { $0.contains("最后 2 个余项") })
      XCTAssertTrue(texts(layout).contains { $0.contains("红色") && $0.contains("绿色") })
    }
    var exact = MathDiagramNewFixtures.cycle
    exact.facts[0].value = 28; exact.facts[3].value = 0
    let layout = try MathDiagramRenderer.layout(exact, width: 360)
    XCTAssertEqual(boxes(layout).count, 12)
    XCTAssertTrue(texts(layout).contains { $0.contains("没有余项") })
    var short = MathDiagramNewFixtures.cycle
    short.facts[0].value = 2; short.facts[2].value = 0
    XCTAssertEqual(boxes(try MathDiagramRenderer.layout(short, width: 360)).count, 2)
  }
  func testEveryNewTemplateProducesPNGAndFitsBoundsAtScreenAndPDFWidths() throws {
    for diagram in MathDiagramNewFixtures.all {
      for width: CGFloat in [360, 507.28, 900] {
        let layout = try MathDiagramRenderer.layout(diagram, width: width)
        let bounds = CGRect(origin: .zero, size: layout.size).insetBy(dx: -0.01, dy: -0.01)
        XCTAssertTrue(layout.elements.allSatisfy { bounds.contains($0.frame) })
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: MathDiagramRenderer.renderPNG(diagram, width: width)))
        XCTAssertEqual(bitmap.pixelsWide, Int(ceil(width * 2)))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)
      }
    }
  }
  func testNewTemplateChineseLabelsWrapRatherThanClipAtNarrowWidth() throws {
    for source in MathDiagramNewFixtures.all {
      var diagram = source
      diagram.title = "四年级数学：" + String(repeating: "数量关系图示", count: 8)
      diagram.facts = diagram.facts.map { fact in
        var copy = fact
        copy.label = String(repeating: "同一组学生对应的实际数量", count: 4)
        return copy
      }
      for width: CGFloat in [360, 507.28, 900] {
        let layout = try MathDiagramRenderer.layout(diagram, width: width)
        XCTAssertLessThan(layout.size.height, 8000)
        XCTAssertNoThrow(try MathDiagramRenderer.renderPNG(diagram, width: width))
      }
    }
  }
  func testCycleNameColorsAgreeWithKnownColorLabels() throws {
    let blocks = boxes(try MathDiagramRenderer.layout(MathDiagramNewFixtures.cycle, width: 360))
    guard case .box(let red, _) = blocks[0].shape, case .box(let blue, _) = blocks[2].shape else { return XCTFail("Missing cycle boxes") }
    let redComponents = try XCTUnwrap(red.components), blueComponents = try XCTUnwrap(blue.components)
    XCTAssertGreaterThan(redComponents[0], redComponents[2])
    XCTAssertGreaterThan(blueComponents[2], blueComponents[0])
    for index in 0..<4 {
      guard case .box(let first, _) = blocks[index].shape, case .box(let next, _) = blocks[index + 4].shape else { return XCTFail("Missing repeated boxes") }
      XCTAssertEqual(first, next)
    }
  }
  func testPortableNewKindsPassNormalAnswerParsingAndPDFLegibilityGate() throws {
    for diagram in MathDiagramNewFixtures.all {
      try MathDiagramAnswer.validateRendering(diagram)
      let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(diagram), encoding: .utf8))
      let json = "{\"schemaVersion\":1,\"diagrams\":[" + encoded + "]}"
      let result = MathDiagramAnswer.parse("原有解题内容\n```math-diagrams\n" + json + "\n```")
      XCTAssertNil(result.failure)
      XCTAssertEqual(result.diagrams, [diagram])
      XCTAssertTrue(result.text.contains("原有解题内容"))
    }
  }
  func testNewTemplatesProduceFourVectorPDFPagesAndRestoreContext() throws {
    let bytes = NSMutableData()
    let output = try XCTUnwrap(CGDataConsumer(data: bytes))
    let context = try XCTUnwrap(CGContext(consumer: output, mediaBox: nil, nil))
    for diagram in MathDiagramNewFixtures.all {
      var page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
      context.beginPage(mediaBox: &page)
      let before = context.ctm
      try MathDiagramRenderer.draw(diagram, in: context, rect: CGRect(x: 44, y: 80, width: 507.28, height: 700), layoutWidth: 507.28)
      XCTAssertEqual(context.ctm, before)
      context.endPage()
    }
    context.closePDF()
    XCTAssertEqual(try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!)).numberOfPages, 4)
  }
  @MainActor func testNativeAnswerPresentationContainsAllFourImageAttachments() throws {
    let text = NSMutableAttributedString(string: "答案仍需用户核验")
    MathDiagramPresentation.append(MathDiagramNewFixtures.all, failure: nil, to: text, width: 507.28)
    var images = 0
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
      if let attachment = value as? NSTextAttachment, attachment.image != nil { images += 1 }
    }
    XCTAssertEqual(images, 4)
    XCTAssertFalse(text.string.contains("图解未显示"))
  }
  func testOptionalNewTemplatePreviewArtifacts() throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_DIAGRAM_PREVIEW_DIRECTORY"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for diagram in MathDiagramNewFixtures.all {
      for width: CGFloat in [360, 507.28, 900] {
        try MathDiagramRenderer.renderPNG(diagram, width: width).write(to: directory.appendingPathComponent("\(diagram.id)-\(Int(width)).png"))
      }
    }
  }
}
