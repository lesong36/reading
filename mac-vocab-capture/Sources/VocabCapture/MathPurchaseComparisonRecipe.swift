import Foundation
import CoreFoundation

/// A deliberately bounded, inert purchase recipe. This verifies arithmetic for
/// the stated exact-quantity policy, not the truth of image transcription or a
/// global optimum when buying surplus products or stacking offers is allowed.
enum MathPurchaseComparisonRecipe {
  static func compile(_ entry: [String: Any]) throws -> MathDiagram {
    func fail(_ message: String) -> MathDiagram.ValidationError { .init(message: message) }
    func keys(_ object: [String: Any], _ expected: Set<String>) throws {
      guard Set(object.keys) == expected else { throw fail("购买比较配方字段不完整或包含未支持的条件；不能填写答案、关系或布局。") }
    }
    func source(_ object: Any?, integer: Bool) throws -> (Double, String) {
      guard let object = object as? [String: Any] else { throw fail("购买比较的数量缺少原题来源。") }
      try keys(object, ["value", "evidence"])
      guard let number = object["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        let evidence = object["evidence"] as? String, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        evidence.count <= 500 else { throw fail("购买比较的原题数量或来源格式无效。") }
      let value = number.doubleValue
      guard value.isFinite, value > 0, value <= 1_000_000_000,
        !integer || value.rounded() == value else { throw fail("购买比较要求正的有限数量，可数物品必须是整数。") }
      return (value, evidence)
    }
    try keys(entry, ["id", "title", "kind", "item_unit", "currency_unit", "quantity_policy", "required_count", "unit_price", "offers"])
    guard entry["kind"] as? String == "purchase_comparison",
      entry["quantity_policy"] as? String == "exact_required_quantity",
      let id = entry["id"] as? String, let title = entry["title"] as? String,
      let unit = entry["item_unit"] as? String, ["本", "张", "个"].contains(unit),
      let currency = entry["currency_unit"] as? String, currency == "元",
      let offers = entry["offers"] as? [[String: Any]], offers.count == 2 else {
      throw fail("当前购买比较仅支持同商品、原价和恰好所需数量的两种独立优惠；不支持叠加或超量购买。")
    }
    let (count, countEvidence) = try source(entry["required_count"], integer: true)
    let (price, priceEvidence) = try source(entry["unit_price"], integer: true)
    var facts: [MathDiagram.Fact] = [
      .init(id: "required_count", label: "需要数量", value: count, unit: unit, origin: .given, evidence: countEvidence),
      .init(id: "unit_price", label: "原价单价", value: price, unit: currency + "/" + unit, origin: .given, evidence: priceEvidence),
    ]
    var relations: [MathDiagram.Relation] = [], rows: [MathDiagram.Row] = [], payments: [Double] = [], names: [String] = []
    func given(_ id: String, _ label: String, _ source: (Double, String), _ unit: String) {
      facts.append(.init(id: id, label: label, value: source.0, unit: unit, origin: .given, evidence: source.1))
    }
    func derived(_ id: String, _ label: String, _ value: Double, _ unit: String,
      _ operation: MathDiagram.Operation, _ inputs: [String]) {
      facts.append(.init(id: id, label: label, value: value, unit: unit, origin: .derived))
      relations.append(.init(operation: operation, inputIDs: inputs, outputID: id))
    }
    let original = count * price
    derived("original_total", "原价总额", original, currency, .product, ["required_count", "unit_price"])
    for (index, offer) in offers.enumerated() {
      guard let name = offer["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        name.count <= 40, !names.contains(name), let kind = offer["kind"] as? String else {
        throw fail("两种优惠必须具有不同且简短的名称。")
      }
      names.append(name)
      let prefix = "offer_\(index + 1)", paymentID = prefix + "_payment", paidID = prefix + "_paid_count"
      let freeID = prefix + "_free_count", savingID = prefix + "_saving"
      let payment: Double
      if kind == "threshold_reduction" {
        try keys(offer, ["name", "kind", "threshold", "reduction"])
        let threshold = try source(offer["threshold"], integer: true), reduction = try source(offer["reduction"], integer: true)
        guard reduction.0 < threshold.0 else { throw fail("每满减规则的减免必须小于原价门槛；其他优惠模式未支持。") }
        given(prefix + "_threshold", name + "原价满减门槛", threshold, currency)
        given(prefix + "_reduction", name + "每档减免", reduction, currency)
        let groups = floor(original / threshold.0)
        derived(prefix + "_groups", name + "满减档数", groups, "", .floorQuotient, ["original_total", prefix + "_threshold"])
        // Floor arithmetic requires integer values; fractional prices/thresholds
        // are intentionally unsupported rather than silently converted to cents.
        derived(savingID, name + "减免总额", groups * reduction.0, currency, .product, [prefix + "_groups", prefix + "_reduction"])
        payment = original - groups * reduction.0
        derived(paymentID, name + "实际支付", payment, currency, .difference, ["original_total", savingID])
        derived(paidID, name + "付费数量", count, unit, .equal, ["required_count"])
        derived(freeID, name + "赠送数量", 0, unit, .difference, ["required_count", paidID])
      } else if kind == "buy_get" {
        try keys(offer, ["name", "kind", "paid", "free"])
        let paid = try source(offer["paid"], integer: true), free = try source(offer["free"], integer: true)
        let bundle = paid.0 + free.0, groups = floor(count / bundle), remainder = count.truncatingRemainder(dividingBy: bundle)
        guard remainder < paid.0 else {
          throw fail("此买赠条件可能需要超量购买或放弃赠品才能求最优；当前恰好数量配方不覆盖，不能直接把剩余全按原价算。")
        }
        given(prefix + "_paid_per_group", name + "每组购买数量", paid, unit)
        given(prefix + "_free_per_group", name + "每组赠送数量", free, unit)
        derived(prefix + "_bundle", name + "每组到手数量", bundle, unit, .sum, [prefix + "_paid_per_group", prefix + "_free_per_group"])
        derived(prefix + "_groups", name + "完整买赠组数", groups, "", .floorQuotient, ["required_count", prefix + "_bundle"])
        derived(prefix + "_remainder", name + "其余单买数量", remainder, unit, .remainder, ["required_count", prefix + "_bundle"])
        derived(prefix + "_group_paid", name + "整组付费数量", groups * paid.0, unit, .product, [prefix + "_groups", prefix + "_paid_per_group"])
        derived(paidID, name + "付费数量", groups * paid.0 + remainder, unit, .sum, [prefix + "_group_paid", prefix + "_remainder"])
        derived(freeID, name + "赠送数量", groups * free.0, unit, .product, [prefix + "_groups", prefix + "_free_per_group"])
        relations.append(.init(operation: .sum, inputIDs: [paidID, freeID], outputID: "required_count"))
        payment = (groups * paid.0 + remainder) * price
        derived(paymentID, name + "实际支付", payment, currency, .product, [paidID, "unit_price"])
        derived(savingID, name + "比原价节省", original - payment, currency, .difference, ["original_total", paymentID])
      } else { throw fail("当前购买比较只支持按原价每满减和买几送几，不能套用其他或复合优惠。") }
      payments.append(payment)
      rows.append(.init(label: name, factIDs: [paidID, freeID, savingID, paymentID]))
    }
    let greater = payments[0] >= payments[1] ? 0 : 1
    derived("payment_difference", "两方案支付差额", abs(payments[0] - payments[1]), currency,
      .difference, ["offer_\(greater + 1)_payment", "offer_\(2 - greater)_payment"])
    let diagram = MathDiagram(id: id, title: title, kind: .table, facts: facts, relations: relations,
      columns: ["付费数量", "赠送数量", "比原价节省", "实际支付"], rows: rows)
    try diagram.validate()
    return diagram
  }
}
