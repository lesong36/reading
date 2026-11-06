import CoreFoundation
import Foundation

/// Shared input for every native drawing template. Results, fact roles and units
/// are compiled by the app; model input is inert quantity data and named operations.
enum MathDiagramPlan {
  private struct Quantity {
    let id: String
    let label: String
    let unit: String?
    let value: Double?
    let evidence: String?
    let operation: MathDiagram.Operation?
    let inputs: [String]
    let rule: String?
    let unknown: Bool
  }

  static func compile(_ supplied: [String: Any]) throws -> MathDiagram {
    var input = supplied
    if let raw = input.removeValue(forKey: "layout") {
      guard let layout = raw as? [String: Any], let view = input["view"] as? String,
        let kind = MathDiagram.Kind(rawValue: view),
        ["factIDs", "parts", "columns", "rows"].allSatisfy({ input[$0] == nil }) else {
        throw MathDiagram.ValidationError(message: "图解 layout 必须为命名位置对象，不能与旧布局字段混用。")
      }
      for (key, value) in try layoutMetadata(layout, kind: kind) { input[key] = value }
    }
    func fail(_ message: String) -> MathDiagram.ValidationError {
      .init(message: "通用图解计划：" + message)
    }
    func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
      guard Set(object.keys).isSubset(of: allowed) else { throw fail("包含未支持的字段；不填写 origin、计算结果或 outputID。") }
    }
    try keys(input, ["id", "title", "kind", "view", "quantities", "factIDs", "parts", "columns", "rows", "checks"])
    guard input["kind"] as? String == "quantity_plan",
      let id = input["id"] as? String, let title = input["title"] as? String,
      let view = input["view"] as? String, let kind = MathDiagram.Kind(rawValue: view),
      let entries = input["quantities"] as? [[String: Any]], (1...32).contains(entries.count)
    else { throw fail("需要编号、标题、受支持的 view 及 1 至 32 个 quantities。") }
    guard !id.isEmpty, id.count <= 80, !title.isEmpty, title.count <= 120 else { throw fail("编号或标题超出范围。") }
    let rules: [String: Double] = ["zero": 0, "one": 1, "two": 2, "ten": 10, "hundred": 100, "thousand": 1000]
    let quantities = try entries.map { entry -> Quantity in
      guard let id = entry["id"] as? String, let label = entry["label"] as? String else {
        throw fail("每个数量需要 id、label。")
      }
      if entry["unit"] != nil && !(entry["unit"] is String) { throw fail("unit 必须是字符串。") }
      let unit = (entry["unit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, id.count <= 80, !label.isEmpty, label.count <= 100, (unit?.count ?? 0) <= 24 else {
        throw fail("数量编号、名称或单位超出范围。")
      }
      let variants = [entry["value"] != nil, entry["operation"] != nil || entry["inputs"] != nil,
        entry["rule"] != nil, entry["unknown"] != nil]
      guard variants.filter({ $0 }).count == 1 else { throw fail("\(id) 必须且只能声明原题 value、计算 operation/inputs、规则 rule 或 unknown。") }
      if variants[0] {
        try keys(entry, ["id", "label", "unit", "value", "evidence"])
        guard let number = entry["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let evidence = entry["evidence"] as? String, !evidence.isEmpty, evidence.count <= 500,
          number.doubleValue.isFinite, abs(number.doubleValue) <= 1_000_000_000 else { throw fail("\(id) 的原题 value 必须为数字，并提供 evidence。") }
        guard evidenceContains(number.doubleValue, in: evidence) else {
          throw fail("原题数值来源与声明不一致：value 未出现在 evidence 中；计算所得量必须使用 operation/inputs 从本图原题数量推导。")
        }
        return .init(id: id, label: label, unit: unit, value: number.doubleValue, evidence: evidence,
          operation: nil, inputs: [], rule: nil, unknown: false)
      }
      if variants[1] {
        try keys(entry, ["id", "label", "unit", "operation", "inputs"])
        guard let name = entry["operation"] as? String, let operation = MathDiagram.Operation(rawValue: name),
          let inputs = entry["inputs"] as? [String] else { throw fail("\(id) 需要受支持的 operation 和 inputs 编号数组。") }
        let validCount = operation == .sum ? (2...12).contains(inputs.count) : inputs.count == (operation == .equal ? 1 : 2)
        guard validCount, !inputs.contains(id) else { throw fail("\(id) 的输入数目无效或引用了自身。") }
        return .init(id: id, label: label, unit: unit, value: nil, evidence: nil,
          operation: operation, inputs: inputs, rule: nil, unknown: false)
      }
      if variants[2] {
        try keys(entry, ["id", "label", "unit", "rule"])
        guard let rule = entry["rule"] as? String, rules[rule] != nil, unit == nil || unit == "" else {
          throw fail("\(id) 的规则仅支持无单位 zero、one、two、ten、hundred、thousand。")
        }
        return .init(id: id, label: label, unit: "", value: rules[rule], evidence: "运算规则常数 \(rule)，不是原题数量。",
          operation: nil, inputs: [], rule: rule, unknown: false)
      }
      try keys(entry, ["id", "label", "unit", "unknown"])
      guard let flag = entry["unknown"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue else {
        throw fail("\(id) 的 unknown 必须为 true，不能填写假定值。")
      }
      return .init(id: id, label: label, unit: unit, value: nil, evidence: nil,
        operation: nil, inputs: [], rule: nil, unknown: true)
    }
    guard Set(quantities.map(\.id)).count == quantities.count else { throw fail("数量编号重复。") }
    let identifiers = Set(quantities.map(\.id))
    for quantity in quantities where !Set(quantity.inputs).isSubset(of: identifiers) {
      throw fail("\(quantity.id) 引用了不存在的数量。")
    }
    var compiled: [String: MathDiagram.Fact] = [:]
    var remaining = quantities
    while !remaining.isEmpty {
      let ready = remaining.filter { $0.inputs.allSatisfy { compiled[$0] != nil } }
      guard !ready.isEmpty else { throw fail("计算关系存在循环，必须从原题数量或明确未知量出发。") }
      for quantity in ready {
        if let operation = quantity.operation {
          let sources = quantity.inputs.map { compiled[$0]! }
          let values = sources.compactMap(\.value)
          let known = values.count == sources.count
          if [.quotient, .floorQuotient, .remainder].contains(operation) && sources[1].value == 0 { throw fail("不能除以零。") }
          let inferredUnit = try MathDiagram.inferredUnit(operation, inputs: sources.map(\.unit))
          compiled[quantity.id] = .init(id: quantity.id, label: quantity.label,
            value: known ? MathDiagram.computedValue(operation, inputs: values) : nil,
            unit: quantity.unit ?? inferredUnit, origin: known ? .derived : .unknown)
        } else {
          compiled[quantity.id] = .init(id: quantity.id, label: quantity.label, value: quantity.value,
            unit: quantity.unit ?? "", origin: quantity.unknown ? .unknown : (quantity.rule == nil ? .given : .constant),
            evidence: quantity.evidence)
        }
      }
      let resolved = Set(ready.map(\.id))
      remaining.removeAll { resolved.contains($0.id) }
    }
    var relations = quantities.compactMap { quantity -> MathDiagram.Relation? in
      quantity.operation.map { .init(operation: $0, inputIDs: quantity.inputs, outputID: quantity.id) }
    }
    if let raw = input["checks"] {
      guard let checks = raw as? [[String: Any]] else { throw fail("checks 必须为数组。") }
      for check in checks {
        try keys(check, ["operation", "inputs", "result"])
        guard let name = check["operation"] as? String, let operation = MathDiagram.Operation(rawValue: name),
          let inputs = check["inputs"] as? [String], let result = check["result"] as? String else {
          throw fail("验算需要 operation、inputs 与 result 编号。")
        }
        relations.append(.init(operation: operation, inputIDs: inputs, outputID: result))
      }
    }
    func strings(_ key: String) throws -> [String] {
      guard let raw = input[key] else { return [] }
      guard let array = raw as? [String] else { throw fail("\(key) 必须是字符串数组。") }
      return array
    }
    var parts: [Int] = []
    if let raw = input["parts"] {
      guard let numbers = raw as? [NSNumber], numbers.allSatisfy({
        CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue && (1...20).contains($0.intValue)
      }) else { throw fail("parts 必须为 1 至 20 的整数数组。") }
      parts = numbers.map(\.intValue)
    }
    var rows: [MathDiagram.Row] = []
    if let raw = input["rows"] {
      guard let entries = raw as? [[String: Any]] else { throw fail("rows 必须为数组。") }
      rows = try entries.map { row in
        try keys(row, ["label", "factIDs"])
        guard let label = row["label"] as? String, let ids = row["factIDs"] as? [String] else { throw fail("每行需要 label 和 factIDs。") }
        return .init(label: label, factIDs: ids)
      }
    }
    let diagram = MathDiagram(id: id, title: title, kind: kind,
      facts: quantities.map { compiled[$0.id]! }, relations: relations,
      factIDs: try strings("factIDs"), parts: parts, columns: try strings("columns"), rows: rows)
    try diagram.validate()
    return diagram
  }
  /// Citation consistency only. A matching numeral does not authenticate the
  /// quotation or prove that the quantity was given in the original image.
  static func evidenceContains(_ value: Double, in evidence: String) -> Bool {
    let text = evidence.precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "−", with: "-")
    let pattern = #"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|负?[零〇一二两三四五六七八九十百千万亿]+(?:点[零〇一二两三四五六七八九]+)?"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.numberStyle = .spellOut
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).contains { match in
      guard let range = Range(match.range, in: text) else { return false }
      let token = String(text[range])
      let parsed = Double(token) ?? formatter.number(from: token)?.doubleValue
      return parsed == value
    }
  }
  /// Named semantic slots replace model-authored positional arrays. Native/stored
  /// diagrams retain the old portable shape; these are only incoming bindings.
  private static func layoutMetadata(_ layout: [String: Any], kind: MathDiagram.Kind) throws -> [String: Any] {
    func invalid() -> MathDiagram.ValidationError { .init(message: "图解 layout 缺少所需命名位置，或包含多余字段。") }
    var allowed: Set<String> = []
    var result: [String: Any] = [:]
    func slots(_ names: [String]) throws {
      allowed.formUnion(names)
      let ids = try names.map { name -> String in
        guard let id = layout[name] as? String, !id.isEmpty else { throw invalid() }
        return id
      }
      result["factIDs"] = ids
    }
    func field(_ name: String) throws {
      allowed.insert(name)
      guard let value = layout[name] else { throw invalid() }
      result[name] = value
    }
    switch kind {
    case .barComparison, .equalParts:
      allowed.insert("items")
      guard let ids = layout["items"] as? [String] else { throw invalid() }
      result["factIDs"] = ids
      if kind == .equalParts { try field("parts") }
    case .state:
      allowed.insert("states")
      guard let ids = layout["states"] as? [String] else { throw invalid() }
      result["factIDs"] = ids
    case .table: try field("columns"); try field("rows")
    case .area: try slots(["length", "width", "area"])
    case .interval: try slots(["start", "end", "gaps", "per", "total"])
    case .balance: try slots(["high", "low", "mean", "transfer"])
    case .partWhole:
      try slots(["whole"])
      allowed.insert("portions")
      guard let ids = layout["portions"] as? [String] else { throw invalid() }
      result["factIDs"] = (result["factIDs"] as! [String]) + ids
    case .venn:
      var names = ["leftOnly", "intersection", "rightOnly", "union"]
      if layout["outside"] != nil || layout["total"] != nil { names += ["outside", "total"] }
      try slots(names)
    case .cycle:
      try slots(["count", "period", "cycles", "remainder"])
      allowed.insert("labels")
      guard let labels = layout["labels"] as? [String] else { throw invalid() }
      result["columns"] = labels
    }
    guard Set(layout.keys) == allowed else { throw invalid() }
    return result
  }

}
