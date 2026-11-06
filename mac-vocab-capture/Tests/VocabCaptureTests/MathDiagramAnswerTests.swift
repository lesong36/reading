import XCTest
@testable import VocabCapture

final class MathDiagramAnswerTests: XCTestCase {
  private func answer(_ diagrams: [MathDiagram] = [MathDiagramFixtures.bar]) throws -> String {
    let data = try JSONEncoder().encode(diagrams)
    return "可读解题步骤\n\n```math-diagrams\n{\"schemaVersion\":1,\"diagrams\":\(String(decoding: data, as: UTF8.self))}\n```"
  }
  func testParsesValidTailAndStripsMachineData() throws {
    let result = MathDiagramAnswer.parse(try answer())
    XCTAssertEqual(result.text, "可读解题步骤")
    XCTAssertEqual(result.diagrams, [MathDiagramFixtures.bar])
    XCTAssertNil(result.failure)
    XCTAssertTrue(result.hasDiagramBlock)
  }
  func testPlainEnglishAndOtherCodeFencesRemainReadable() {
    let english = "Streaming is crucial.\n```swift\nlet a = 1\n```"
    XCTAssertEqual(MathDiagramAnswer.displayText(english), english)
    XCTAssertEqual(MathDiagramAnswer.parse(english).text, english)
    XCTAssertNil(MathDiagramAnswer.parse(english).failure)
  }
  func testEveryPartialMarkerAndPayloadIsHiddenWhileStreaming() throws {
    let complete = try answer()
    let start = complete.range(of: MathDiagramAnswer.marker)!.lowerBound
    let before = String(complete[..<start])
    for length in 3...MathDiagramAnswer.marker.count {
      let partial = before + String(MathDiagramAnswer.marker.prefix(length))
      XCTAssertEqual(MathDiagramAnswer.displayText(partial), "可读解题步骤")
    }
    XCTAssertEqual(MathDiagramAnswer.displayText(complete.dropLast(15).description), "可读解题步骤")
    XCTAssertNotNil(MathDiagramAnswer.parse(String(complete.dropLast(3))).failure)
  }
  func testInvalidArithmeticIsNotDisplayedAndDoesNotEraseReadableSteps() throws {
    var wrong = MathDiagramFixtures.bar; wrong.facts[2].value = 5
    let result = MathDiagramAnswer.parse(try answer([wrong]))
    XCTAssertEqual(result.text, "可读解题步骤")
    XCTAssertTrue(result.diagrams.isEmpty)
    XCTAssertNotNil(result.failure)
  }
  func testIndependentValidDiagramsSurviveAnotherInvalidDiagramInEitherOrder() throws {
    var wrong = MathDiagramFixtures.area; wrong.facts[2].value = 181
    for diagrams in [[MathDiagramFixtures.bar, wrong], [wrong, MathDiagramFixtures.bar]] {
      let result = MathDiagramAnswer.parse(try answer(diagrams))
      XCTAssertEqual(result.diagrams, [MathDiagramFixtures.bar])
      XCTAssertNotNil(result.failure)
      XCTAssertEqual(result.text, "可读解题步骤")
    }
  }
  func testCapturedRateResponseKeepsTwoCheckedRectanglesAndRejectsInvalidComparison() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "RateRectanglePartialResponse", withExtension: "txt", subdirectory: "Fixtures"))
    let result = MathDiagramAnswer.parse(try String(contentsOf: url))
    XCTAssertEqual(result.diagrams.map(\.kind), [.area, .area])
    XCTAssertEqual(result.diagrams.last?.fact("t2")?.value, 31.5)
    XCTAssertTrue(result.failure?.contains("缺少对应关系") == true)
    XCTAssertFalse(result.diagrams.contains { $0.kind == .barComparison })
  }
  func testEnvelopeFailuresStillRejectEveryDiagramEvenWhenOneIsValid() throws {
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MathDiagramFixtures.bar)) as? [String: Any])
    for object: [String: Any] in [
      ["schemaVersion": 2, "diagrams": [valid]],
      ["schemaVersion": true, "diagrams": [valid]],
      ["schemaVersion": 1, "diagrams": [valid, valid]],
      ["schemaVersion": 1, "diagrams": [valid, valid, valid, valid]],
      ["schemaVersion": 1, "diagrams": [valid], "script": "untrusted"],
    ] {
      let data = try JSONSerialization.data(withJSONObject: object)
      let result = MathDiagramAnswer.parse("正文\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
      XCTAssertTrue(result.diagrams.isEmpty)
      XCTAssertNotNil(result.failure)
    }
  }
  func testPartialFailureDoesNotBypassComputedDisplayOrRequestedViewChecks() throws {
    let result = MathDiagramAnswer.Result(text: "正文", diagrams: [MathDiagramFixtures.bar, MathDiagramFixtures.unknown],
      failure: "图解3：原有错误", hasDiagramBlock: true)
    let completed = MathDiagramAnswer.requireComputedDisplay(result, request: "请解题")
    XCTAssertEqual(completed.diagrams, [MathDiagramFixtures.bar])
    XCTAssertTrue(completed.failure?.contains("原有错误") == true)
    XCTAssertTrue(completed.failure?.contains("未完成推导") == true)
    let requested = MathDiagramAnswer.requireViews(result, views: [.area])
    XCTAssertTrue(requested.diagrams.isEmpty)
    XCTAssertTrue(requested.failure?.contains("原有错误") == true)
    XCTAssertTrue(requested.failure?.contains("指定画法") == true)
  }
  func testMalformedOrUnsupportedIndividualEntryCannotPoisonValidNeighbor() throws {
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MathDiagramFixtures.bar)) as? [String: Any])
    var unknownField = valid; unknownField["id"] = "bad"; unknownField["script"] = "untrusted"
    var badFact = valid; badFact["id"] = "bad"; badFact["facts"] = [["id": "a", "value": 5]]
    for bad in [unknownField, badFact] {
      let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [bad, valid]])
      let result = MathDiagramAnswer.parse("正文\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
      XCTAssertEqual(result.diagrams, [MathDiagramFixtures.bar])
      XCTAssertTrue(result.failure?.hasPrefix("图解1：") == true)
    }
  }
  func testSemanticallyValidButIllegibleAreaTriggersRepairFailure() throws {
    var diagram = MathDiagramFixtures.area
    diagram.facts[0].value = 1000
    diagram.facts[1].value = 100
    diagram.facts[2].value = 100_000
    diagram.parts = [1, 1]
    XCTAssertNoThrow(try diagram.validate())
    let result = MathDiagramAnswer.parse(try answer([diagram]))
    XCTAssertEqual(result.text, "可读解题步骤")
    XCTAssertTrue(result.diagrams.isEmpty)
    XCTAssertTrue(result.failure?.contains("面积分块过窄") == true)
  }
  func testSourceLinksBeforeDiagramRemainVisible() throws {
    let sources = "检索来源：\n[1] Official release\nhttps://example.com/release\n\n"
    let result = MathDiagramAnswer.parse(sources + (try answer()))
    XCTAssertNil(result.failure)
    XCTAssertEqual(result.diagrams, [MathDiagramFixtures.bar])
    XCTAssertTrue(result.text.contains(sources.trimmingCharacters(in: .whitespacesAndNewlines)))
  }
  func testMissingUnitsAndStringValuesGiveSpecificRepairFeedback() throws {
    let encoded = try JSONEncoder().encode(MathDiagramFixtures.bar)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for missingUnit in [true, false] {
      var diagram = original
      var facts = try XCTUnwrap(diagram["facts"] as? [[String: Any]])
      if missingUnit { facts[0].removeValue(forKey: "unit") }
      else { facts[0]["value"] = "45" }
      diagram["facts"] = facts
      let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [diagram]])
      let result = MathDiagramAnswer.parse("原回答\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
      XCTAssertEqual(result.text, "原回答")
      XCTAssertTrue(result.diagrams.isEmpty)
      XCTAssertTrue(result.failure?.contains(missingUnit ? "unit 缺失" : "value 类型无效") == true)
      XCTAssertTrue(result.failure?.contains("facts.[0]") == true)
    }
  }
  func testMissingRelationOutputGivesRelationshipFeedbackInsteadOfFactFields() throws {
    let encoded = try JSONEncoder().encode(MathDiagramFixtures.bar)
    var diagram = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var relations = try XCTUnwrap(diagram["relations"] as? [[String: Any]])
    relations[0].removeValue(forKey: "outputID")
    diagram["relations"] = relations
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [diagram]])
    let result = MathDiagramAnswer.parse("原回答\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
    XCTAssertEqual(result.text, "原回答")
    XCTAssertTrue(result.diagrams.isEmpty)
    XCTAssertTrue(result.failure?.contains("relations.[0].outputID 缺失") == true)
    XCTAssertTrue(result.failure?.contains("operation、inputIDs、outputID") == true)
    XCTAssertFalse(result.failure?.contains("label、unit、origin") == true)
  }
  func testFocusedDifferenceRatioPromptsExcludeFreeFormExamplesAndPreserveQuestionScope() {
    let request = "只解第60题；按四年级方法画线段图。"
    let repair = MathDiagramAnswer.differenceRatioRepairPrompt(question: request)
    XCTAssertTrue(repair.contains(request))
    XCTAssertTrue(repair.contains("仅为本次原截图补充"))
    XCTAssertTrue(repair.contains("不重新解题"))
    XCTAssertTrue(repair.contains("尚未核验的解答"))
    XCTAssertTrue(repair.contains("只返回一个完整的结尾 ```math-diagrams 数据块"))
    for prompt in [repair, MathDiagramAnswer.differenceRatioPrompt] {
      XCTAssertTrue(prompt.contains(MathDiagramAnswer.marker))
      XCTAssertTrue(prompt.contains("difference_ratio"))
      XCTAssertTrue(prompt.contains("年龄差随年份同时变化保持不变"))
      XCTAssertTrue(prompt.contains("不把过去的倍数当作现在的倍数"))
      XCTAssertTrue(prompt.contains("不混合不同题"))
      XCTAssertFalse(prompt.contains("\"facts\":["))
      XCTAssertFalse(prompt.contains("\"relations\":["))
      XCTAssertFalse(prompt.contains("bar_comparison"))
      XCTAssertFalse(prompt.contains("\"value\":12"))
    }
    XCTAssertTrue(MathDiagramAnswer.differenceRatioPrompt.contains("逐题编号"))
    XCTAssertTrue(MathDiagramAnswer.differenceRatioPrompt.contains("不编造配方"))
    XCTAssertTrue(MathDiagramAnswer.prompt.contains("bar_comparison"))
  }
  func testRejectsUnsupportedVersionDuplicateIDsNonfinalBlocksAndUnknownCodeFields() throws {
    let valid = try answer()
    for malformed in [valid.replacingOccurrences(of: "schemaVersion\":1", with: "schemaVersion\":2"), valid + "\n尾部解释", try answer([MathDiagramFixtures.bar, MathDiagramFixtures.bar]), valid.replacingOccurrences(of: "\"kind\":", with: "\"svg\":\"<svg/>\",\"kind\":"), "步骤\n```math-diagrams\n{}\n```", "步骤\n```math-diagrams\n{\n```"] {
      let result = MathDiagramAnswer.parse(malformed)
      XCTAssertTrue(result.diagrams.isEmpty)
      XCTAssertNotNil(result.failure)
      XCTAssertFalse(result.text.contains("schemaVersion"))
    }
  }
  func testInlineMarkerDoesNotTruncateNormalAnswer() {
    let text = "可以使用 ```math-diagrams 作为数据块名字。"
    XCTAssertEqual(MathDiagramAnswer.displayText(text), text)
    XCTAssertEqual(MathDiagramAnswer.parse(text).text, text)
  }

  func testSolvingRequestsRepairAnUncomputedFigureButSchematicRequestsKeepUnknowns() {
    let unresolved = MathDiagramAnswer.Result(text: "解答", diagrams: [MathDiagramFixtures.unknown], failure: nil, hasDiagramBlock: true)
    XCTAssertNotNil(MathDiagramAnswer.requireComputedDisplay(unresolved, request: "请解题").failure)
    XCTAssertNil(MathDiagramAnswer.requireComputedDisplay(unresolved, request: "只画图示意").failure)
    XCTAssertNil(MathDiagramAnswer.requireComputedDisplay(.init(text: "解答", diagrams: [MathDiagramFixtures.bar], failure: nil, hasDiagramBlock: true), request: "请解题").failure)
  }

}
