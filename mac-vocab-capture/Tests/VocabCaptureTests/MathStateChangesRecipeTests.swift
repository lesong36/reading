import XCTest
@testable import VocabCapture

final class MathStateChangesRecipeTests: XCTestCase {
  private func quantity(_ value: Any, _ unit: String = "人", _ evidence: String) -> [String: Any] {
    ["value": value, "unit": unit, "evidence": evidence]
  }
  private func recipe() -> [String: Any] {
    ["id": "visitors", "title": "人数变化", "kind": "state_changes",
      "initial": quantity(100, "人", "原来有100人"), "changes": [
        ["direction": "decrease", "amount": quantity(30, "人", "离开30人")],
        ["direction": "increase", "amount": quantity(20, "人", "又到来20人")],
      ]]
  }
  private func replacingAmount(_ value: [String: Any]) -> [String: Any] {
    var input = recipe()
    input["changes"] = [["direction": "decrease", "amount": value]]
    return input
  }

  func testIndependentForwardOracleAndActualRendering() throws {
    let diagram = try MathStateChangesRecipe.compile(recipe())
    XCTAssertEqual(diagram.kind, .state)
    XCTAssertEqual(diagram.factIDs, ["initial", "state_1", "final"])
    XCTAssertEqual(diagram.fact("initial")?.value, 100)
    XCTAssertEqual(diagram.fact("state_1")?.value, 70)
    XCTAssertEqual(diagram.fact("final")?.value, 90) // Independent: 100 - 30 + 20.
    XCTAssertEqual(diagram.fact("initial")?.origin, .given)
    XCTAssertEqual(diagram.fact("change_1")?.origin, .given)
    XCTAssertEqual(diagram.fact("final")?.origin, .derived)
    XCTAssertEqual(diagram.relations.map(\.operation), [.difference, .sum])
    XCTAssertEqual(diagram.relations[1].inputIDs, ["state_1", "change_2"])
    try diagram.validate()
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
  }

  func testOppositeTransitionsUseOrderAndIgnoreTitle() throws {
    var input = recipe()
    input["title"] = "这是离开还是到来？标题不决定方向"
    input["changes"] = [
      ["direction": "increase", "amount": quantity(30, "人", "又到来30人")],
      ["direction": "decrease", "amount": quantity(20, "人", "离开20人")],
    ]
    let diagram = try MathStateChangesRecipe.compile(input)
    XCTAssertEqual(diagram.fact("state_1")?.value, 130)
    XCTAssertEqual(diagram.fact("final")?.value, 110)
    XCTAssertEqual(diagram.relations.map(\.operation), [.sum, .difference])
  }

