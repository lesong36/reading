import XCTest
@testable import VocabCapture

final class MathStructuredSolutionTests: XCTestCase {
  func testRecordedSurplusBarKeepsOriginalRecipientCountAndIndependentTotals() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "surplus-and-shortfall" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "recorded-" + skill.version, title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    let file = try XCTUnwrap(Bundle.module.url(forResource: "real-surplus-bar-20261015", withExtension: "json", subdirectory: "Fixtures"))
    let result = MathStructuredSolution.parse(try String(contentsOf: file), candidates: [method], rendererTools: true)
    XCTAssertNil(result.failure); XCTAssertEqual(result.method, method)
    let checked = MathDiagramAnswer.parse(result.answer)
    XCTAssertNil(checked.failure)
    let diagram = try XCTUnwrap(checked.diagrams.first)
    XCTAssertEqual(diagram.kind, .barComparison)
    for value in [25.0, 50, 625, 675] {
      XCTAssertTrue(diagram.facts.contains { $0.origin == .derived && $0.value == value }, "Missing independent \(value)")
    }
    XCTAssertTrue(diagram.facts.contains { $0.origin == .given && $0.value == 2 && $0.unit == "人" })
    XCTAssertGreaterThan(try MathDiagramRenderer.renderPNG(diagram).count, 1000)
  }

  func testRecordedNumericHandlesBindExactDifferenceAndVisualSnapshots() throws {
    let catalogue = try MathSkillCatalogue.load()
    let names = ["multiplicative-scaling", "difference-and-ratio", "sum-and-difference", "age-invariants",
      "sum-and-ratio", "comparison-line-diagram", "ratio-parts-diagram"]
    let candidates = try names.map { name -> MathTeachingMethod in
      let skill = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      return MathTeachingMethod(id: skill.sourceID, versionID: "recorded-" + skill.version, title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let file = try XCTUnwrap(Bundle.module.url(forResource: "real-difference-ratio-numeric-handles-20261015", withExtension: "json", subdirectory: "Fixtures"))
    let result = MathStructuredSolution.parse(try String(contentsOf: file), candidates: candidates, rendererTools: true)
    XCTAssertNil(result.failure)
    XCTAssertEqual(result.method, candidates[1]); XCTAssertEqual(result.visualMethods, [candidates[5]])
    let checked = MathDiagramAnswer.parse(result.answer)
    XCTAssertNil(checked.failure)
    XCTAssertEqual(checked.diagrams.first?.kind, .equalParts)
    XCTAssertTrue(checked.diagrams.flatMap(\.facts).contains { $0.origin == .derived && $0.value == 8 })
  }

  func testRendererHandlesRestoreExactSnapshotsAndDoNotChangeOldProtocols() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "comparison-line-diagram" })
    let method = MathTeachingMethod(id: String(repeating: "opaque-hash", count: 8), versionID: "immutable-v3",
      title: "自定义方法", category: "用户", instructions: "原题条件满足时采用完整用户方法。", createdAt: Date())
    let visual = MathTeachingMethod(id: skill.sourceID, versionID: "visual-v1", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    let candidates = [method, visual]
    let prompt = MathStructuredSolution.prompt("解题", candidates: candidates, singleSubmission: true, rendererTools: true)
    XCTAssertTrue(prompt.contains("id:0\nroles:solution"))
    XCTAssertTrue(prompt.contains("id:1\nroles:visual"))
    XCTAssertFalse(prompt.contains(method.id)); XCTAssertFalse(prompt.contains(visual.id))
    XCTAssertTrue(prompt.contains(method.instructions)); XCTAssertTrue(prompt.contains(visual.instructions))
    let old = MathStructuredSolution.prompt("解题", candidates: candidates, singleSubmission: true)
    XCTAssertTrue(old.contains("id:" + method.id))
    func parse(_ primary: Any, _ visuals: [String], renderer: Bool = true) throws -> MathSinglePassSolution.Result {
      let value: [String: Any] = ["schemaVersion": 1, "mode": "general", "answer": "原图条件暂缺。",
        "method_id": primary, "visual_method_ids": visuals, "diagrams": []]
      return MathStructuredSolution.parse(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self),
        candidates: candidates, rendererTools: renderer)
    }
    let restored = try parse("0", ["1"])
    XCTAssertNil(restored.failure); XCTAssertEqual(restored.method, method); XCTAssertEqual(restored.visualMethods, [visual])
    XCTAssertEqual(try parse(method.id, [visual.id]).method, method, "Recorded full-ID replies stay readable")
    XCTAssertNotNil(try parse("0", ["1"], renderer: false).failure)
    XCTAssertNotNil(try parse("9", []).failure)
    XCTAssertNotNil(try parse("1", []).failure, "A visual handle cannot become the primary solution")
    XCTAssertNotNil(try parse("0", ["1", visual.id]).failure, "Aliases cannot conceal duplicate adoption")
  }

  func testRendererHandlesNeverCollideWithRealMethodIdentities() throws {
    let candidate = MathTeachingMethod(id: "0", versionID: "immutable", title: "用户方法", category: "用户",
      instructions: "核对原题全部条件。", createdAt: Date())
    let prompt = MathStructuredSolution.prompt("解题", candidates: [candidate], singleSubmission: true, rendererTools: true)
    XCTAssertTrue(prompt.contains("id:m0\n"))
    for identifier in ["0", "m0"] {
      let value: [String: Any] = ["schemaVersion": 1, "mode": "general", "answer": "核对条件。", "method_id": identifier,
        "visual_method_ids": [], "diagrams": []]
      let result = MathStructuredSolution.parse(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self),
        candidates: [candidate], rendererTools: true)
      XCTAssertNil(result.failure); XCTAssertEqual(result.method, candidate)
    }
  }

  func testRendererPromptKeepsFullCandidatesAndNullableMethodsWithoutOldResultContract() {
    let candidate = MathTeachingMethod(id: "local", versionID: "local-v1", title: "用户方法", category: "自定义", instructions: "原题前提齐全才采用，缺失时拒绝。", createdAt: Date())
    let text = MathStructuredSolution.prompt("解答所有题", candidates: [candidate], requireDiagram: true, singleSubmission: true, rendererTools: true)
    XCTAssertTrue(text.hasPrefix(MathStructuredSolution.rendererRequestPrefix))
    XCTAssertTrue(text.contains(candidate.instructions))
    XCTAssertTrue(text.contains("null")); XCTAssertTrue(text.contains("包含多道题"))
    XCTAssertFalse(text.contains("submit_math_solution")); XCTAssertFalse(text.contains("mode保持"))
    let system = ScreenshotQuestionInstructions.forMathRendererTools(ScreenshotQuestionInstructions.text)
    XCTAssertTrue(system.contains("submit_general_math_solution"))
    XCTAssertFalse(system.contains("diagram_outcome")); XCTAssertFalse(system.contains("submit_math_solution"))
  }
  func testDiagramUnionDoesNotReplaceResponseEnvelopeOrConflateRecipeWithGenericFields() {
    let contract = MathStructuredSolution.diagramContract(views: [.table])
    XCTAssertFalse(contract.contains("使用严格 JSON 对象"))
    XCTAssertFalse(contract.contains("每个图解对象字段"))
    XCTAssertTrue(contract.contains("这些字段只适用于quantity_plan"))
    for kind in ["difference_ratio", "two_allocations", "purchase_comparison", "return_deadline"] {
      XCTAssertTrue(contract.contains(kind))
    }
  }
  func testSubmissionPromptUsesToolOutcomeWithoutCompetingJSONEnvelope() {
    let prompt = MathStructuredSolution.prompt("解题", candidates: [], requireDiagram: true, singleSubmission: true)
    XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.submissionRequestPrefix))
    for field in ["submit_math_solution", "primary_diagram", "additional_diagrams", "unreadable_or_insufficient", "no_helpful_diagram", "user_requested_text_only", "null"] {
      XCTAssertTrue(prompt.contains(field))
    }
    XCTAssertFalse(prompt.contains("六项"))
    XCTAssertFalse(prompt.contains("严格JSON对象"))
    XCTAssertFalse(prompt.contains("diagrams:"))
    for kind in MathStructuredSolution.nativeRecipeKinds {
      XCTAssertTrue(MathStructuredSolution.submissionDiagramContract.contains(kind))
    }
    XCTAssertTrue(MathStructuredSolution.prompt("解题", candidates: []).hasPrefix(MathStructuredSolution.requestPrefix))
  }

  func testSubmissionKeepsFullCandidateSnapshotAndRolePolicy() {
    let body = "仅当原图前提齐全时采用。" + String(repeating: "不要把例题条件当本题已知。", count: 250)
    let candidate = MathTeachingMethod(id: "local-method", versionID: "immutable-local-version", title: "用户方法", category: "自定义", instructions: body, createdAt: Date())
    let prompt = MathStructuredSolution.prompt("解题", candidates: [candidate], singleSubmission: true)
    XCTAssertTrue(prompt.contains("id:local-method"))
    XCTAssertTrue(prompt.contains("roles:"))
    XCTAssertTrue(prompt.contains(body))
  }

  private func recipe() throws -> Any {
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(Bundle.module.url(
      forResource: "real-purchase-offers-20261013", withExtension: "json", subdirectory: "Fixtures")))) as? [String: Any])
    return try XCTUnwrap((envelope["diagrams"] as? [[String: Any]])?.first)
  }
  private func response(mode: String = "native_recipe", text: String = "按原题优惠分别算付款再比较。", diagrams: [Any]? = nil,
    primary: Any = NSNull(), version: Any = 1) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["schemaVersion": version,
      "mode": mode, "method_id": primary, "visual_method_ids": [], "answer": text,
      "diagrams": try diagrams ?? [recipe()]]), as: UTF8.self)
  }
  func testNativeRecipeIsPassedThroughFullArithmeticAndRenderingChecks() throws {
    let result = MathStructuredSolution.parse(try response(), candidates: [])
    XCTAssertNil(result.failure); XCTAssertNil(result.method)
    let checked = MathDiagramAnswer.parse(result.answer)
    XCTAssertNil(checked.failure); XCTAssertEqual(checked.diagrams.count, 1)
    let text = try MathCheckedDiagramExplanation.text(for: XCTUnwrap(checked.diagrams.first))
    for value in ["2505", "2616", "111"] { XCTAssertTrue(text.contains(value)) }
  }
  func testGeneralModeKeepsUnknownAndUnsupportedQuestionsUsable() throws {
    let result = MathStructuredSolution.parse(try response(mode: "general", text: "原图缺少总量，无法确定人数。", diagrams: []), candidates: [])
    XCTAssertNil(result.failure); XCTAssertEqual(result.answer, "原图缺少总量，无法确定人数。")
    XCTAssertTrue(MathDiagramAnswer.parse(result.answer).diagrams.isEmpty)
  }
  func testRendererOmissionIsTypedSeparateFromProseAndCannotHideInvalidNativeDiagram() throws {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try response(mode: "general", text: "图解说明：此题当前没有帮助理解的受支持图。", diagrams: []).utf8)) as? [String: Any])
    value["diagram_omission"] = ["status": "no_helpful_diagram", "reason": "此题当前没有帮助理解的受支持图。"]
    func encode() throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    let result = MathStructuredSolution.parse(try encode(), candidates: [], rendererTools: true)
    XCTAssertNil(result.failure); XCTAssertEqual(result.diagramOmissionReason, "此题当前没有帮助理解的受支持图。")
    XCTAssertNotNil(MathStructuredSolution.parse(try encode(), candidates: []).failure, "V1/V2 must not accept the new field")
    value.removeValue(forKey: "diagram_omission")
    XCTAssertNil(MathStructuredSolution.parse(try encode(), candidates: [], rendererTools: true).diagramOmissionReason, "Prose is not an omission policy")
    value["diagram_omission"] = ["status": "no_helpful_diagram", "reason": ""]
    XCTAssertNotNil(MathStructuredSolution.parse(try encode(), candidates: [], rendererTools: true).failure)
    value["diagram_omission"] = ["status": "no_helpful_diagram", "reason": "不画图"]
    value["mode"] = "native_recipe"; value["diagrams"] = [try recipe()]
    XCTAssertNotNil(MathStructuredSolution.parse(try encode(), candidates: [], rendererTools: true).failure)
  }
  func testRendererFailedDiagramKeepsIndependentAnswerWithoutAuthorizingOmission() throws {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try response(mode: "general", text: "按原题逐边核对，路径是E→F→G→H→I→E→G。", diagrams: []).utf8)) as? [String: Any])
    value["diagram_submission_failure"] = "submission_shape"
    let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    let result = MathStructuredSolution.parse(json, candidates: [], rendererTools: true)
    XCTAssertTrue(result.answer.contains("E→F→G")); XCTAssertNil(result.failure)
    XCTAssertNil(result.diagramOmissionReason); XCTAssertNotNil(result.diagramSubmissionFailure)
    XCTAssertNotNil(MathStructuredSolution.parse(json, candidates: []).failure)
    for issue in ["submission_inline_grid", "submission_inline_geometry", "submission_inline_cube"] {
      value["diagram_submission_failure"] = issue
      let payload = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
      let failure = MathStructuredSolution.parse(payload, candidates: [], rendererTools: true)
      XCTAssertTrue(failure.answer.contains("E→F→G"))
      XCTAssertNil(failure.failure)
      XCTAssertNotNil(failure.diagramSubmissionFailure)
    }
    value["diagram_submission_failure"] = "DO_NOT_DISPLAY_RAW_PROVIDER_VALUE"
    let bad = MathStructuredSolution.parse(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), candidates: [], rendererTools: true)
    XCTAssertNotNil(bad.failure); XCTAssertNil(bad.diagramSubmissionFailure)
    XCTAssertNil(MathSolutionSubmissionError(issue: "DO_NOT_DISPLAY_RAW_PROVIDER_VALUE"))
  }
  func testSchemaErrorsPreserveReadableAnswerWithoutInventingMethodOrRepair() throws {
    for source in [try response(mode: "guessed"), try response(version: true),
      try response(diagrams: []),
      try response(diagrams: [["id":"x", "kind":"quantity_plan"]])] {
      let result = MathStructuredSolution.parse(source, candidates: [])
      XCTAssertNotNil(result.failure); XCTAssertNil(result.method)
      XCTAssertFalse(result.answer.hasPrefix("{")); XCTAssertFalse(result.answer.contains("math-diagrams"))
    }
  }
  func testReadableCitationsDoNotDiscardIndependentlyValidNativeDiagram() throws {
    let text = "按原题分别计算后比较。\n\n检索来源：" + String(repeating:"来源说明", count:40)
    let result = MathStructuredSolution.parse(try response(text:text), candidates:[])
    XCTAssertNil(result.failure)
    XCTAssertTrue(result.answer.hasPrefix(text))
    XCTAssertEqual(MathDiagramAnswer.parse(result.answer).diagrams.count,1)
  }
  func testUnknownMethodDoesNotDiscardIndependentValidRecipe() throws {
    let result = MathStructuredSolution.parse(try response(primary: "invented"), candidates: [])
    XCTAssertNotNil(result.failure); XCTAssertNil(result.method)
    XCTAssertEqual(MathDiagramAnswer.parse(result.answer).diagrams.count, 1)
  }
  func testBadArithmeticIsNotAcceptedMerelyBecauseEnvelopeMatches() throws {
    var entry = try XCTUnwrap(recipe() as? [String: Any])
    entry["required_count"] = ["value": -1, "evidence":"负数"]
    let result = MathStructuredSolution.parse(try response(diagrams: [entry]), candidates: [])
    let checked = MathDiagramAnswer.parse(result.answer)
    XCTAssertNotNil(checked.failure); XCTAssertTrue(checked.diagrams.isEmpty)
  }
  func testMalformedJSONAndExtraFieldsDoNotExposeRawProtocolToUser() throws {
    XCTAssertNotNil(MathStructuredSolution.parse("{unfinished", candidates: []).failure)
    XCTAssertFalse(MathStructuredSolution.parse("{unfinished", candidates: []).answer.hasPrefix("{"))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try response().utf8)) as? [String: Any])
    object["verified"] = true
    XCTAssertNotNil(MathStructuredSolution.parse(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), candidates: []).failure)
    XCTAssertEqual(MathStructuredSolution.displayText("{\"answer\":\"partial"), "")
  }
}
