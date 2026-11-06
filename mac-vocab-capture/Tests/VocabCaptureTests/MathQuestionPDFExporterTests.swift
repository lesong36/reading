import CSQLite
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest

@testable import VocabCapture

final class MathQuestionPDFExporterTests: XCTestCase {
  @MainActor
  func testPageSizedBlockquoteStaysTogetherAcrossOffsets() async throws {
    for count in [3,5,7,9] {
      let prefix = Array(repeating: "Leading paragraph.", count: count).joined(separator: "\n\n")
      let answer = prefix + "\n\n> CautionStart: cut to the midpoints, never to the vertices. "
        + String(repeating: "Keep all five sides visible. ", count: 5) + "CautionEnd."
      let slices = try await MathAnswerPDFRenderer.pages(question: "Caution", answer: answer,
        note: "", size: CGSize(width: 500, height: 260))
      let texts = try slices.map { try XCTUnwrap(PDFDocument(data: $0)?.string) }
      let page = try XCTUnwrap(texts.first { $0.contains("CautionStart") })
      XCTAssertTrue(page.contains("CautionEnd"), "short blockquote split at offset \(count)")
    }
  }

  func testNearPagePhotoFitsWithoutFooterOnlyContinuation() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "near-page", imageData: image(height: 1450)))
    let count = try await MathQuestionPDFExporter.export(records: [record], store: store,
      to: directory.appendingPathComponent("near-page.pdf"))
    XCTAssertEqual(count, 1)
    await store.close()
  }

  func testArchivedHexagonReexportPreservesAnswerAndThreeFigures() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["MATH_HEXAGON_PDF_SOURCE"], let output = env["MATH_HEXAGON_PDF_OUTPUT"]
    else { throw XCTSkip("Opt-in original hexagon answer export") }
    let fixture = URL(fileURLWithPath: source)
    let archived = try JSONDecoder().decode([MathQuestionSolution].self,
      from: Data(contentsOf: fixture.appendingPathComponent("hexagon-source-solutions.json")))
    let photo = try Data(contentsOf: fixture.appendingPathComponent("hexagon-source-question.png"))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "archived-hexagon", imageData: photo, solutions: archived))
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store,
      to: URL(fileURLWithPath: output), options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: output)))
    let texts = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
      .map { $0.filter { !$0.isWhitespace } }
    XCTAssertTrue(texts.contains { $0.contains("注意：如果切到间隔") && $0.contains("才能得到五边形") })
    for marker in ["三条完整线段", "画OA、OC、OE", "画OM、ON、OP"] {
      XCTAssertTrue(texts.contains { $0.contains(marker) }, marker)
    }
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, archived.first?.answer)
    XCTAssertEqual(saved.first?.method, archived.first?.method)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    await store.close()
  }

  @MainActor
  func test404E12RecordedAnswerReexportKeepsTextAndDiagramFence() async throws {
    guard let source = ProcessInfo.processInfo.environment["MATH_E12_RESPONSE_JSON"] else {
      throw XCTSkip("Opt-in recorded E12 answer export")
    }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source))) as! [String: Any]
    let choices = object["choices"] as! [[String: Any]]
    let message = choices[0]["message"] as! [String: Any]
    let answer = message["content"] as! String
    let pages = try await MathAnswerPDFRenderer.pages(question: "404-E12三块矩形拼正方形", answer: answer,
      note: "原图来源：第404讲第9页；本页为保存答案离线重导出。", size: CGSize(width: 612, height: 792))
    XCTAssertFalse(pages.isEmpty)
    let text = pages.compactMap { PDFDocument(data: $0)?.string }.joined()
    XCTAssertTrue(text.contains("16") && text.contains("12"))
    XCTAssertTrue(text.contains("math-rectangle-dissection") == false, "fence must be rendered, not leaked")
    if let output = ProcessInfo.processInfo.environment["MATH_E12_PDF_OUTPUT"] {
      let document = PDFDocument()
      for data in pages { if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) } }
      XCTAssertTrue(document.write(to: URL(fileURLWithPath: output)))
    }
  }

  @MainActor
  func test404E03FixedTriangleAnswerReexportKeepsTextAndDiagram() async throws {
    let answer = "图4-13由24个小三角形组成，四块各6格，允许翻面后全等。\n\n```math-triangle-dissection\n{\"case\":\"404-e03\"}\n```"
    let pages = try await MathAnswerPDFRenderer.pages(question: "404-E03三角网四块全等分割", answer: answer,
      note: "原图来源：第404讲第7页；本页为保存答案离线重导出。", size: CGSize(width: 612, height: 792))
    XCTAssertFalse(pages.isEmpty)
    let text = pages.compactMap { PDFDocument(data: $0)?.string }.joined()
    XCTAssertTrue(text.contains("24") && text.contains("四块各6格"))
    XCTAssertFalse(text.contains("math-triangle-dissection"), "fence must be rendered, not leaked")
  }

  @MainActor
  func test404E12RecordedAnswerPersistsOriginalHashAndUnverifiedSolution() async throws {
    guard let source = ProcessInfo.processInfo.environment["MATH_E12_RESPONSE_JSON"] else {
      throw XCTSkip("Opt-in recorded E12 SQLite persistence")
    }
    let photoURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/evaluations/2026-10-22-gauss-fullbook/geometry/404-e12-source-page-09.png")
    let photo = try Data(contentsOf: photoURL)
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source))) as! [String: Any]
    let answer = (((object["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])["content"] as! String)
    let solution = MathQuestionSolution(question: "404-E12三块矩形拼正方形", answer: answer,
      model: "Qwen3.8-27B-P920", verificationStatus: "unverified")
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "404-e12-recorded", imageData: photo,
      ocrText: "图4-22 16×9 三块拼正方形", solutions: [solution]))
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.answer, answer)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    let original = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(original, photo)
    await store.close()
  }

  @MainActor
  func test404E03FixedAnswerPersistsOriginalImageAndUnverifiedSolution() async throws {
    let photoURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/evaluations/2026-10-22-gauss-fullbook/geometry/404-e03-source/page-07.png")
    let photo = try Data(contentsOf: photoURL)
    let answer = "图4-13由24个小三角形组成，四块各6格。\n```math-triangle-dissection\n{\"case\":\"404-e03\"}\n```"
    let solution = MathQuestionSolution(question: "404-E03三角网四块全等分割", answer: answer,
      model: "Qwen3.8-27B-P920", verificationStatus: "unverified")
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "404-e03-fixed", imageData: photo,
      ocrText: "图4-13 三角网四块全等分割", solutions: [solution]))
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, answer)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    let original = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(original, photo)
    await store.close()
  }

  func testGeneratedDigitStrategyExportPreservesStateSequenceAndLedgers() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["MATH_DIGIT_PDF_SOURCE"], let output = env["MATH_DIGIT_PDF_OUTPUT"]
    else { throw XCTSkip("Opt-in generated digit strategy export") }
    let fixture = URL(fileURLWithPath: source)
    let archived = try JSONDecoder().decode([MathQuestionSolution].self,
      from: Data(contentsOf: fixture.appendingPathComponent("reported-digit-game-source-solutions.json")))
    let photo = try Data(contentsOf: fixture.appendingPathComponent("reported-digit-game-source-question.png"))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "digit", imageData: photo, solutions: archived))
    let url = URL(fileURLWithPath: output)
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    let texts = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
      .map { $0.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "−", with: "-").filter { !$0.isWhitespace } }
    for marker in ["-11", "-21", "-31", "-41", "-51", "-61", "-71", "-81", "240-100=140", "299-159=140"] {
      XCTAssertTrue(texts.joined().contains(marker), marker)
    }
    for first in ["4", "5"] {
      let page = try XCTUnwrap(texts.first { $0.contains("首报" + first + "的完整最优对局:") })
      XCTAssertTrue(page.contains(first == "4" ? "240-100=140" : "299-159=140"))
    }
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, archived.first?.answer)
    XCTAssertEqual(saved.first?.method, archived.first?.method)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    await store.close()
  }

  func testArchivedReflectedLedgersKeepCaptionsWithTables() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["MATH_REFLECTED_PDF_ROOT"], let output = env["MATH_REFLECTED_PDF_OUTPUT"]
    else { throw XCTSkip("Opt-in archived reflected answers export") }
    let root = URL(fileURLWithPath: source), destination = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    for (folder, name, caption, marker) in [
      ("419-reflected-program-live-20261031", "same-end", "全程90", "280"),
      ("419-reflected-diagnostic-live-20261031", "opposite-ends", "全程65", "75")
    ] {
      let fixture = root.appendingPathComponent(folder)
      let photo = try Data(contentsOf: fixture.appendingPathComponent(name + "-question.png"))
      let archived = try JSONDecoder().decode([MathQuestionSolution].self,
        from: Data(contentsOf: fixture.appendingPathComponent(name + "-solutions.json")))
      let store = MathQuestionStore(directory: directory.appendingPathComponent(name))
      let record = try await store.save(.init(captureID: name, imageData: photo, solutions: archived))
      let url = destination.appendingPathComponent(name + ".pdf")
      _ = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url,
        options: .init(includeSolutions: true))
      let document = try XCTUnwrap(PDFDocument(url: url))
      let texts = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        .map { $0.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace } }
      let page = try XCTUnwrap(texts.first { $0.contains(caption) })
      XCTAssertTrue(page.contains(marker), name + " caption detached from ledger")
      let saved = try await store.solutions(questionID: record.id)
      XCTAssertEqual(saved.first?.answer, archived.first?.answer)
      XCTAssertEqual(saved.first?.method, archived.first?.method)
      XCTAssertEqual(saved.first?.verificationStatus, "unverified")
      await store.close()
    }
  }

  func testArchivedAverageCounterexampleKeepsLabelWithTable() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["MATH_AVERAGE_PDF_SOURCE"], let output = env["MATH_AVERAGE_PDF_OUTPUT"]
    else { throw XCTSkip("Opt-in archived average answer export") }
    let fixture = URL(fileURLWithPath: source)
    let archived = try JSONDecoder().decode([MathQuestionSolution].self,
      from: Data(contentsOf: fixture.appendingPathComponent("average-source-solutions.json")))
    let photo = try Data(contentsOf: fixture.appendingPathComponent("average-source-question.png"))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "average-caption", imageData: photo, solutions: archived))
    let url = URL(fileURLWithPath: output)
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    let texts = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
      .map { $0.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace } }
    let page = try XCTUnwrap(texts.first { $0.contains("第二组:") })
    XCTAssertTrue(page.contains("56,52,54"), "Second counterexample label detached from its table")
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, archived.first?.answer)
    XCTAssertEqual(saved.first?.method, archived.first?.method)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    await store.close()
  }

  func testArchivedMagicAnswerKeepsCompletedMatrixOnOnePage() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["MATH_SAVED_MAGIC_DIRECTORY"], let output = env["MATH_SAVED_MAGIC_PDF"]
    else { throw XCTSkip("Opt-in archived magic answer export") }
    let fixture = URL(fileURLWithPath: source)
    let answer = try String(contentsOf: fixture.appendingPathComponent("magic-five-source-answer.txt"), encoding: .utf8)
    let photo = try Data(contentsOf: fixture.appendingPathComponent("magic-five-source-question.png"))
    let archived = try JSONDecoder().decode([MathQuestionSolution].self,
      from: Data(contentsOf: fixture.appendingPathComponent("magic-five-source-solutions.json")))
    XCTAssertEqual(archived.first?.answer, answer)
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "archived-magic", imageData: photo,
      solutions: archived))
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store,
      to: URL(fileURLWithPath: output), options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: output)))
    let texts = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
      .map { $0.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace } }
    let matrixPage = try XCTUnwrap(texts.first { $0.contains("291104") })
    for row in ["291104", "37826", "53846", "84923", "83087"] {
      XCTAssertTrue(matrixPage.contains(row), row)
    }
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, answer)
    XCTAssertEqual(saved.first?.question, archived.first?.question)
    XCTAssertEqual(saved.first?.diagramFailure, archived.first?.diagramFailure)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    await store.close()
  }

  @MainActor
  func testOversizedTableRetainsEveryRowAcrossPages() async throws {
    let rows = (1...40).map { "| item\($0)start | item\($0)end |" }
    let answer = (["| Left | Right |", "| --- | --- |"] + rows).joined(separator: "\n")
    let slices = try await MathAnswerPDFRenderer.pages(question: "Long table", answer: answer,
      note: "", size: CGSize(width: 500, height: 260))
    XCTAssertGreaterThan(slices.count, 1)
    let texts = try slices.map { try XCTUnwrap(PDFDocument(data: $0)?.string) }
    for row in 1...40 {
      XCTAssertTrue(texts.contains { $0.contains("item\(row)start") && $0.contains("item\(row)end") })
    }
  }

  @MainActor
  func testPageSizedTableStaysTogetherAcrossDifferentPageOffsets() async throws {
    let rows = (1...5).map { "| row\($0)start | \($0) | row\($0)end |" }
    let table = (["| Column A | Column B | Column C |", "| --- | --- | --- |"] + rows)
      .joined(separator: "\n")
    for count in [3, 5, 7, 9] {
      let prefix = Array(repeating: "Leading paragraph.", count: count).joined(separator: "\n\n")
      let slices = try await MathAnswerPDFRenderer.pages(
        question: "Table pagination", answer: prefix + "\n\nCaption marker:\n\n" + table + "\n\nEnd marker.",
        note: "", size: CGSize(width: 500, height: 260))
      let texts = try slices.map { data in
        try XCTUnwrap(PDFDocument(data: data)?.string)
      }
      let tablePages = texts.filter { $0.contains("row1start") }
      XCTAssertEqual(tablePages.count, 1)
      let tablePage = try XCTUnwrap(tablePages.first)
      XCTAssertTrue(tablePage.contains("Caption marker:"), "caption orphan, prefix \(count)")
      for row in 1...5 {
        XCTAssertTrue(tablePage.contains("row\(row)start"), "row \(row), prefix \(count)")
        XCTAssertTrue(tablePage.contains("row\(row)end"), "row \(row), prefix \(count)")
      }
      XCTAssertTrue(texts.joined().contains("End marker."))
    }
  }

  func testArithmeticNoticeSurvivesStoreReopenAndPDFWithoutChangingAnswer() async throws {
    let original = "面积核对：1+2+3+4+5+4+4+6=25，正好25格。"
    let photo = try image()
    let firstStore = MathQuestionStore(directory: directory)
    let record = try await firstStore.save(.init(captureID: "arithmetic-notice", imageData: photo,
      solutions: [.init(question: "检查面积", answer: original, model: "archived-fixture")]))
    await firstStore.close()
    let store = MathQuestionStore(directory: directory)
    let saved = try await store.solutions(questionID: record.id)
    XCTAssertEqual(saved.first?.answer, original)
    XCTAssertEqual(saved.first?.verificationStatus, "unverified")
    let output = directory.appendingPathComponent("arithmetic-notice.pdf")
    let count = try await MathQuestionPDFExporter.export(records: [record], store: store, to: output,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertEqual(document.pageCount, count)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    for marker in ["算式核对提示", "29、25", "不代表整题已核验", "1+2+3+4+5+4+4+6=25"] {
      XCTAssertTrue(text.contains(marker), marker)
    }
    let noticePosition = try XCTUnwrap(text.range(of: "算式核对提示"))
    let answerPosition = try XCTUnwrap(text.range(of: "面积核对"))
    XCTAssertLessThan(noticePosition.lowerBound, answerPosition.lowerBound)
    let after = try await store.solutions(questionID: record.id)
    XCTAssertEqual(after, saved)
    let archivedPhoto = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(archivedPhoto, photo)
    await store.close()
  }

  func testSavedRealAnswerExportsWithoutAnotherProviderCall() async throws {
    guard let source = ProcessInfo.processInfo.environment["MATH_SAVED_ANSWER_DIRECTORY"],
      let output = ProcessInfo.processInfo.environment["MATH_SAVED_ANSWER_PDF"]
    else { throw XCTSkip("Opt-in archived real-answer export") }
    let fixture = URL(fileURLWithPath: source)
    let answer = try String(contentsOf: fixture.appendingPathComponent("stage-two-machine-waiting-answer.txt"), encoding: .utf8)
    let photo = try Data(contentsOf: fixture.appendingPathComponent("stage-two-machine-waiting-question.png"))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "saved-real-answer", imageData: photo,
      solutions: [.init(question: "原卷双机总等待问题", answer: answer, model: "archived-deepseek-flash")]))
    let url = URL(fileURLWithPath: output)
    let count = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertEqual(document.pageCount, count)
    XCTAssertGreaterThan(count, 2)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    let joinedText = text.filter { !$0.isWhitespace }
    for marker in ["尚未核验", "59", "五、说明", "用时间线表格与分段验算更清楚"] {
      XCTAssertTrue(joinedText.contains(marker.precomposedStringWithCompatibilityMapping), marker)
    }
    for raw in ["##", "**", "\\boxed", "\\text", "\\times", "\\["] {
      XCTAssertFalse(text.contains(raw), raw)
    }
    let savedPhoto = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(savedPhoto, photo)
    await store.close()
  }

  func testGridDiagramFitsPDFContentWidth() async throws {
    let store = MathQuestionStore(directory: directory)
    let answer = #"""
      ## 方格分割
      ```math-grid
      {"title":"四块方格","unitWidth":1,"unitHeight":1,"source":[["A","B"],["C","D"]],"target":[["A","B"],["C","D"]]}
      ```
      完整网格结束
      """#
    let record = try await store.save(.init(captureID: "grid-pdf-width", imageData: image(),
      solutions: [.init(question: "画分割线", answer: answer, model: "fixture")]))
    let output = directory.appendingPathComponent("grid-width.pdf")
    let pages = try await MathQuestionPDFExporter.export(records: [record], store: store, to: output,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertEqual(document.pageCount, pages)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    XCTAssertTrue(text.contains("完整网格结束"))
    XCTAssertFalse(text.contains("math-grid"))
    XCTAssertFalse(text.contains("unitWidth"))
    await store.close()
  }

  func testRecordedGridAnswerExportsWithoutProvider() async throws {
    guard let source = ProcessInfo.processInfo.environment["MATH_SAVED_GRID_DIRECTORY"] else {
      throw XCTSkip("Set archived original grid answer directory")
    }
    let fixture = URL(fileURLWithPath: source)
    let answer = try String(contentsOf: fixture.appendingPathComponent("seven-rectangles-source-answer.txt"), encoding: .utf8)
    let photo = try Data(contentsOf: fixture.appendingPathComponent("seven-rectangles-source-question.png"))
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "recorded-grid", imageData: photo,
      solutions: [.init(question: "原图七块长方形分割", answer: answer, model: "archived-source")]))
    let output = ProcessInfo.processInfo.environment["MATH_SAVED_GRID_PDF"].map { URL(fileURLWithPath: $0) }
      ?? directory.appendingPathComponent("recorded-grid.pdf")
    do {
      let pages = try await MathQuestionPDFExporter.export(records: [record], store: store, to: output,
        options: .init(includeSolutions: true))
      let document = try XCTUnwrap(PDFDocument(url: output))
      XCTAssertEqual(document.pageCount, pages)
      let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
      XCTAssertTrue(text.contains("七块"))
      XCTAssertFalse(text.contains("math-grid"))
      XCTAssertFalse(text.contains("unitWidth"))
      let savedPhoto = try await store.originalImage(questionID: record.id)
      XCTAssertEqual(savedPhoto, photo)
    } catch {
      let detail = error as NSError
      print("RECORDED_GRID_EXPORT_ERROR: \(detail.domain) \(detail.code) \(detail.userInfo)")
      await store.close()
      throw error
    }
    await store.close()
  }

  func testAnswerAppendixRendersMarkdownMathAndTablesWithoutRawMarkup() async throws {
    let store = MathQuestionStore(directory: directory)
    let answer = #"""
      ## 最短等待
      **结论**为59分钟。

      | 机器 | 等待 |
      | --- | --- |
      | 甲机器 | 26分钟 |
      | 乙机器 | 33分钟 |

      \[2\times7+2\times10+12+13=59\]

      完整结束标记
      """#
    let record = try await store.save(.init(captureID: "formatted-answer", imageData: image(),
      solutions: [.init(question: "请解释", answer: answer, model: "fixture")]))
    let url = directory.appendingPathComponent("formatted-answer.pdf")
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    // PDF font mappings can extract visually identical Kangxi radicals (e.g. ⼄).
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    for marker in ["尚未核验", "最短等待", "甲机器", "乙机器", "26分钟", "33分钟", "59", "完整结束标记"] {
      XCTAssertTrue(text.contains(marker.precomposedStringWithCompatibilityMapping), marker)
    }
    for raw in ["##", "**", "| ---", "\\times", "\\["] {
      XCTAssertFalse(text.contains(raw), raw)
    }
    if let output = ProcessInfo.processInfo.environment["MATH_FORMATTED_PDF_OUTPUT"] {
      try Data(contentsOf: url).write(to: URL(fileURLWithPath: output))
    }
    await store.close()
  }

  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func image(width: Int = 1000, height: Int = 400) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    for (index, color) in [
      CGColor(red: 1, green: 0, blue: 0, alpha: 1),
      CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1),
    ].enumerated() {
      context.setFillColor(color)
      context.fill(
        CGRect(
          x: 0, y: CGFloat(index) * CGFloat(height) / 3,
          width: CGFloat(width), height: CGFloat(height) / 3 + 1))
    }
    let bytes = NSMutableData()
    let encoder = try XCTUnwrap(
      CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(encoder, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(encoder))
    return bytes as Data
  }

  func testPracticeExportUsesArchivedPhotoAndDeduplicatesWithoutOCRorAnswers() async throws {
    let store = MathQuestionStore(directory: directory)
    let original = try image()
    let record = try await store.save(
      .init(
        captureID: "photo", imageData: original,
        ocrText: "索引文字不可印作题干", solutions: [.init(question: "解题", answer: "答案秘密", model: "test")]))
    try await store.rename(questionID: record.id, title: "四年级练习")
    let url = directory.appendingPathComponent("practice.pdf")
    let pages = try await MathQuestionPDFExporter.export(
      records: [record, record], store: store, to: url)
    let document = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertEqual(pages, 1)
    XCTAssertEqual(document.pageCount, 1)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    XCTAssertTrue(text.contains("四年级练习"))
    XCTAssertTrue(text.contains("作答区"))
    XCTAssertFalse(text.contains("索引文字"))
    XCTAssertFalse(text.contains("答案秘密"))
    let saved = try await store.originalImage(questionID: record.id)
    XCTAssertEqual(saved, original)
    await store.close()
  }

  func testLongAnswerAppendixPaginatesAndKeepsVerificationVisible() async throws {
    let store = MathQuestionStore(directory: directory)
    let primary = try await store.saveMethod(
      title: "和差问题", category: "两个未知数", instructions: "先去掉差，再平均分。")
    let visual = try await store.saveMethod(
      title: "线段图", category: "数形结合", instructions: "对齐公共部分，标注多出的段。")
    let answer = (0..<180).map { "第\($0)步：四年级解题记录保持原文。" }.joined(separator: "\n") + "\n完整回答结束标记"
    let record = try await store.save(
      .init(
        captureID: "answer", imageData: image(),
        solutions: [
          .init(
            question: "我的提示词", answer: answer, model: "测试模型", method: primary,
            visualMethods: [visual])
        ]))
    let url = directory.appendingPathComponent("answers.pdf")
    let pages = try await MathQuestionPDFExporter.export(
      records: [record], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertGreaterThan(pages, 3)
    XCTAssertEqual(document.pageCount, pages)
    XCTAssertFalse(document.page(at: 0)?.string?.contains("我的提示词") == true)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    for marker in ["尚未核验", "我的提示词", "测试模型", "第90步", "完整回答结束标记", "参考方法建议（未确认采用）：和差问题", "数形结合：线段图"] {
      XCTAssertTrue(text.contains(marker.precomposedStringWithCompatibilityMapping), marker)
    }
    await store.close()
  }

  func testPrerequisiteRefusalIsPrintedSeparatelyFromUnverifiedAnswer() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "blocked", imageData: image(), solutions: [
      .init(question: "我的提示词", answer: "正常解答保留", model: "fixture", selectionFailure: "方法前提复核未通过，本次未自动套用。整数分组前提不成立。")
    ]))
    let url = directory.appendingPathComponent("blocked-answer.pdf")
    _ = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url, options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    for marker in ["尚未核验", "正常解答保留", "自动选法记录（未套用方法）", "方法前提复核未通过", "本次未自动套用", "整数分组前提不成立"] {
      XCTAssertTrue(text.contains(marker.precomposedStringWithCompatibilityMapping), marker)
    }
    XCTAssertFalse(text.contains("参考方法建议（未确认采用）：".precomposedStringWithCompatibilityMapping))
    XCTAssertFalse(text.contains("用户已确认"))
    XCTAssertFalse(document.page(at: 0)?.string?.contains("复核未通过") == true)
    await store.close()
  }

  func testTallPhotoRetainsTopMiddleAndBottomAcrossA4Pages() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "tall", imageData: image(height: 4000)))
    let url = directory.appendingPathComponent("tall.pdf")
    let count = try await MathQuestionPDFExporter.export(records: [record], store: store, to: url)
    let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
    XCTAssertEqual(count, 3)
    XCTAssertEqual(document.numberOfPages, 3)
    // Sample the actual rendered photo at the top of every slice. The archived bitmap
    // starts blue, then green, then red: this detects missing or reversed source rows.
    for (index, channel) in [2, 1, 0].enumerated() {
      let page = try XCTUnwrap(document.page(at: index + 1))
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 596, height: 842,
          bitsPerComponent: 8, bytesPerRow: 596 * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      context.drawPDFPage(page)
      let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      let offset = (700 * 596 + 100) * 4
      XCTAssertGreaterThan(data[offset + channel], 220, "page \(index + 1)")
      XCTAssertLessThan(data[offset + (channel + 1) % 3], 70)
    }
    await store.close()
  }

  func testDeletedOrEmptySelectionCannotOverwriteDestination() async throws {
    let store = MathQuestionStore(directory: directory)
    let record = try await store.save(.init(captureID: "deleted", imageData: image()))
    let url = directory.appendingPathComponent("preserve.pdf")
    let before = Data("existing export".utf8)
    try before.write(to: url)
    try await store.delete(questionID: record.id)
    for records in [[], [record]] {
      do {
        _ = try await MathQuestionPDFExporter.export(records: records, store: store, to: url)
        XCTFail("Invalid export succeeded")
      } catch { XCTAssertEqual(try Data(contentsOf: url), before) }
    }
    await store.close()
  }

  func testLegacyIllegibleDiagramKeepsQuestionAnswerAndFollowingQuestionInPDF() async throws {
    let store = MathQuestionStore(directory: directory)
    let first = try await store.save(.init(captureID: "legacy", imageData: image(),
      solutions: [.init(id: "legacy-answer", question: "原提示词", answer: "原回答完整保留", model: "test",
        diagrams: [MathDiagramFixtures.bar])]))
    let second = try await store.save(.init(captureID: "following", imageData: image(),
      solutions: [.init(question: "后续提示词", answer: "后续回答完整保留", model: "test")]))
    // Reproduce a schema-5 snapshot accepted before renderability was checked.
    var narrow = MathDiagramFixtures.area
    narrow.facts[0].value = 1000; narrow.facts[1].value = 100
    narrow.facts[2].value = 100_000; narrow.parts = [1, 1]
    XCTAssertNoThrow(try narrow.validate())
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("questions.sqlite").path, &db), SQLITE_OK)
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, "UPDATE solution_diagrams SET diagram_json=? WHERE solution_id='legacy-answer'", -1, &statement, nil), SQLITE_OK)
    let json = String(decoding: try JSONEncoder().encode(narrow), as: UTF8.self)
    XCTAssertEqual(sqlite3_bind_text(statement, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)), SQLITE_OK)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
    sqlite3_close(db)
    let url = directory.appendingPathComponent("legacy.pdf")
    let count = try await MathQuestionPDFExporter.export(records: [first, second], store: store, to: url,
      options: .init(includeSolutions: true))
    let document = try XCTUnwrap(PDFDocument(url: url))
    XCTAssertEqual(count, 5)
    XCTAssertEqual(document.pageCount, count)
    let text = try XCTUnwrap(document.string).precomposedStringWithCompatibilityMapping
    for expected in ["原回答完整保留", "后续回答完整保留", "图解未显示", "面积分块过窄"] {
      XCTAssertTrue(text.contains(expected), expected)
    }
    await store.close()
  }
}