  func testRecordedQualityCaseArrivalWordingCompilesWithoutFutureOrNegationGuessing() throws {
    let original = "原来有100人，先离开30人，后来又来了20人。现在有多少人？"
    var input = recipe()
    input["initial"] = quantity(100, "人", original)
    input["changes"] = [
      ["direction": "decrease", "amount": quantity(30, "人", "先离开30人")],
      ["direction": "increase", "amount": quantity(20, "人", "后来又来了20人")],
    ]
    let diagram = try MathStateChangesRecipe.compile(input)
    XCTAssertEqual(diagram.fact("final")?.value, 90)
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
    for text in ["未来20人", "本来20人", "预计来了20人", "如果来了20人", "没有来了20人", "没来20人", "离开20人"] {
      input["changes"] = [["direction": "increase", "amount": quantity(20, "人", text)]]
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(input), text)
    }
  }

  func testElementaryUnitsAndZeroRemaining() throws {
    for unit in ["人", "本", "张", "个", "只", "棵", "件", "辆"] {
      var input = recipe()
      input["initial"] = quantity(30, unit, "原来有30\(unit)")
      input["changes"] = [["direction": "decrease", "amount": quantity(30, unit, "取出30\(unit)")]]
      let diagram = try MathStateChangesRecipe.compile(input)
      XCTAssertEqual(diagram.fact("final")?.value, 0)
      XCTAssertEqual(diagram.fact("final")?.unit, unit)
      try diagram.validate()
    }
    var zero = recipe()
    zero["initial"] = quantity(0, "人", "原来有0人")
    zero["changes"] = [["direction": "increase", "amount": quantity(0, "人", "增加0人")]]
    XCTAssertEqual(try MathStateChangesRecipe.compile(zero).fact("final")?.value, 0)
  }

  func testOneThroughFiveChangesAreBounded() throws {
    for count in 1...5 {
      var input = recipe()
      input["changes"] = (0..<count).map { _ in
        ["direction": "increase", "amount": quantity(1, "人", "到来1人")]
      }
      let diagram = try MathStateChangesRecipe.compile(input)
      XCTAssertEqual(diagram.factIDs.count, count + 1)
      XCTAssertEqual(diagram.fact("final")?.value, Double(100 + count))
    }
    for count in [0, 6] {
      var input = recipe()
      input["changes"] = (0..<count).map { _ in
        ["direction": "increase", "amount": quantity(1, "人", "到来1人")]
      }
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(input))
    }
  }

  func testRejectsOppositeAmbiguousNegatedAndComparativeCitations() {
    for evidence in ["到来30人", "变化30人", "没有离开30人", "如果离开30人", "可能离开30人",
      "比昨天离开的人少30人", "离开30人又到来30人", "离开20人，到来30人", "未卖出30本"] {
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(replacingAmount(quantity(30, "人", evidence))), evidence)
    }
    var input = recipe()
    input["title"] = "离开30人"
    input["changes"] = [["direction": "decrease", "amount": quantity(30, "人", "原题30人")]]
    XCTAssertThrowsError(try MathStateChangesRecipe.compile(input))
  }

  func testRejectsInvalidNumeralsComputedUnknownSourcesAndExtraFields() {
    for source in [quantity(true, "人", "离开1人"), quantity(-30, "人", "离开-30人"),
      quantity(Double.infinity, "人", "离开30人"), quantity(Double.nan, "人", "离开30人"),
      quantity(1_000_000_001, "人", "离开1000000001人"), quantity(30.5, "人", "离开30.5人"),
      quantity(30, "人", "离开20人"), quantity(30, "人", "100-70=30人离开"),
      quantity(30, "人", "离开30人，100−30"), ["value": NSNull(), "unit": "人", "evidence": "离开多少人"],
      ["value": 30, "unit": "人", "evidence": "离开30人", "origin": "derived"],
      ["value": 30, "unit": "人", "evidence": "离开30人", "source": "computed"],
      ["value": 30, "unit": "人", "evidence": "离开30人", "inputIDs": ["final"]],
    ] {
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(replacingAmount(source)))
    }
  }

  func testRejectsMissingMixedUnsupportedUnitsAndAnyNegativeIntermediate() {
    for unit in ["", "个", "米", "千人", " 人"] {
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(replacingAmount(quantity(30, unit, "离开30人"))))
    }
    XCTAssertThrowsError(try MathStateChangesRecipe.compile(replacingAmount(["value": 30, "evidence": "离开30人"])))
    var negative = recipe()
    negative["initial"] = quantity(10, "人", "原来10人")
    // A later arrival cannot justify an impossible negative intermediate.
    XCTAssertThrowsError(try MathStateChangesRecipe.compile(negative))
    var overflow = recipe()
    overflow["initial"] = quantity(1_000_000_000, "人", "原来1000000000人")
    overflow["changes"] = [["direction": "increase", "amount": quantity(1, "人", "到来1人")]]
    XCTAssertThrowsError(try MathStateChangesRecipe.compile(overflow))
  }

  func testRejectsCallerSuppliedRelationsCycleAnswersAndChangeSigns() {
    for key in ["answer", "facts", "relations", "source"] {
      var input = recipe(); input[key] = ["initial", "final"]
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(input))
    }
    for direction in ["+", "-", "unknown", "Increase"] {
      var input = recipe()
      input["changes"] = [["direction": direction, "amount": quantity(30, "人", "离开30人")]]
      XCTAssertThrowsError(try MathStateChangesRecipe.compile(input))
    }
    var input = recipe()
    input["changes"] = [["direction": "decrease", "amount": quantity(30, "人", "离开30人"), "outputID": "initial"]]
    XCTAssertThrowsError(try MathStateChangesRecipe.compile(input))
  }

  func testTamperedProgramResultFailsExistingArithmeticValidation() throws {
    var diagram = try MathStateChangesRecipe.compile(recipe())
    let index = try XCTUnwrap(diagram.facts.firstIndex { $0.id == "final" })
    diagram.facts[index].value = 91
    XCTAssertThrowsError(try diagram.validate())
  }
}
