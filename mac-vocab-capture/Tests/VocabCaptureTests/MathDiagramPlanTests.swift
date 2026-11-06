import AppKit
import XCTest
@testable import VocabCapture

/// These inputs omit computed answers. Gold quantities come from independently fixed
/// examples, so a plan that merely trusts model-supplied results cannot pass.
final class MathDiagramPlanTests: XCTestCase {
  func testOriginalValueMustAppearAsCompleteNumeralInItsCitation() throws {
    for (value, evidence) in [(31.5, "由630米除以每分钟20米得到"), (21, "原题121分钟"),
      (5, "原题31.5分钟"), (3, "原题负三分钟"), (30, "三百分钟")] {
      var entry = source("given", value, unit: "分钟")
      entry["evidence"] = evidence
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([entry, operation("result", "equal", ["given"])]))) { error in
        XCTAssertTrue(error.localizedDescription.contains("原题数值来源"))
      }
    }
    for (value, evidence) in [(31.5, "原题三十一点五分钟"), (21, "原题二十一分钟"),
      (2, "原题两分钟"), (0, "原题零分钟"), (-3.5, "原题负三点五分钟"),
      (31.5, "原题３１．５分钟"), (1000, "原题1e3分钟"), (-3.5, "原题−3.5分钟")] {
      var entry = source("given", value, unit: "分钟")
      entry["evidence"] = evidence
      XCTAssertEqual(try MathDiagramPlan.compile(table([entry, operation("result", "equal", ["given"])])).fact("result")?.value, value)
    }
  }

  func testSecondReturnTripDiagramRecomputesRatherThanCopiesAnAnswer() throws {
    // Actual failed second diagram: the citation contains only the calculation
    // inputs. It cannot turn a calculated 31.5 into an original quantity.
    var copied = source("returnTime2", 31.5, unit: "分钟")
    copied["evidence"] = "由630米除以每分钟20米得到"
    let limit = source("limit", 45, unit: "分钟")
    let outTime = source("outTime2", 21, unit: "分钟")
    let tail = [operation("totalTime", "sum", ["outTime2", "returnTime2"]), limit,
      operation("excess", "difference", ["totalTime", "limit"])]
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([outTime, copied] + tail, output: "excess")))

    let inputs = [outTime, source("outSpeed", 30, unit: "米/分钟"),
      source("returnSpeed", 20, unit: "米/分钟"),
      operation("distance", "product", ["outSpeed", "outTime2"]),
      operation("returnTime2", "quotient", ["distance", "returnSpeed"])]
    let compiled = try MathDiagramPlan.compile(table(inputs + tail, output: "excess"))
    for (id, expected) in [("distance", 630.0), ("returnTime2", 31.5), ("totalTime", 52.5), ("excess", 7.5)] {
      XCTAssertEqual(compiled.fact(id)?.value, expected)
      XCTAssertEqual(compiled.fact(id)?.origin, .derived)
    }
  }

  func testPreviouslySavedDiagramRemainsReadableWithoutNewPlanCitationRules() throws {
    // Old saved data is an already compiled MathDiagram, not a new input plan.
    // Preserve its readable history without silently rewriting original roles.
    let saved = MathDiagram(id: "saved", title: "旧图解", kind: .table,
      facts: [.init(id: "given", label: "旧回程时间", value: 31.5, unit: "分钟", origin: .given,
        evidence: "由630米除以每分钟20米得到"),
        .init(id: "result", label: "时间", value: 31.5, unit: "分钟", origin: .derived)],
      relations: [.init(operation: .equal, inputIDs: ["given"], outputID: "result")],
      columns: ["时间"], rows: [.init(label: "回程", factIDs: ["result"])])
    let reopened = try JSONDecoder().decode(MathDiagram.self, from: JSONEncoder().encode(saved))
    try reopened.validate()
    XCTAssertEqual(reopened.fact("given")?.origin, .given)
    XCTAssertEqual(reopened.fact("given")?.value, 31.5)
  }

  @MainActor
  func testMultiplicationRectanglesAcceptEitherProductOrderAndBothInverseDirections() throws {
    // The area skill covers rates as well as physical lengths. Computed answers
    // are omitted so compilation must derive them from the original quantities.
    for (unitA, unitB) in [("米/分钟", "分钟"), ("元/个", "个"), ("棵/小时", "小时"), ("厘米", "厘米")] {
      for variant in 0..<4 {
        var quantities: [[String: Any]]
        if variant < 2 {
          quantities = [source("a", 20, unit: unitA), source("b", 3, unit: unitB),
            operation("total", "product", variant == 0 ? ["a", "b"] : ["b", "a"])]
        } else {
          let totalUnit = try MathDiagram.inferredUnit(.product, inputs: [unitA, unitB])
          quantities = [source("total", 60, unit: totalUnit)]
          quantities += variant == 2
            ? [source("a", 20, unit: unitA), operation("b", "quotient", ["total", "a"])]
            : [source("b", 3, unit: unitB), operation("a", "quotient", ["total", "b"])]
        }
        let input: [String: Any] = ["id": "rectangle", "title": "两因素与乘积", "kind": "quantity_plan", "view": "area",
          "quantities": quantities, "layout": ["length": "a", "width": "b", "area": "total"]]
        let diagram = try MathDiagramPlan.compile(input)
        XCTAssertEqual(diagram.fact("a")?.value, 20)
        XCTAssertEqual(diagram.fact("b")?.value, 3)
        XCTAssertEqual(diagram.fact("total")?.value, 60)
        XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)
        var wrong = diagram
        wrong.facts[try XCTUnwrap(wrong.facts.firstIndex { $0.id == "total" })].value = 61
        XCTAssertThrowsError(try wrong.validate(), "Inverse acceptance must still check arithmetic")
        wrong = diagram
        wrong.facts[try XCTUnwrap(wrong.facts.firstIndex { $0.id == "total" })].unit = "秒"
        XCTAssertThrowsError(try wrong.validate(), "Inverse acceptance must still check dimensions")
      }
    }
  }

  func testMinuteAbbreviationsCancelInRateAndTimeProducts() throws {
    for rate in ["米/分", "米/min", "米/分钟"] {
      let distanceUnit = try MathDiagram.inferredUnit(.product, inputs: [rate, "分钟"])
      XCTAssertEqual(distanceUnit, "m")
      XCTAssertEqual(try MathDiagram.inferredUnit(.quotient, inputs: [distanceUnit, rate]), "分钟")
    }
    XCTAssertThrowsError(try MathDiagram.inferredUnit(.sum, inputs: ["分钟", "秒"]))
    XCTAssertThrowsError(try MathDiagram.inferredUnit(.sum, inputs: ["分钟", "小时"]))
  }

  func testReturnTripRectangleUsesGroundedQuotientWithoutRedundantProductCheck() throws {
    let input: [String: Any] = ["id": "return", "title": "相同路程的速度与时间", "kind": "quantity_plan", "view": "area",
      "quantities": [source("outSpeed", 30, unit: "米/分钟"), source("outTime", 21, unit: "分钟"),
        source("returnSpeed", 20, unit: "米/分钟"), operation("distance", "product", ["outSpeed", "outTime"]),
        operation("returnTime", "quotient", ["distance", "returnSpeed"])],
      "layout": ["length": "returnSpeed", "width": "returnTime", "area": "distance"]]
    let diagram = try MathDiagramPlan.compile(input)
    XCTAssertEqual(diagram.fact("returnTime")?.value, 31.5)
    XCTAssertEqual(diagram.fact("returnTime")?.unit, "分钟")
    var wrong = diagram
    wrong.factIDs[1] = "outTime"
    XCTAssertThrowsError(try wrong.validate(), "A relation involving another trip must not validate these axes")
  }

  private func plan(for fixture: MathDiagram) throws -> [String: Any] {
    var used = Set<Int>()
    let quantities = try fixture.facts.map { fact -> [String: Any] in
      var entry: [String: Any] = ["id": fact.id, "label": fact.label]
      switch fact.origin {
      case .given:
        entry["value"] = try XCTUnwrap(fact.value)
        entry["unit"] = fact.unit
        entry["evidence"] = try XCTUnwrap(fact.evidence)
      case .unknown:
        entry["unknown"] = true
        entry["unit"] = fact.unit
      case .constant:
        let names: [Double: String] = [0: "zero", 1: "one", 2: "two", 10: "ten", 100: "hundred", 1000: "thousand"]
        entry["rule"] = try XCTUnwrap(names[try XCTUnwrap(fact.value)])
      case .derived:
        let index = try XCTUnwrap(fixture.relations.indices.first { fixture.relations[$0].outputID == fact.id })
        used.insert(index)
        entry["operation"] = fixture.relations[index].operation.rawValue
        entry["inputs"] = fixture.relations[index].inputIDs
        // Neither answer values nor units for calculations are supplied by the model.
      }
      return entry
    }
    return ["id": fixture.id, "title": fixture.title, "kind": "quantity_plan", "view": fixture.kind.rawValue,
      "quantities": quantities, "factIDs": fixture.factIDs, "parts": fixture.parts,
      "columns": fixture.columns, "rows": fixture.rows.map { ["label": $0.label, "factIDs": $0.factIDs] as [String: Any] },
      "checks": fixture.relations.indices.filter { !used.contains($0) }.map {
        ["operation": fixture.relations[$0].operation.rawValue, "inputs": fixture.relations[$0].inputIDs,
          "result": fixture.relations[$0].outputID] as [String: Any]
      }]
  }

  private func table(_ quantities: [[String: Any]], output: String = "result", checks: [[String: Any]] = []) -> [String: Any] {
    ["id": "plan", "title": "从原题数量推导", "kind": "quantity_plan", "view": "table",
      "quantities": quantities, "columns": ["结果"], "rows": [["label": "推导", "factIDs": [output]]], "checks": checks]
  }
  private func source(_ id: String, _ value: Double, unit: String = "") -> [String: Any] {
    ["id": id, "label": id, "value": value, "unit": unit, "evidence": "原题明确给出 \(id)=\(value)\(unit)"]
  }
  private func operation(_ id: String, _ name: String, _ inputs: [String]) -> [String: Any] {
    ["id": id, "label": id, "operation": name, "inputs": inputs]
  }

  private func namedPlan(for fixture: MathDiagram) throws -> [String: Any] {
    var input = try plan(for: fixture)
    for key in ["factIDs", "parts", "columns", "rows"] { input.removeValue(forKey: key) }
    let ids = fixture.factIDs
    let layout: [String: Any]
    switch fixture.kind {
    case .barComparison: layout = ["items": ids]
    case .equalParts: layout = ["items": ids, "parts": fixture.parts]
    case .state: layout = ["states": ids]
    case .table:
      layout = ["columns": fixture.columns, "rows": fixture.rows.map { ["label": $0.label, "factIDs": $0.factIDs] as [String: Any] }]
    case .area: layout = ["length": ids[0], "width": ids[1], "area": ids[2]]
    case .interval: layout = ["start": ids[0], "end": ids[1], "gaps": ids[2], "per": ids[3], "total": ids[4]]
    case .balance: layout = ["high": ids[0], "low": ids[1], "mean": ids[2], "transfer": ids[3]]
    case .partWhole: layout = ["whole": ids[0], "portions": Array(ids.dropFirst())]
    case .venn:
      var roles: [String: Any] = ["leftOnly": ids[0], "intersection": ids[1], "rightOnly": ids[2], "union": ids[3]]
      if ids.count == 6 { roles["outside"] = ids[4]; roles["total"] = ids[5] }
      layout = roles
    case .cycle: layout = ["count": ids[0], "period": ids[1], "cycles": ids[2], "remainder": ids[3], "labels": fixture.columns]
    }
    input["layout"] = layout
    return input
  }

  @MainActor
  func testNamedRoleLayoutsCompileGoldQuantitiesAndNativeGeometryForAllTenViews() throws {
    let fixtures = MathDiagramFixtures.all + MathDiagramNewFixtures.all
    XCTAssertEqual(Set(fixtures.map { $0.kind.rawValue }).count, 10)
    for fixture in fixtures {
      let input = try namedPlan(for: fixture)
      XCTAssertNil(input["factIDs"])
      XCTAssertNil(input["parts"])
      let diagram = try MathDiagramPlan.compile(input)
      XCTAssertEqual(diagram.kind, fixture.kind)
      XCTAssertEqual(diagram.factIDs, fixture.factIDs)
      for gold in fixture.facts {
        let actual = try XCTUnwrap(diagram.fact(gold.id))
        XCTAssertEqual(actual.value, gold.value, "\(fixture.id)/\(gold.id)")
        XCTAssertEqual(actual.unit, gold.unit)
        XCTAssertEqual(actual.origin, gold.origin)
      }
      XCTAssertEqual(diagram.relations.count, fixture.relations.count)
      XCTAssertTrue(fixture.relations.allSatisfy { diagram.relations.contains($0) })
      for width: CGFloat in [360, 507.28, 900] {
        let layout = try MathDiagramRenderer.layout(diagram, width: width)
        XCTAssertTrue(layout.elements.contains { element in
          switch element.shape {
          case .text: return false
          default: return true
          }
        }, "\(fixture.id) must contain real drawing geometry, not text only")
        XCTAssertNotNil(NSBitmapImageRep(data: try MathDiagramRenderer.renderPNG(diagram, width: width)))
        let answer = NSMutableAttributedString(string: "方法说明")
        MathDiagramPresentation.append([diagram], failure: nil, to: answer, width: width)
        var images = 0
        answer.enumerateAttribute(.attachment, in: NSRange(location: 0, length: answer.length)) { value, _, _ in
          if let attachment = value as? NSTextAttachment, attachment.image != nil { images += 1 }
        }
        XCTAssertEqual(images, 1, "\(fixture.id) at width \(width)")
      }
    }
  }

  func testNamedLayoutRejectsEveryMissingRequiredRoleAndExtraRole() throws {
    for fixture in MathDiagramFixtures.all + MathDiagramNewFixtures.all {
      let valid = try namedPlan(for: fixture)
      let layout = try XCTUnwrap(valid["layout"] as? [String: Any])
      for role in layout.keys {
        var missing = layout; missing.removeValue(forKey: role)
        var input = valid; input["layout"] = missing
        XCTAssertThrowsError(try MathDiagramPlan.compile(input), "\(fixture.kind.rawValue) missing \(role)")
      }
      var extra = layout; extra["inventedRole"] = "total"
      var input = valid; input["layout"] = extra
      XCTAssertThrowsError(try MathDiagramPlan.compile(input), "\(fixture.kind.rawValue) must reject unknown roles")
    }
  }

  func testNamedLayoutRejectsWrongTypesNonexistentReferencesAndMixedLegacyFields() throws {
    for fixture in MathDiagramFixtures.all + MathDiagramNewFixtures.all {
      let valid = try namedPlan(for: fixture)
      let layout = try XCTUnwrap(valid["layout"] as? [String: Any])
      for role in layout.keys {
        var wrong = layout; wrong[role] = 12
        var input = valid; input["layout"] = wrong
        XCTAssertThrowsError(try MathDiagramPlan.compile(input), "\(fixture.kind.rawValue)/\(role) cannot be numeric")
      }
      for key in ["factIDs", "parts", "columns", "rows"] {
        var mixed = valid; mixed[key] = []
        XCTAssertThrowsError(try MathDiagramPlan.compile(mixed), "Named layout cannot coexist even with empty legacy \(key)")
      }
      var wrongReference = layout
      switch fixture.kind {
      case .barComparison, .equalParts: wrongReference["items"] = ["missing", fixture.factIDs[1]]
      case .state: wrongReference["states"] = ["missing", fixture.factIDs[1], fixture.factIDs[2]]
      case .table:
        wrongReference["rows"] = [["label": "坏引用", "factIDs": ["missing", "missing", "missing"]]]
      case .area: wrongReference["area"] = "missing"
      case .interval: wrongReference["gaps"] = "missing"
      case .balance: wrongReference["mean"] = "missing"
      case .partWhole: wrongReference["portions"] = [fixture.factIDs[1], "missing"]
      case .venn: wrongReference["intersection"] = "missing"
      case .cycle: wrongReference["remainder"] = "missing"
      }
      var input = valid; input["layout"] = wrongReference
      XCTAssertThrowsError(try MathDiagramPlan.compile(input), "\(fixture.kind.rawValue) role must reference a declared quantity")
      input = valid; input["layout"] = NSNull()
      XCTAssertThrowsError(try MathDiagramPlan.compile(input))
      input = valid; input["layout"] = ["items"]
      XCTAssertThrowsError(try MathDiagramPlan.compile(input))
    }
  }

  func testNamedVennAllowsFourRegionsOrPairedOutsideAndTotalButNeverAnIncompletePair() throws {
    var diagram = MathDiagramNewFixtures.venn
    diagram.factIDs = Array(diagram.factIDs.prefix(4))
    let fourRegion = try MathDiagramPlan.compile(namedPlan(for: diagram))
    XCTAssertEqual(fourRegion.factIDs, ["left", "both", "right", "union"])
    XCTAssertEqual(fourRegion.fact("union")?.value, 54)
    let sixRegion = try MathDiagramPlan.compile(namedPlan(for: MathDiagramNewFixtures.venn))
    XCTAssertEqual(sixRegion.fact("total")?.value, 60)
    for omitted in ["outside", "total"] {
      var input = try namedPlan(for: MathDiagramNewFixtures.venn)
      var layout = try XCTUnwrap(input["layout"] as? [String: Any]); layout.removeValue(forKey: omitted)
      input["layout"] = layout
      XCTAssertThrowsError(try MathDiagramPlan.compile(input), "Outside and total must be supplied together")
    }
  }

  func testNamedLayoutChecksSemanticBindingsInsteadOfOnlyAcceptingExistingIDs() throws {
    var equal = try namedPlan(for: MathDiagramFixtures.parts)
    equal["layout"] = ["items": ["a", "b"], "parts": [2, 1]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(equal))
    var balance = try namedPlan(for: MathDiagramNewFixtures.balance)
    balance["layout"] = ["high": "high", "low": "low", "mean": "transfer", "transfer": "mean"]
    XCTAssertThrowsError(try MathDiagramPlan.compile(balance))
    var interval = try namedPlan(for: MathDiagramFixtures.interval)
    interval["layout"] = ["start": "end", "end": "start", "gaps": "count", "per": "per", "total": "total"]
    XCTAssertThrowsError(try MathDiagramPlan.compile(interval))
    var cycle = try namedPlan(for: MathDiagramNewFixtures.cycle)
    cycle["layout"] = ["count": "total", "period": "period", "cycles": "cycles", "remainder": "remainder", "labels": ["红", "黄", "蓝"]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(cycle))
    var table = try namedPlan(for: MathDiagramFixtures.table)
    table["layout"] = ["columns": ["一列"], "rows": [["label": "方案", "factIDs": ["rate1", "count"]]]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(table))
  }

  func testAllExistingViewsAndUnknownFixtureCompileFromConditionsToIndependentGold() throws {
    for fixture in MathDiagramFixtures.all {
      let diagram = try MathDiagramPlan.compile(plan(for: fixture))
      XCTAssertEqual(diagram.kind, fixture.kind)
      XCTAssertEqual(diagram.factIDs, fixture.factIDs)
      XCTAssertEqual(diagram.parts, fixture.parts)
      XCTAssertEqual(diagram.rows, fixture.rows)
      XCTAssertEqual(diagram.relations.count, fixture.relations.count)
      XCTAssertTrue(fixture.relations.allSatisfy { diagram.relations.contains($0) })
      for gold in fixture.facts {
        let actual = try XCTUnwrap(diagram.fact(gold.id))
        XCTAssertEqual(actual.value, gold.value, "\(fixture.id)/\(gold.id)")
        XCTAssertEqual(actual.unit, gold.unit, "\(fixture.id)/\(gold.id)")
        XCTAssertEqual(actual.origin, gold.origin)
      }
      for width: CGFloat in [360, 507.28, 900] {
        let layout = try MathDiagramRenderer.layout(diagram, width: width)
        XCTAssertFalse(layout.elements.isEmpty)
        XCTAssertEqual(layout.size.width, width)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertNotNil(NSBitmapImageRep(data: try MathDiagramRenderer.renderPNG(diagram, width: width)))
      }
    }
  }

  @MainActor
  func testCompiledPlansReachNativeAnswerAttachmentsForEverySupportedView() throws {
    let fixtures = MathDiagramFixtures.all + MathDiagramNewFixtures.all
    let diagrams = try fixtures.map { try MathDiagramPlan.compile(plan(for: $0)) }
    let answer = NSMutableAttributedString(string: "解题过程")
    MathDiagramPresentation.append(diagrams, failure: nil, to: answer, width: 900)
    var attached: [NSTextAttachment] = []
    answer.enumerateAttribute(.attachment, in: NSRange(location: 0, length: answer.length)) { value, _, _ in
      if let attachment = value as? NSTextAttachment { attached.append(attachment) }
    }
    XCTAssertEqual(attached.count, diagrams.count)
    XCTAssertTrue(attached.allSatisfy { $0.image != nil && $0.bounds.width > 0 && $0.bounds.height > 0 })
    XCTAssertFalse(answer.string.contains("未显示"))
  }

  func testNewVisualFamiliesCompileIncludingIntegerCyclesAndRemainders() throws {
    for fixture in MathDiagramNewFixtures.all {
      let diagram = try MathDiagramPlan.compile(plan(for: fixture))
      for gold in fixture.facts {
        let actual = try XCTUnwrap(diagram.fact(gold.id))
        XCTAssertEqual(actual.value, gold.value)
        XCTAssertEqual(actual.unit, gold.unit)
        XCTAssertEqual(actual.origin, gold.origin)
      }
      try diagram.validate()
    }
    let cycle = try MathDiagramPlan.compile(plan(for: MathDiagramNewFixtures.cycle))
    XCTAssertEqual(cycle.fact("cycles")?.value, 7)
    XCTAssertEqual(cycle.fact("remainder")?.value, 2)
    XCTAssertEqual(cycle.fact("cycles")?.origin, .derived)
    XCTAssertEqual(cycle.fact("remainder")?.origin, .derived)
    XCTAssertEqual(7 * 4 + 2, 30)
  }

  func testDependenciesResolveInAnyInputOrderWithoutChangingFactIdentities() throws {
    var input = try plan(for: MathDiagramFixtures.table)
    let quantities = try XCTUnwrap(input["quantities"] as? [[String: Any]])
    input["quantities"] = Array(quantities.reversed())
    let diagram = try MathDiagramPlan.compile(input)
    XCTAssertEqual(diagram.facts.map(\.id), quantities.reversed().compactMap { $0["id"] as? String })
    XCTAssertEqual(diagram.fact("count")?.value, 25)
    XCTAssertEqual(diagram.fact("used1")?.value, 625)
    XCTAssertEqual(diagram.fact("total")?.value, 675)
    XCTAssertEqual(diagram.fact("total")?.origin, .derived)
  }

  func testUnknownInputsPropagateUnknownAndNeverAcquireAssumedValues() throws {
    let diagram = try MathDiagramPlan.compile(table([
      operation("result", "sum", ["unknown", "known"]), source("known", 12, unit: "人"),
      ["id": "unknown", "label": "未给出的人数", "unit": "人", "unknown": true],
    ]))
    XCTAssertNil(diagram.fact("unknown")?.value)
    XCTAssertNil(diagram.fact("result")?.value)
    XCTAssertEqual(diagram.fact("result")?.origin, .unknown)
    XCTAssertEqual(diagram.fact("result")?.unit, "人")
    let labels = try MathDiagramRenderer.layout(diagram).elements.compactMap { element -> String? in
      if case .text(let text, _, _) = element.shape { return text }; return nil
    }
    XCTAssertTrue(labels.contains { $0.contains("？") && $0.contains("待求") })
  }

  func testSourceEvidenceAndVariantWhitelistRejectInventedComputedAnswers() {
    let valid = [source("a", 12), source("b", 4), operation("result", "quotient", ["a", "b"])]
    var variants: [[[String: Any]]] = []
    var forged = valid; forged[0].removeValue(forKey: "evidence"); variants.append(forged)
    forged = valid; forged[0]["value"] = true; variants.append(forged)
    forged = valid; forged[0]["evidence"] = ""; variants.append(forged)
    forged = valid; forged[2]["value"] = 999; variants.append(forged)
    forged = valid; forged[2]["origin"] = "given"; variants.append(forged)
    forged = valid; forged[2]["outputID"] = "a"; variants.append(forged)
    forged = valid; forged[2]["evidence"] = "AI 已算出"; variants.append(forged)
    for quantities in variants { XCTAssertThrowsError(try MathDiagramPlan.compile(table(quantities))) }
    var topLevel = table(valid); topLevel["script"] = "return 999"
    XCTAssertThrowsError(try MathDiagramPlan.compile(topLevel))
    var row = table(valid); row["rows"] = [["label": "结果", "factIDs": ["result"], "value": 999]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(row))
    var check = table(valid); check["checks"] = [["operation": "equal", "inputs": ["result"], "result": "a", "outputID": "a"]]
    XCTAssertThrowsError(try MathDiagramPlan.compile(check))
  }

  func testRulesAreExplicitDimensionlessAndUnknownMustBeBooleanTrue() throws {
    let rule: [String: Any] = ["id": "two", "label": "平分两份", "rule": "two"]
    let valid = [source("sum", 72, unit: "人"), rule, operation("result", "quotient", ["sum", "two"])]
    let diagram = try MathDiagramPlan.compile(table(valid))
    XCTAssertEqual(diagram.fact("two")?.origin, .constant)
    XCTAssertEqual(diagram.fact("two")?.unit, "")
    XCTAssertEqual(diagram.fact("result")?.value, 36)
    for extra in [["unit": "人"], ["rule": "nine"], ["value": 2]] as [[String: Any]] {
      var modified = valid; modified[1].merge(extra) { _, new in new }
      XCTAssertThrowsError(try MathDiagramPlan.compile(table(modified)))
    }
    for flag: Any in [false, 2, "true", NSNull()] {
      let quantities: [[String: Any]] = [["id": "a", "label": "未知", "unknown": flag], operation("result", "equal", ["a"])]
      XCTAssertThrowsError(try MathDiagramPlan.compile(table(quantities)))
    }
  }

  func testUnitInferenceSupportsRatesAreasAndReciprocalsButRejectsContradictions() throws {
    let rate = try MathDiagramPlan.compile(table([source("distance", 120, unit: "千米"), source("time", 4, unit: "小时"),
      operation("speed", "quotient", ["distance", "time"]), operation("result", "product", ["speed", "time"])]))
    XCTAssertEqual(rate.fact("speed")?.value, 30)
    XCTAssertEqual(rate.fact("speed")?.unit, "km/小时")
    XCTAssertEqual(rate.fact("result")?.unit, "km")
    XCTAssertEqual(rate.fact("result")?.value, 120)
    let reciprocal = try MathDiagramPlan.compile(table([source("one", 1), source("count", 4, unit: "人"),
      operation("inverse", "quotient", ["one", "count"]), operation("result", "product", ["inverse", "count"])]))
    XCTAssertEqual(reciprocal.fact("inverse")?.unit, "1/人")
    XCTAssertEqual(reciprocal.fact("result")?.unit, "")
    XCTAssertEqual(reciprocal.fact("result")?.value, 1)
    var wrong = [source("distance", 120, unit: "米"), source("time", 4, unit: "小时"), operation("result", "sum", ["distance", "time"])]
    XCTAssertThrowsError(try MathDiagramPlan.compile(table(wrong)))
    wrong[2] = operation("result", "quotient", ["distance", "time"]); wrong[2]["unit"] = "米"
    XCTAssertThrowsError(try MathDiagramPlan.compile(table(wrong)))
  }

  func testUnitsAndMetadataAreBoundedBeforeExpandingCalculationGraph() {
    let longUnit = String(repeating: "米", count: 25)
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 1, unit: longUnit), operation("result", "equal", ["a"])])))
    XCTAssertThrowsError(try MathDiagram.inferredUnit(.product, inputs: [String(repeating: "m", count: 100_000), "m"]))
    var graph = [source("power0", 1, unit: "m")]
    for exponent in 1...20 { graph.append(operation("power\(exponent)", "product", ["power\(exponent - 1)", "power\(exponent - 1)"])) }
    XCTAssertThrowsError(try MathDiagramPlan.compile(table(graph, output: "power20")), "Exponent growth must fail before allocating enormous unit strings")
    for key in ["id", "label", "evidence"] {
      var a = source("a", 1); a[key] = String(repeating: "x", count: 501)
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([a, operation("result", "equal", ["a"])])))
    }
    var tooMany = (0..<33).map { source("a\($0)", 1) }
    tooMany.append(operation("result", "equal", ["a0"]))
    XCTAssertThrowsError(try MathDiagramPlan.compile(table(tooMany)))
  }

  func testDependencyCyclesMissingReferencesDuplicateIDsAndInvalidAritiesAreRejected() {
    let cases: [[[String: Any]]] = [
      [operation("a", "equal", ["result"]), operation("result", "equal", ["a"])],
      [source("a", 1), operation("result", "equal", ["missing"])],
      [source("a", 1), source("a", 2), operation("result", "equal", ["a"])],
      [source("a", 1), operation("result", "equal", ["result"])],
      [source("a", 1), operation("result", "sum", ["a"])],
      [source("a", 1), operation("result", "difference", ["a", "a", "a"])],
      [source("a", 1), operation("result", "equal", [])],
      [source("a", 1), operation("result", "execute", ["a"])],
    ]
    for quantities in cases { XCTAssertThrowsError(try MathDiagramPlan.compile(table(quantities))) }
  }

  func testAllDivisionOperationsRejectZeroAndIntegerOperationsRejectFractionalInputs() {
    for name in ["quotient", "floor_quotient", "remainder"] {
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 30), source("b", 0), operation("result", name, ["a", "b"])])))
    }
    for name in ["floor_quotient", "remainder"] {
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 30.5), source("b", 4), operation("result", name, ["a", "b"])])))
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 30, unit: "人"), source("b", 4, unit: "张"), operation("result", name, ["a", "b"])])))
    }
  }

  func testExactFiniteDecimalBoundaryRejectsRoundedFractionsAndOutOfRangeResults() throws {
    let valid = try MathDiagramPlan.compile(table([source("a", 1), source("b", 8), operation("result", "quotient", ["a", "b"])]))
    XCTAssertEqual(valid.fact("result")?.value, 0.125)
    for (a, b) in [(1.0, 3.0), (1.0, 128.0), (240.0, 11.0)] {
      XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", a), source("b", b), operation("result", "quotient", ["a", "b"])])))
    }
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 1.2345678), operation("result", "equal", ["a"])])))
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", 1_000_000_000), source("b", 2), operation("result", "product", ["a", "b"])])))
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([source("a", .infinity), operation("result", "equal", ["a"])])))
  }

  func testBinaryFloatingPointNoiseDoesNotRejectExactSuitCountOrAcceptTinyUnsupportedDecimal() throws {
    let suits = try MathDiagramPlan.compile(table([
      source("oldRate", 3.2, unit: "米/套"), source("oldCount", 791, unit: "套"),
      source("newRate", 2.8, unit: "米/套"), operation("cloth", "product", ["oldRate", "oldCount"]),
      operation("result", "quotient", ["cloth", "newRate"]),
    ]))
    XCTAssertEqual(suits.fact("cloth")?.value, 2531.2)
    XCTAssertEqual(suits.fact("result")?.value, 904)
    XCTAssertEqual(suits.fact("result")?.unit, "套")
    XCTAssertThrowsError(try MathDiagramPlan.compile(table([
      source("a", 0.000001), source("b", 0.000001), operation("result", "product", ["a", "b"]),
    ])), "A real 1e-12 result must not be normalized to zero")
  }

  func testChecksCannotTurnInconsistentArithmeticIntoAnAcceptedDiagram() throws {
    let quantities = [source("a", 12), source("b", 4), operation("result", "quotient", ["a", "b"])]
    let valid = table(quantities, checks: [["operation": "product", "inputs": ["result", "b"], "result": "a"]])
    XCTAssertEqual(try MathDiagramPlan.compile(valid).fact("result")?.value, 3)
    for check in [
      ["operation": "sum", "inputs": ["result", "b"], "result": "a"],
      ["operation": "equal", "inputs": ["missing"], "result": "a"],
      ["operation": "equal", "inputs": ["result"], "result": "missing"],
      ["operation": "product", "inputs": ["result"], "result": "a"],
    ] as [[String: Any]] { XCTAssertThrowsError(try MathDiagramPlan.compile(table(quantities, checks: [check]))) }
  }

  func testSurplusTableComputesPeopleTotalsAndExactRemainderWithoutChecks() throws {
    for recipients in [true, false] {
      let low = recipients ? 25.0 : 20.0, high = recipients ? 27.0 : 22.0
      var quantities = [source("low", low, unit: "张/人"), source("high", high, unit: "张/人")]
      if recipients {
        quantities += [source("extraPeople", 2, unit: "人"), operation("surplus", "product", ["low", "extraPeople"])]
      } else { quantities += [source("surplus", 60, unit: "张")] }
      quantities += [operation("gap", "difference", ["high", "low"]),
        operation("count", "quotient", ["surplus", "gap"]),
        operation("sentLow", "product", ["low", "count"]),
        operation("total", "sum", ["sentLow", "surplus"]),
        operation("sentHigh", "product", ["high", "count"]),
        operation("remainingHigh", "difference", ["total", "sentHigh"])]
      var input = table(quantities)
      input.removeValue(forKey: "columns"); input.removeValue(forKey: "rows")
      input["layout"] = ["columns": ["每人张数", "人数", "已发", "剩余"], "rows": [
        ["label": "原分法", "factIDs": ["low", "count", "sentLow", "surplus"]],
        ["label": "正好发完", "factIDs": ["high", "count", "sentHigh", "remainingHigh"]],
      ]]
      let diagram = try MathDiagramPlan.compile(input)
      XCTAssertEqual(diagram.fact("count")?.value, recipients ? 25 : 30)
      XCTAssertEqual(diagram.fact("count")?.unit, "人")
      XCTAssertEqual(diagram.fact("count")?.origin, .derived)
      XCTAssertEqual(diagram.fact("total")?.value, recipients ? 675 : 660)
      XCTAssertEqual(diagram.fact("remainingHigh")?.value, 0)
      XCTAssertEqual(diagram.fact("remainingHigh")?.unit, "张")
      try MathDiagramAnswer.validateRendering(diagram)
      XCTAssertFalse(try MathDiagramRenderer.renderPNG(diagram).isEmpty)

      for check: [String: Any] in [
        ["operation": "equal", "inputs": ["total", "sentHigh"], "result": "total"],
        ["operation": "equal", "inputs": ["total"], "result": "total"],
        ["operation": "product", "inputs": ["low", "count"], "result": "surplus"],
      ] {
        var invalid = input; invalid["checks"] = [check]
        XCTAssertThrowsError(try MathDiagramPlan.compile(invalid), "Invalid checks must never be silently dropped")
      }
    }
  }

  func testEnvelopeParsingNormalizesPlanAndHidesOnlyTheProtocolBlock() throws {
    let input = try plan(for: MathDiagramFixtures.parts)
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": [input]])
    let payload = try XCTUnwrap(String(data: data, encoding: .utf8))
    let response = "先按三倍关系分份。仍需用户核验。\n```math-diagrams\n\(payload)\n```"
    let parsed = MathDiagramAnswer.parse(response)
    XCTAssertNil(parsed.failure)
    XCTAssertEqual(parsed.diagrams.count, 1)
    XCTAssertEqual(parsed.diagrams.first?.fact("b")?.value, 20)
    XCTAssertTrue(parsed.text.contains("先按三倍关系分份"))
    XCTAssertTrue(parsed.text.contains("仍需用户核验"))
    XCTAssertFalse(parsed.text.contains("quantity_plan"))
  }
}
