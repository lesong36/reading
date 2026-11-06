import AppKit
import XCTest
@testable import VocabCapture

/// Source-selected regression cases with independently calculated answers.
/// The source document is not a trusted answer key or a production question import.
@MainActor
final class MathDiagramDocumentTests: XCTestCase {
  private func corpus() throws -> [String: Any] {
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "MathDiagramDocumentCases", withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
  }

  func testSourceCoverageHasAllThirtyOneFamiliesAndExplicitLimitations() throws {
    let corpus = try corpus()
    let source = try XCTUnwrap(corpus["source"] as? [String: Any])
    XCTAssertEqual(source["sha256"] as? String, "6886fcc09280e975b39667e70b678e7fd25efccfa637d5e6f45b28951d3f866a")
    let inventory = try XCTUnwrap(corpus["inventory"] as? [[String: Any]])
    let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
    XCTAssertEqual(inventory.count, 111)
    XCTAssertEqual(Set(cases.compactMap { $0["sectionID"] as? Int }), Set(1...31))
    XCTAssertEqual(Set(inventory.compactMap { $0["id"] as? String }).count, inventory.count)
    XCTAssertEqual(Set(cases.compactMap { $0["id"] as? String }).count, cases.count)
    XCTAssertEqual(cases.filter { $0["status"] as? String == "supported" }.count, 27)
    XCTAssertEqual(cases.filter { $0["status"] as? String == "unsupported" }.count, 6)
    XCTAssertEqual(cases.filter { $0["status"] as? String == "quarantined" }.count, 5)
    for entry in cases {
      let id = try XCTUnwrap(entry["id"] as? String)
      XCTAssertFalse((entry["stem"] as? String ?? "").isEmpty, id)
      XCTAssertTrue((entry["sourceLocator"] as? String ?? "").contains("第"), id)
      XCTAssertTrue(inventory.contains { $0["id"] as? String == id }, id)
      if entry["status"] as? String != "supported" {
        XCTAssertFalse((entry["reason"] as? String ?? "").isEmpty, id)
        XCTAssertNil(entry["plans"], "Unsupported or quarantined cases must not fabricate executable gold: \(id)")
      }
    }
  }

  func testDocumentPlansCompileToGoldAndActuallyRenderAcrossChatAndPDFWidths() throws {
    let cases = try XCTUnwrap(try corpus()["cases"] as? [[String: Any]])
    var renderedKinds = Set<String>()
    for entry in cases where entry["status"] as? String == "supported" {
      let id = try XCTUnwrap(entry["id"] as? String)
      let plans = try XCTUnwrap(entry["plans"] as? [[String: Any]])
      let envelope: [String: Any] = ["schemaVersion": 1, "diagrams": plans]
      let json = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
      let result = MathDiagramAnswer.parse("保留原解题文字。\n```math-diagrams\n" + String(decoding: json, as: UTF8.self) + "\n```")
      XCTAssertNil(result.failure, "\(id): \(result.failure ?? "")")
      XCTAssertEqual(result.text, "保留原解题文字。", id)
      XCTAssertEqual(result.diagrams.count, plans.count, id)
      guard result.diagrams.count == plans.count else { continue }
      let expected = try XCTUnwrap(entry["expected"] as? [String: Any])
      let gold = try XCTUnwrap(expected["values"] as? [String: NSNumber])
      for (reference, value) in gold {
        let pieces = reference.split(separator: ":", maxSplits: 1).map(String.init)
        let diagramID = pieces.count == 2 ? pieces[0] : id
        let factID = pieces.count == 2 ? pieces[1] : reference
        let diagram = try XCTUnwrap(result.diagrams.first { $0.id == diagramID }, reference)
        let actual = try XCTUnwrap(diagram.fact(factID)?.value, "\(id): \(reference)")
        XCTAssertEqual(actual, value.doubleValue, accuracy: 0.000001, "\(id): \(reference)")
        XCTAssertEqual(diagram.fact(factID)?.origin, .derived, "Expected outputs must be computed: \(id): \(reference)")
      }
      for diagram in result.diagrams {
        renderedKinds.insert(diagram.kind.rawValue)
        let attributed = NSMutableAttributedString(string: result.text)
        MathDiagramPresentation.append([diagram], failure: nil, to: attributed, width: 900)
        var imageAttachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
          if let attachment = value as? NSTextAttachment, attachment.image != nil { imageAttachments += 1 }
        }
        XCTAssertEqual(imageAttachments, 1, "Actual question/archive attachment missing: \(id)")
        XCTAssertFalse(attributed.string.contains("图解未显示"), id)
        XCTAssertTrue(attributed.string.contains("答案核验以用户标记为准"), id)
        if let output = ProcessInfo.processInfo.environment["MATH_DIAGRAM_DOCUMENT_PREVIEW_DIR"] {
          let directory = URL(fileURLWithPath: output, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try MathDiagramRenderer.renderPNG(diagram, width: 900).write(to: directory.appendingPathComponent(diagram.id + ".png"))
        }
        for width: CGFloat in [360, 507.28, 900] {
          let layout = try MathDiagramRenderer.layout(diagram, width: width)
          XCTAssertFalse(layout.elements.isEmpty, id)
          XCTAssertTrue(layout.elements.contains { if case .text = $0.shape { return false }; return true }, "Native drawing is required, not just an explanation: \(id)")
          let image = try MathDiagramRenderer.renderPNG(diagram, width: width)
          XCTAssertNotNil(NSBitmapImageRep(data: image), "\(id), width \(width)")
        }
      }
    }
    XCTAssertTrue(Set(["bar_comparison", "equal_parts", "state", "table", "area", "interval", "part_whole", "balance", "cycle"]).isSubset(of: renderedKinds))
  }

  func testSourceErrorsAndUnsupportedExactFractionsCannotBecomeTrustedAnswers() throws {
    let cases = try XCTUnwrap(try corpus()["cases"] as? [[String: Any]])
    let statuses = Dictionary(uniqueKeysWithValues: cases.map { ($0["id"] as! String, $0["status"] as! String) })
    for id in ["doc-19-01", "doc-09-03", "doc-17-03", "doc-21-02", "doc-29-02"] {
      XCTAssertEqual(statuses[id], "quarantined", id)
    }
    XCTAssertEqual(statuses["doc-13-01"], "unsupported")
    // A valid-looking arithmetic plan must still reject the rounded clock answer.
    let invalid: [String: Any] = ["id": "clock", "title": "钟面追及精确值", "kind": "quantity_plan", "view": "table",
      "quantities": [["id": "a", "label": "追及分子", "unit": "分钟", "value": 240, "evidence": "4点对应20格、统一乘12后的追及分子"],
        ["id": "b", "label": "统一分母后的相对速度", "unit": "", "value": 11, "evidence": "分针每分1格、时针1/12格；差为11/12"],
        ["id": "time", "label": "精确时间", "operation": "quotient", "inputs": ["a", "b"]]],
      "columns": ["精确时间"], "rows": [["label": "钟针重合", "factIDs": ["time"]]]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(invalid))
  }
}
