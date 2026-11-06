import XCTest
@testable import VocabCapture

final class MathDiagramRecipeTests: XCTestCase {
  private func recipe(difference: Double = 72, multiplier: Double = 10, unit: String = "") -> [String: Any] {
    ["id": "ratio", "title": "差数对应多出的份数", "kind": "difference_ratio",
      "difference": ["value": difference, "unit": unit, "evidence": "原题说较大量比较小量多\(difference)\(unit)"],
      "multiplier": ["value": multiplier, "evidence": "原题说较大量是较小量的\(multiplier)倍"]]
  }
  private func compile(_ recipe: [String: Any]) throws -> MathDiagram {
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [recipe]])
    let normalized = try MathDiagramRecipe.normalizedEnvelope(data)
    struct Envelope: Decodable { let diagrams: [MathDiagram] }
    return try JSONDecoder().decode(Envelope.self, from: normalized).diagrams[0]
  }

  func testDifferenceRatioUsesOnlyOriginalConditionsAndGroundedDerivations() throws {
    let diagram = try compile(recipe())
    XCTAssertEqual(diagram.kind, .equalParts)
    XCTAssertEqual(diagram.parts, [1, 10, 9])
    XCTAssertEqual(diagram.fact("smaller")?.value, 8)
    XCTAssertEqual(diagram.fact("larger")?.value, 80)
    XCTAssertEqual(diagram.fact("extra_parts")?.origin, .derived)
    XCTAssertEqual(diagram.fact("extra_parts")?.value, 9)
    XCTAssertEqual(diagram.facts.filter { $0.origin == .given }.map(\.id), ["difference", "multiplier"])
    XCTAssertEqual(diagram.facts.filter { $0.origin == .constant }.map(\.value), [1])
    XCTAssertTrue(diagram.facts.filter { $0.origin == .constant }.allSatisfy { $0.unit.isEmpty })
    try MathDiagramAnswer.validateRendering(diagram)
  }

  func testRecordedMissingTrailingZeroUsesDecimalRuleRatherThanInventedGivenTen() throws {
    var item = recipe(difference: 40005)
    item["multiplier"] = ["value": 10, "unit": "倍", "evidence": "在得数末尾少添了一个0"]
    let diagram = try compile(item)
    XCTAssertEqual(diagram.fact("multiplier")?.origin, .constant)
    XCTAssertEqual(diagram.fact("larger")?.value, 44450)
    XCTAssertEqual(diagram.fact("smaller")?.value, 4445)
    XCTAssertEqual(diagram.fact("difference")?.origin, .given)
    try MathDiagramAnswer.validateRendering(diagram)
    XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
    for evidence in ["在得数末尾少添了两个0", "在得数中间少添了一个0", "小数的末尾少添了一个0", "没有在得数末尾少添了一个0", "在得数末尾少添了一个0，多添了一个0"] {
      item["multiplier"] = ["value": 10, "evidence": evidence]
      XCTAssertThrowsError(try compile(item), evidence)
    }
    item["multiplier"] = ["value": 2, "evidence": "在得数末尾少添了一个0"]
    XCTAssertThrowsError(try compile(item))
  }

  func testDifferentRatiosUnitsExactDecimalsAndBoundaryCases() throws {
    for (difference, multiplier, unit, smaller) in [
      (12.0, 3.0, "人", 6.0), (19.0, 20.0, "本", 1.0),
      (0.0, 2.0, "", 0.0), (0.125, 2.0, "米", 0.125),
      (1.0, 6.0, "千克", 0.2), (0.000001, 2.0, "", 0.000001),
    ] {
      let diagram = try compile(recipe(difference: difference, multiplier: multiplier, unit: unit))
      XCTAssertEqual(diagram.fact("smaller")?.value, smaller)
      XCTAssertEqual(diagram.fact("difference")?.unit, unit)
      XCTAssertEqual(diagram.parts, [1, Int(multiplier), Int(multiplier - 1)])
      try MathDiagramAnswer.validateRendering(diagram)
    }
  }

  func testOptionalMultiplierUnitAcceptsOnlyDimensionlessStringsAndNormalizesThem() throws {
    let original = try compile(recipe())
    for unit in ["", "倍", " \n\t", " 倍 "] {
      var item = recipe()
      var multiplier = try XCTUnwrap(item["multiplier"] as? [String: Any])
      multiplier["unit"] = unit
      item["multiplier"] = multiplier
      let diagram = try compile(item)
      XCTAssertEqual(diagram, original)
      XCTAssertEqual(diagram.fact("multiplier")?.unit, "")
      XCTAssertEqual(diagram.fact("extra_parts")?.unit, "")
      try MathDiagramAnswer.validateRendering(diagram)
    }
    for unit: Any in ["岁", "人", "份", "倍/岁", "1", 3, true, NSNull(), [], ["unit": "倍"]] {
      var item = recipe()
      var multiplier = try XCTUnwrap(item["multiplier"] as? [String: Any])
      multiplier["unit"] = unit
      item["multiplier"] = multiplier
      XCTAssertThrowsError(try compile(item))
    }
  }

  func testRejectsUnsupportedNumbersAndDoesNotRoundComputedValues() {
    for (difference, multiplier, unit) in [
      (-1.0, 10.0, ""), (1_000_000_001.0, 10.0, ""),
      (72.0, 1.0, ""), (72.0, 21.0, ""), (72.0, 2.5, ""),
      (1.0, 4.0, ""), (1.0, 3.0, "人"),
      (0.000001, 3.0, ""), (1_000_000_000.0, 2.0, ""),
    ] {
      XCTAssertThrowsError(try compile(recipe(difference: difference, multiplier: multiplier, unit: unit)))
    }
    // Foundation's JSON writer can raise an Objective-C exception for nonfinite values.
    // Exercise the incoming model payload instead of attempting to serialize them.
    for value in ["1e309", "-1e309", "NaN", "Infinity"] {
      for key in ["difference", "multiplier"] {
        let difference = key == "difference" ? value : "72"
        let multiplier = key == "multiplier" ? value : "10"
        let json = """
          {"schemaVersion":1,"diagrams":[{"id":"ratio","title":"差倍图","kind":"difference_ratio","difference":{"value":\(difference),"unit":"","evidence":"原题差数"},"multiplier":{"value":\(multiplier),"evidence":"原题倍数"}}]}
          """
        let result = MathDiagramAnswer.parse("原回答\n```math-diagrams\n\(json)\n```")
        XCTAssertEqual(result.text, "原回答")
        XCTAssertTrue(result.diagrams.isEmpty)
        XCTAssertNotNil(result.failure)
      }
    }
  }

  func testRejectsInventedRolesComputedValuesMissingConditionsAndExtraFields() {
    var invalid: [[String: Any]] = []
    var top = recipe(); top["facts"] = []; invalid.append(top)
    top = recipe(); top["smaller"] = 8; invalid.append(top)
    top = recipe(); top["id"] = ""; invalid.append(top)
    top = recipe(); top["title"] = ""; invalid.append(top)
    for key in ["difference", "multiplier"] {
      for field in ["origin", "answer", "rule"] {
        var item = recipe(); var nested = item[key] as! [String: Any]
        nested[field] = "given"; item[key] = nested; invalid.append(item)
      }
      for evidence in ["", String(repeating: "原", count: 501)] {
        var item = recipe(); var nested = item[key] as! [String: Any]
        nested["evidence"] = evidence; item[key] = nested; invalid.append(item)
      }
      var item = recipe(); item.removeValue(forKey: key); invalid.append(item)
      item = recipe(); var nested = item[key] as! [String: Any]
      nested["value"] = "72"; item[key] = nested; invalid.append(item)
      item = recipe(); nested = item[key] as! [String: Any]
      nested["value"] = true; item[key] = nested; invalid.append(item)
    }
    for item in invalid { XCTAssertThrowsError(try compile(item)) }
  }

  func testOrdinaryDiagramsRemainByteIdenticalIncludingInvalidFactRoles() throws {
    let data = Data("{\"schemaVersion\":1,\"diagrams\":[{\"kind\":\"equal_parts\",\"facts\":[{\"value\":9,\"origin\":\"constant\"}]}]}".utf8)
    XCTAssertEqual(try MathDiagramRecipe.normalizedEnvelope(data), data)
  }

  func testRejectsOverflowInOrdinaryDiagramInsideMixedEnvelopeBeforeWritingJSON() throws {
    let ordinary = String(decoding: try JSONEncoder().encode(compile(recipe())), as: UTF8.self)
      .replacingOccurrences(of: "\"value\":72", with: "\"value\":1e309")
    XCTAssertTrue(ordinary.contains("1e309"))
    let recipeJSON = String(decoding: try JSONSerialization.data(withJSONObject: recipe()), as: UTF8.self)
    let json = "{\"schemaVersion\":1,\"diagrams\":[\(recipeJSON),\(ordinary)]}"
    XCTAssertThrowsError(try MathDiagramRecipe.normalizedEnvelope(Data(json.utf8)))
    let result = MathDiagramAnswer.parse("原回答\n```math-diagrams\n\(json)\n```")
    XCTAssertEqual(result.text, "原回答")
    XCTAssertTrue(result.diagrams.isEmpty)
    XCTAssertNotNil(result.failure)
  }

  func testTerminalRecipeIsRenderedAsOrdinaryDiagramAndRetainsEnvelopeChecks() throws {
    func parse(_ envelope: [String: Any]) throws -> MathDiagramAnswer.Result {
      let data = try JSONSerialization.data(withJSONObject: envelope)
      return MathDiagramAnswer.parse("保留解题正文\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
    }
    let diagram = try compile(recipe())
    let result = try parse(["schemaVersion": 1, "diagrams": [recipe()]])
    XCTAssertEqual(result.text, "保留解题正文")
    XCTAssertEqual(result.diagrams, [diagram])
    XCTAssertNil(result.failure)
    XCTAssertTrue(result.hasDiagramBlock)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
    var ordinary = encoded; ordinary["id"] = "ordinary"
    let mixed = try parse(["schemaVersion": 1, "diagrams": [recipe(), ordinary]])
    XCTAssertEqual(mixed.diagrams.count, 2)
    XCTAssertNil(mixed.failure)
    let invalidEnvelopes: [[String: Any]] = [
      ["schemaVersion": 2, "diagrams": [recipe()]],
      ["schemaVersion": 1, "diagrams": [recipe(), encoded]],
      ["schemaVersion": 1, "diagrams": [recipe()], "script": "draw()"],
      ["schemaVersion": 1, "diagrams": Array(repeating: recipe(), count: 4)],
    ]
    for envelope in invalidEnvelopes {
      let invalid = try parse(envelope)
      XCTAssertEqual(invalid.text, "保留解题正文")
      XCTAssertTrue(invalid.diagrams.isEmpty)
      XCTAssertNotNil(invalid.failure)
    }
  }

  func testAgeDifferenceAcrossYearsAndSeparateNumberQuestionProduceIndependentDiagrams() throws {
    var age = recipe(difference: 30, multiplier: 3, unit: "岁")
    age["id"] = "question60"
    age["title"] = "今年爸爸和孩子的年龄"
    age["difference"] = ["value": 30, "unit": "岁",
      "evidence": "原题去年爸爸比孩子大30岁；今年仍是同一两人，两人同时增长一岁，年龄差不变。"]
    age["multiplier"] = ["value": 3, "evidence": "原题今年爸爸的年龄是孩子的3倍。"]
    var number = recipe(difference: 810, multiplier: 10)
    number["id"] = "question61"
    number["title"] = "乘十后的数和原数"
    number["difference"] = ["value": 810, "unit": "", "evidence": "第61题原数乘十后的数比原数大810。"]
    number["multiplier"] = ["value": 10, "evidence": "第61题原数乘十。"]
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [age, number]])
    let result = MathDiagramAnswer.parse("第60题：比较今年的年龄。\n第61题：求原来的数。\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
    XCTAssertNil(result.failure)
    XCTAssertEqual(result.diagrams.map(\.id), ["question60", "question61"])
    XCTAssertEqual(result.diagrams[0].fact("smaller")?.value, 15)
    XCTAssertEqual(result.diagrams[0].fact("larger")?.value, 45)
    XCTAssertEqual(result.diagrams[0].fact("difference")?.unit, "岁")
    XCTAssertTrue(result.diagrams[0].fact("difference")?.evidence?.contains("年龄差不变") == true)
    XCTAssertEqual(result.diagrams[1].fact("smaller")?.value, 90)
    XCTAssertEqual(result.diagrams[1].fact("larger")?.value, 900)
    XCTAssertEqual(result.diagrams[1].fact("difference")?.unit, "")
    for diagram in result.diagrams { try MathDiagramAnswer.validateRendering(diagram) }
  }

  func testMissingRecipeFieldsGiveRecipeSpecificFeedback() throws {
    for (objectKey, field, expected) in [("difference", "unit", "value、unit、evidence"),
      ("multiplier", "evidence", "value、evidence")] {
      var item = recipe()
      var object = try XCTUnwrap(item[objectKey] as? [String: Any])
      object.removeValue(forKey: field)
      item[objectKey] = object
      let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [item]])
      let result = MathDiagramAnswer.parse("正文\n```math-diagrams\n\(String(decoding: data, as: UTF8.self))\n```")
      XCTAssertTrue(result.diagrams.isEmpty)
      XCTAssertTrue(result.failure?.contains("\(objectKey).\(field) 缺失") == true)
      XCTAssertTrue(result.failure?.contains(expected) == true)
      XCTAssertFalse(result.failure?.contains("label、unit、origin") == true)
    }
  }
}
