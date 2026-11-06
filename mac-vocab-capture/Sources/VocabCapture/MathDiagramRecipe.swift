import Foundation
import CoreFoundation

/// Compiles original difference/ratio conditions into the existing checked diagram schema.
/// The model supplies no computed quantities or fact roles; those follow from the recipe.
enum MathDiagramRecipe {
  private struct Difference: Decodable {
    let value: Double
    let unit: String
    let evidence: String
  }
  private struct Multiplier: Decodable {
    let value: Double
    let evidence: String
    let unit: String?
    private enum CodingKeys: String, CodingKey { case value, evidence, unit }
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      value = try container.decode(Double.self, forKey: .value)
      evidence = try container.decode(String.self, forKey: .evidence)
      // Omission is supported; an explicit unit must be a string, never null or a number.
      unit = container.contains(.unit) ? try container.decode(String.self, forKey: .unit) : nil
    }
  }
  private struct DifferenceRatio: Decodable {
    let id: String
    let title: String
    let difference: Difference
    let multiplier: Multiplier
  }

  /// Leaves ordinary diagrams untouched, including invalid data, for their normal checks.
  /// Recipes are accepted only through this narrow field whitelist and compile to ordinary
  /// diagrams before parsing, rendering, persistence, and PDF export.
  static func normalizedEnvelope(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    // The reader can parse an overflowing exponent into NSNumber.infinity, while
    // writing that object raises an Objective-C exception rather than a Swift error.
    // Check the whole envelope, including ordinary diagrams, before any JSON write.
    guard JSONSerialization.isValidJSONObject(object) else {
      throw MathDiagram.ValidationError(message: "图解数据必须包含有限的 JSON 数值，不能使用溢出指数或无穷大。")
    }
    guard var envelope = object as? [String: Any],
      let entries = envelope["diagrams"] as? [[String: Any]] else { return data }
    var changed = false
    let normalized = try entries.map { entry -> [String: Any] in
      if entry["kind"] as? String == "quantity_plan" {
        changed = true
        let diagram = try MathDiagramPlan.compile(entry)
        guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as? [String: Any] else {
          throw MathDiagram.ValidationError(message: "通用图解计划无法转换为图形数据。")
        }
        return encoded
      }
      if entry["kind"] as? String == "purchase_comparison" {
        changed = true
        let diagram = try MathPurchaseComparisonRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "return_deadline" {
        changed = true
        let diagram = try MathReturnDeadlineRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "interval_problem" {
        changed = true
        let diagram = try MathIntervalRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if MathComparisonRecipe.kinds.contains(entry["kind"] as? String ?? "") {
        changed = true
        let diagram = try MathComparisonRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "rectangle_sum_difference" {
        changed = true
        let diagram = try MathRectangleSumDifferenceRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "venn_counts" {
        changed = true
        let diagram = try MathVennCountsRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "state_changes" {
        changed = true
        let diagram = try MathStateChangesRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "cyclic_pattern" {
        changed = true
        let diagram = try MathCycleRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "fixed_total" {
        changed = true
        let diagram = try MathFixedTotalRecipe.compile(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      if entry["kind"] as? String == "two_allocations" {
        changed = true
        let diagram = try compileAllocations(entry)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as! [String: Any]
      }
      guard entry["kind"] as? String == "difference_ratio" else { return entry }
      changed = true
      try requireKeys(entry, allowed: ["id", "title", "kind", "difference", "multiplier"])
      if let difference = entry["difference"] as? [String: Any] {
        try requireKeys(difference, allowed: ["value", "unit", "evidence"])
      }
      if let multiplier = entry["multiplier"] as? [String: Any] {
        try requireKeys(multiplier, allowed: ["value", "evidence", "unit"])
      }
      let recipe = try JSONDecoder().decode(DifferenceRatio.self, from: JSONSerialization.data(withJSONObject: entry))
      let diagram = try compile(recipe)
      guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagram)) as? [String: Any] else {
        throw MathDiagram.ValidationError(message: "差倍图配方无法转换为图形数据。")
      }
      return object
    }
    guard changed else { return data }
    envelope["diagrams"] = normalized
    return try JSONSerialization.data(withJSONObject: envelope)
  }

  private static func requireKeys(_ object: [String: Any], allowed: Set<String>) throws {
    guard Set(object.keys).isSubset(of: allowed) else {
      throw MathDiagram.ValidationError(message: "差倍图配方包含未支持的字段；只填写原题差数、倍数及来源，不填写答案或事实角色。")
    }
  }

  private static func compile(_ recipe: DifferenceRatio) throws -> MathDiagram {
    if let unit = recipe.multiplier.unit?.trimmingCharacters(in: .whitespacesAndNewlines),
      !unit.isEmpty && unit != "倍" {
      throw MathDiagram.ValidationError(message: "差倍图的倍数是无单位的比例；multiplier.unit 只可省略、为空字符串或写“倍”，不能使用年龄等数量单位。")
    }
    let difference = recipe.difference.value, multiplier = recipe.multiplier.value
    guard difference.isFinite, (0...1_000_000_000).contains(difference),
      multiplier.isFinite, (2...20).contains(multiplier), multiplier.rounded() == multiplier else {
      throw MathDiagram.ValidationError(message: "差倍图需要非负有限差数，以及原题明确给出的 2 至 20 的整数倍数。")
    }
    let trailingZeroRule = multiplier == 10 && missingOneTrailingZero(recipe.multiplier.evidence)
    guard MathOriginalQuantityPremise.difference(difference, evidence: recipe.difference.evidence),
      trailingZeroRule || MathOriginalQuantityPremise.multiplier(multiplier, evidence: recipe.multiplier.evidence) else {
      throw MathDiagram.ValidationError(message: "差倍图必须引用原题明确的差数和倍数；不能把总数、计算结果或平分规则冒充这两个已知条件。")
    }
    let extraParts = multiplier - 1
    let smaller = difference / extraParts
    let larger = smaller * multiplier
    guard !trailingZeroRule || (difference.rounded() == difference && smaller.rounded() == smaller) else {
      throw MathDiagram.ValidationError(message: "末尾少写一个0的整数配方需要整数差数，且差数能被9整除。")
    }
    let diagram = MathDiagram(
      id: recipe.id, title: recipe.title, kind: .equalParts,
      facts: [
        .init(id: "difference", label: "相差数量", value: difference, unit: recipe.difference.unit,
          origin: .given, evidence: recipe.difference.evidence),
        .init(id: "multiplier", label: "较大量是较小量的倍数", value: multiplier,
          origin: trailingZeroRule ? .constant : .given,
          evidence: trailingZeroRule
            ? "十进制整数末尾少写一个0后，原整数是所得数的10倍。原题表述：" + recipe.multiplier.evidence
            : recipe.multiplier.evidence),
        .init(id: "one", label: "较小量占一份", value: 1, origin: .constant,
          evidence: "比较倍数时把较小量看作一份；份数是无单位的比例，不是原题数量。"),
        .init(id: "extra_parts", label: "较大量多出的份数", value: extraParts, origin: .derived),
        .init(id: "smaller", label: "较小量（1份）", value: smaller, unit: recipe.difference.unit, origin: .derived),
        .init(id: "larger", label: "较大量（\(Int(multiplier))份）", value: larger, unit: recipe.difference.unit, origin: .derived),
      ],
      relations: [
        .init(operation: .difference, inputIDs: ["multiplier", "one"], outputID: "extra_parts"),
        .init(operation: .quotient, inputIDs: ["difference", "extra_parts"], outputID: "smaller"),
        .init(operation: .product, inputIDs: ["smaller", "multiplier"], outputID: "larger"),
        .init(operation: .difference, inputIDs: ["larger", "smaller"], outputID: "difference"),
      ], factIDs: ["smaller", "larger", "difference"], parts: [1, Int(multiplier), Int(extraParts)])
    try diagram.validate()
    return diagram
  }

  /// A narrow integer place-value equivalence, not a general relaxation of
  /// literal source checks. Negated, decimal, multiple-zero and mixed clauses reject.
  private static func missingOneTrailingZero(_ evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    return text.range(of: #"^(?:在)?(?:整数|得数|结果|正确结果|计算结果)?的?末尾(?:少添|少写|漏写|漏添)了?(?:一|1)个(?:0|零)[。.]?$"#,
      options: .regularExpression) != nil
  }

  /// Two allocations use the same recipients and the same total. Only original
  /// rates and balances enter this contract; the compiler owns every derived fact.
  private static func compileAllocations(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ text: String) -> MathDiagram.ValidationError { .init(message: text) }
    func keys(_ object: [String: Any], _ allowed: Set<String>, _ required: Set<String>) throws {
      guard Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else {
        throw fail("两次分配配方缺少条件或包含额外字段；不能填写答案、事实编号、关系或布局。")
      }
    }
    func evidence(_ object: [String: Any]) throws -> String {
      guard let text = object["evidence"] as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else {
        throw fail("两次分配的已知条件必须保留原题来源，不能使用假设或计算结果作为来源。")
      }
      return text
    }
    func number(_ object: [String: Any], positive: Bool) throws -> Double {
      guard let value = object["value"] as? NSNumber,
        CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
        value.doubleValue >= (positive ? 0.000001 : 0), value.doubleValue <= 1_000_000_000 else {
        throw fail("两次分配的数量必须是支持范围内的非负数，每人分配量必须大于零。")
      }
      return value.doubleValue
    }
    try keys(entry, ["id", "title", "kind", "item_unit", "recipient_unit", "allocations", "view"],
      ["id", "title", "kind", "item_unit", "recipient_unit", "allocations"])
    guard let id = entry["id"] as? String, let title = entry["title"] as? String,
      let itemUnit = entry["item_unit"] as? String,
      let rawRecipientUnit = entry["recipient_unit"] as? String,
      ["张", "本", "个", "只", "袋", "箱", "件", "枝", "元", "千克", "米"].contains(itemUnit),
      ["人", "名", "名同学", "个", "组", "班", "只", "辆"].contains(rawRecipientUnit), itemUnit != rawRecipientUnit,
      let allocations = entry["allocations"] as? [[String: Any]], allocations.count == 2 else {
      throw fail("两次分配需要同一组接收者的两个条件，以及明确且不同的物品和接收者单位。")
    }
    let recipientUnit = ["名", "名同学"].contains(rawRecipientUnit) ? "人" : rawRecipientUnit
    let view = entry["view"] as? String ?? "table"
    guard entry["view"] == nil || entry["view"] is String,
      ["table", "bar_comparison"].contains(view) else { throw fail("两次分配只支持表格或线段比较图。") }
    var facts: [MathDiagram.Fact] = []
    var relations: [MathDiagram.Relation] = []
    var rates: [Double] = [], balances: [Double] = [], balanceIDs: [String] = []
    for (index, allocation) in allocations.enumerated() {
      try keys(allocation, ["per_recipient", "balance"], ["per_recipient", "balance"])
      guard let rate = allocation["per_recipient"] as? [String: Any],
        let balance = allocation["balance"] as? [String: Any], let kind = balance["kind"] as? String,
        ["surplus", "shortfall", "extra_recipients", "missing_recipients", "exact"].contains(kind) else {
        throw fail("每次分配必须给出每人数量和明确的盈、亏、正好状态。")
      }
      try keys(rate, ["value", "evidence"], ["value", "evidence"])
      try keys(balance, kind == "exact" ? ["kind", "evidence"] : ["kind", "value", "evidence"],
        kind == "exact" ? ["kind", "evidence"] : ["kind", "value", "evidence"])
      let amount = try number(rate, positive: true), rateEvidence = try evidence(rate)
      let remaining = kind == "exact" ? 0 : try number(balance, positive: false)
      let balanceEvidence = try evidence(balance)
      guard MathOriginalQuantityPremise.original(amount, evidence: rateEvidence),
        kind == "exact" || MathOriginalQuantityPremise.original(remaining, evidence: balanceEvidence) else {
        throw fail("每人量和余缺条件必须直接来自原题；还能分给几人应填写原人数，不能先算成物品数量。")
      }
      if kind == "exact", !["正好", "恰好", "刚好", "无剩余", "全部发完"].contains(where: balanceEvidence.contains) {
        throw fail("正好分完必须是原题明确给出的条件，不能把未知余缺设为零。")
      }
      let countUnits = ["张", "本", "个", "只", "袋", "箱", "件", "枝"]
      guard !countUnits.contains(itemUnit) || amount.rounded() == amount,
        !(kind == "extra_recipients" || kind == "missing_recipients") || remaining.rounded() == remaining else {
        throw fail("可数物品及剩余可分人数必须是整数。")
      }
      let prefix = "allocation_\(index + 1)", rateID = prefix + "_rate", balanceID = prefix + "_balance"
      facts.append(.init(id: rateID, label: "第\(index + 1)次每\(recipientUnit)分配", value: amount,
        unit: itemUnit + "/" + recipientUnit, origin: .given, evidence: rateEvidence))
      let isRecipients = kind == "extra_recipients" || kind == "missing_recipients"
      let magnitude = isRecipients ? amount * remaining : remaining
      let label = kind == "shortfall" || kind == "missing_recipients" ? "缺少数量" : (kind == "exact" ? "正好分完（余0）" : "剩余数量")
      if isRecipients {
        let countID = prefix + "_remaining_recipients"
        facts.append(.init(id: countID, label: "第\(index + 1)次余缺接收者数量", value: remaining,
          unit: recipientUnit, origin: .given, evidence: balanceEvidence))
        facts.append(.init(id: balanceID, label: "第\(index + 1)次" + label, value: magnitude,
          unit: itemUnit, origin: .derived))
        relations.append(.init(operation: .product, inputIDs: [rateID, countID], outputID: balanceID))
      } else {
        facts.append(.init(id: balanceID, label: "第\(index + 1)次" + label, value: magnitude,
          unit: itemUnit, origin: .given, evidence: balanceEvidence))
      }
      rates.append(amount); balances.append((kind == "shortfall" || kind == "missing_recipients") ? -magnitude : magnitude)
      balanceIDs.append(balanceID)
    }
    let low = rates[0] < rates[1] ? 0 : 1, high = 1 - low
    let rateDifference = rates[high] - rates[low], totalDifference = balances[low] - balances[high]
    guard rateDifference > 0, totalDifference > 0 else {
      throw fail("两次分配不能推出唯一正人数，或每人多发与余缺变化互相矛盾。")
    }
    let count = totalDifference / rateDifference
    guard count.isFinite, count > 0, count.rounded() == count else {
      throw fail("两次分配推出的人数不是正整数；请核对原题条件，不能四舍五入。")
    }
    func derived(_ id: String, _ label: String, _ value: Double, _ unit: String,
      _ operation: MathDiagram.Operation, _ inputs: [String]) {
      facts.append(.init(id: id, label: label, value: value, unit: unit, origin: .derived))
      relations.append(.init(operation: operation, inputIDs: inputs, outputID: id))
    }
    derived("rate_difference", "每\(recipientUnit)多发数量", rateDifference, itemUnit + "/" + recipientUnit,
      .difference, ["allocation_\(high + 1)_rate", "allocation_\(low + 1)_rate"])
    let differenceOperation: MathDiagram.Operation = balances[low] >= 0 && balances[high] < 0 ? .sum : .difference
    let differenceInputs = balances[low] < 0 ? [balanceIDs[high], balanceIDs[low]] : [balanceIDs[low], balanceIDs[high]]
    derived("total_difference", "两次分配的总差", totalDifference, itemUnit, differenceOperation, differenceInputs)
    derived("recipients", "接收者数量", count, recipientUnit, .quotient, ["total_difference", "rate_difference"])
    for index in 0..<2 {
      derived("allocation_\(index + 1)_used", "第\(index + 1)次需用数量", count * rates[index], itemUnit,
        .product, ["recipients", "allocation_\(index + 1)_rate"])
    }
    let total = count * rates[low] + balances[low]
    guard total > 0 else { throw fail("两次分配推出的总量不是正数。") }
    derived("total", "同一批物品总量", total, itemUnit, balances[low] >= 0 ? .sum : .difference,
      ["allocation_\(low + 1)_used", balanceIDs[low]])
    // The lower allocation derives the total; the other condition checks it
    // independently, without displaying the same derivation twice.
    relations.append(.init(operation: balances[high] >= 0 ? .sum : .difference,
      inputIDs: ["allocation_\(high + 1)_used", balanceIDs[high]], outputID: "total"))
    let diagram = MathDiagram(id: id, title: title, kind: view == "table" ? .table : .barComparison,
      facts: facts, relations: relations,
      factIDs: view == "table" ? [] : ["allocation_\(low + 1)_used", "total", balanceIDs[low]],
      columns: view == "table" ? ["每\(recipientUnit)分配", "同一份数", "需用数量", "剩余／缺少", "同一总量"] : [],
      rows: view == "table" ? (0..<2).map { index in
        .init(label: "第\(index + 1)次分配", factIDs: ["allocation_\(index + 1)_rate", "recipients",
          "allocation_\(index + 1)_used", balanceIDs[index], "total"])
      } : [])
    try diagram.validate()
    return diagram
  }

}
