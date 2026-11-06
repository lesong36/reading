import Foundation

/// Portable semantic diagram. Coordinates and executable drawing code are deliberately absent.
struct MathDiagram: Codable, Sendable, Equatable {
  static let schemaVersion = 1
  enum Kind: String, Codable, Sendable { case barComparison = "bar_comparison", equalParts = "equal_parts", state, table, area, interval, partWhole = "part_whole", venn, balance, cycle }
  enum Origin: String, Codable, Sendable { case given, derived, unknown, constant }
  enum Operation: String, Codable, Sendable { case sum, difference, product, quotient, equal, floorQuotient = "floor_quotient", remainder }
  struct Fact: Codable, Sendable, Equatable {
    var id: String
    var label: String
    var value: Double?
    var unit: String
    var origin: Origin
    var evidence: String?
    init(id: String, label: String, value: Double? = nil, unit: String = "", origin: Origin = .given, evidence: String? = nil) {
      self.id = id; self.label = label; self.value = value; self.unit = unit; self.origin = origin; self.evidence = evidence
    }
  }
  struct Relation: Codable, Sendable, Equatable {
    var operation: Operation
    var inputIDs: [String]
    var outputID: String
    init(operation: Operation, inputIDs: [String], outputID: String) {
      self.operation = operation; self.inputIDs = inputIDs; self.outputID = outputID
    }
  }
  struct Row: Codable, Sendable, Equatable {
    var label: String
    var factIDs: [String]
  }
  var id: String
  var title: String
  var kind: Kind
  var facts: [Fact]
  var relations: [Relation]
  var factIDs: [String]
  var parts: [Int]
  var columns: [String]
  var rows: [Row]

  init(id: String, title: String, kind: Kind, facts: [Fact], relations: [Relation], factIDs: [String] = [], parts: [Int] = [], columns: [String] = [], rows: [Row] = []) {
    self.id = id; self.title = title; self.kind = kind; self.facts = facts; self.relations = relations
    self.factIDs = factIDs; self.parts = parts; self.columns = columns; self.rows = rows
  }

  enum CodingKeys: String, CodingKey { case id, title, kind, facts, relations, factIDs, parts, columns, rows }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
    kind = try c.decode(Kind.self, forKey: .kind); facts = try c.decode([Fact].self, forKey: .facts)
    relations = try c.decode([Relation].self, forKey: .relations)
    factIDs = try c.decodeIfPresent([String].self, forKey: .factIDs) ?? []
    parts = try c.decodeIfPresent([Int].self, forKey: .parts) ?? []
    columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
    rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
  }

  struct ValidationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
  }

  func fact(_ id: String) -> Fact? { facts.first { $0.id == id } }

  /// Internal consistency only: evidence is not a substitute for inspecting the original question.
  func validate() throws {
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw ValidationError(message: message) } }
    func short(_ text: String, _ limit: Int) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit }
    try require(short(id, 80) && short(title, 120), "图形编号或标题无效。")
    try require((1...32).contains(facts.count) && (1...32).contains(relations.count), "图形必须包含有限的事实与数量关系。")
    try require(Set(facts.map(\.id)).count == facts.count, "图形事实编号重复。")
    for fact in facts {
      try require(short(fact.id, 80) && short(fact.label, 100) && fact.unit.count <= 24, "事实编号、名称或单位无效。")
      if let value = fact.value {
        try require(value.isFinite && abs(value) <= 1_000_000_000, "数量必须是有限且在支持范围内的数值。")
        try require(Self.scaledInteger(value) != nil, "当前图解支持最多六位的有限小数；分数需要单独处理。")
        if ["人", "本", "张", "只", "个", "辆", "棵", "头", "袋", "套", "箱", "件", "枝", "级"].contains(fact.unit.trimmingCharacters(in: .whitespacesAndNewlines)) {
          try require(value >= 0 && value.rounded() == value, "可数数量必须是非负整数。")
        }
      }
      if fact.origin == .unknown { try require(fact.value == nil, "未知量不能填入假定数值。") }
      else { try require(fact.value != nil, "已知量或推得量缺少数值。") }
      if fact.origin == .given { try require(short(fact.evidence ?? "", 500), "已知量缺少原题来源说明。") }
      if fact.origin == .constant {
        let description = "常数事实 \(fact.id)（\(fact.label)）"
        try require([0.0, 1, 2, 10, 100, 1000].contains(fact.value ?? .nan),
          "\(description)的数值不在允许范围内。运算常数仅支持 0、1、2、10、100、1000；计算得到的数应标为 derived 并提供推导关系，原题数量应标为 given 并提供原题来源。")
        try require(Self.unitPowers(fact.unit).isEmpty,
          "\(description)带有单位“\(fact.unit)”。运算常数必须无单位；份数或倍数用空单位，实际数量应使用 given 或 derived。")
        try require(short(fact.evidence ?? "", 500),
          "\(description)缺少规则说明，不能当作原题条件。")
      }
    }
    let lookup = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
    for relation in relations {
      let count = relation.operation == .sum ? (2...12).contains(relation.inputIDs.count) : relation.inputIDs.count == (relation.operation == .equal ? 1 : 2)
      try require(count, "数量关系的输入数目无效。")
      try require(!relation.inputIDs.contains(relation.outputID), "关系不能将输出自身作为输入。")
      guard let output = lookup[relation.outputID] else {
        throw ValidationError(message: "关系引用了不存在的输出事实：\(relation.outputID)。可用事实编号：\(facts.map(\.id).joined(separator: "、"))。")
      }
      let inputs = relation.inputIDs.compactMap { lookup[$0] }
      let missingInputs = relation.inputIDs.filter { lookup[$0] == nil }
      try require(missingInputs.isEmpty, "关系引用了不存在的输入事实：\(missingInputs.joined(separator: "、"))。可用事实编号：\(facts.map(\.id).joined(separator: "、"))。")
      let units = inputs.map { Self.unitPowers($0.unit) }
      let outputUnit = Self.unitPowers(output.unit)
      switch relation.operation {
      case .sum, .difference, .equal:
        try require(units.allSatisfy { $0 == outputUnit }, "加减或相等关系的单位不一致。")
      case .floorQuotient, .remainder:
        try require(units[0] == units[1] && (relation.operation == .floorQuotient ? outputUnit.isEmpty : outputUnit == units[0]), "整除与余数关系的单位不一致。")
      case .product, .quotient:
        var expected = units[0]
        for (unit, exponent) in units[1] { expected[unit, default: 0] += (relation.operation == .product ? exponent : -exponent) }
        expected = expected.filter { $0.value != 0 }
        let expression = inputs.map { "\($0.label)〔\($0.unit.isEmpty ? "无单位" : $0.unit)〕" }
          .joined(separator: relation.operation == .product ? " × " : " ÷ ")
        try require(expected == outputUnit,
          "乘除关系的单位不一致：\(expression) → \(output.label)〔\(output.unit.isEmpty ? "无单位" : output.unit)〕。请核对单价、时间与总量的单位。")
      }
      if [.quotient, .floorQuotient, .remainder].contains(relation.operation), inputs[1].value == 0 { throw ValidationError(message: "不能除以零。") }
      if [.floorQuotient, .remainder].contains(relation.operation) {
        try require(inputs.allSatisfy { $0.value.map { $0 >= 0 && $0.rounded() == $0 } ?? false }
          && (inputs[1].value ?? 0) > 0, "整除与余数只能用于非负整数和正整数除数。")
      }
      if relation.operation == .quotient, let numerator = inputs[0].value, let denominator = inputs[1].value {
        try require(Self.hasSupportedDecimalQuotient(numerator, denominator), "此除法需要精确分数或更多小数位，当前图解不能将近似值作为精确值。")
      }
      if let result = output.value, inputs.allSatisfy({ $0.value != nil }) {
        let values = inputs.map { $0.value! }
        let expected = Self.computedValue(relation.operation, inputs: values)
        let symbol: String
        switch relation.operation {
        case .sum: symbol = "+"
        case .difference: symbol = "−"
        case .product: symbol = "×"
        case .quotient: symbol = "÷"
        case .equal: symbol = "="
        case .floorQuotient: symbol = "整除"
        case .remainder: symbol = "余数"
        }
        let expression = inputs.map { "\($0.label)(\($0.value!))" }.joined(separator: " \(symbol) ")
        try require(expected.isFinite && abs(expected - result) <= max(0.000001, abs(expected).ulp * 8),
          "图形数量关系的算术不成立：\(expression) 应得 \(expected)，但“\(output.label)”声明为 \(result)。检查输入引用；多步运算要拆为中间量及独立关系，不修改原题条件。")
      }
    }
    // Derived numbers require a grounded acyclic chain, rather than a circular self-justification.
    var grounded = Set(facts.filter { $0.origin == .given || $0.origin == .constant }.map(\.id))
    for _ in 0..<facts.count {
      for relation in relations where relation.inputIDs.allSatisfy({ grounded.contains($0) }) {
        if lookup[relation.outputID]?.origin == .derived { grounded.insert(relation.outputID) }
      }
    }
    let ungrounded = facts.filter { $0.origin == .derived && !grounded.contains($0.id) }
    try require(ungrounded.isEmpty, "推得量缺少从原题已知量出发的推导：" + ungrounded.map(\.label).joined(separator: "、") + "。")
    let displayed = kind == .table ? rows.flatMap(\.factIDs) : factIDs
    try require(!displayed.isEmpty && displayed.allSatisfy { lookup[$0] != nil }, "图形引用了不存在的事实。")
    let related = Set(relations.flatMap { $0.inputIDs + [$0.outputID] })
    let unrelated = displayed.filter { !related.contains($0) }.compactMap { lookup[$0]?.label }
    try require(unrelated.isEmpty, "图形中的数量缺少对应关系：" + unrelated.joined(separator: "、") + "。")
    switch kind {
    case .barComparison, .equalParts:
      try require((2...8).contains(factIDs.count) && Set(factIDs).count == factIDs.count, "线段图需要 2 至 8 个不同数量。")
      try require(factIDs.allSatisfy { lookup[$0]?.value.map { $0 >= 0 } ?? true }, "线段图数量不能为负。")
      let lineUnit = Self.unitPowers(lookup[factIDs[0]]!.unit)
      try require(factIDs.allSatisfy { Self.unitPowers(lookup[$0]!.unit) == lineUnit }, "同一线段图的数量单位必须一致。")
      if kind == .equalParts {
        try require(parts.count == factIDs.count && parts.allSatisfy { (1...20).contains($0) }, "等份图需要与数量对应的 1 至 20 份。")
        var unitPart: Double?
        for (index, factID) in factIDs.enumerated() {
          if let value = lookup[factID]?.value {
            let part = value / Double(parts[index])
            if let previous = unitPart { try require(abs(previous - part) <= 0.000001, "等份线段图的每份数量不一致。") }
            else { unitPart = part }
          }
        }
        if factIDs.contains(where: { lookup[$0]?.value == nil }) {
          let baseIndex = parts.indices.min(by: { parts[$0] < parts[$1] })!
          let baseID = factIDs[baseIndex]
          for index in factIDs.indices where index != baseIndex {
            let ratio = Double(parts[index]) / Double(parts[baseIndex])
            let id = factIDs[index]
            let supported = relations.contains { relation in
              if parts[index] == parts[baseIndex], relation.operation == .equal {
                return relation.inputIDs == [baseID] && relation.outputID == id
                  || relation.inputIDs == [id] && relation.outputID == baseID
              }
              let product = relation.operation == .product && relation.outputID == id
                && relation.inputIDs.contains(baseID)
              let quotient = relation.operation == .quotient && relation.outputID == baseID
                && relation.inputIDs.first == id
              guard product || quotient else { return false }
              let multiplierID = relation.inputIDs.first { $0 != (product ? baseID : id) }
              guard let multiplierID, let multiplier = lookup[multiplierID],
                multiplier.origin == .given || multiplier.origin == .constant,
                Self.unitPowers(multiplier.unit).isEmpty, let value = multiplier.value
              else { return false }
              return abs(value - ratio) <= 0.000001
            }
            try require(supported, "未知量的等份比例缺少原题倍数或相等关系依据：\(lookup[id]!.label)。")
          }
        }
      } else { try require(parts.isEmpty, "比较线段图不使用等份字段。") }
      try require(columns.isEmpty && rows.isEmpty, "线段图包含了其他模板的字段。")
    case .state:
      try require((2...6).contains(factIDs.count) && Set(factIDs).count == factIDs.count, "状态图需要 2 至 6 个不同状态。")
      for index in 1..<factIDs.count {
        let prior = factIDs[index - 1], next = factIDs[index]
        try require(relations.contains { $0.outputID == next && $0.inputIDs.contains(prior) }, "相邻状态缺少连续的变化关系。")
      }
      try require(parts.isEmpty && columns.isEmpty && rows.isEmpty, "状态图包含了其他模板的字段。")
    case .table:
      try require((1...6).contains(columns.count) && (1...12).contains(rows.count), "表格列数或行数超出范围。")
      try require(columns.allSatisfy { short($0, 60) } && rows.allSatisfy { short($0.label, 100) && $0.factIDs.count == columns.count }, "表格名称或列数不一致。")
      try require(factIDs.isEmpty && parts.isEmpty, "表格包含了其他模板的字段。")
    case .area:
      try require(factIDs.count == 3 && Set(factIDs).count == 3, "面积图需要长、宽、面积三个不同事实。")
      try require(factIDs.allSatisfy { lookup[$0]?.value.map { $0 > 0 } ?? false }, "面积图需要正的已知尺寸。")
      let a = factIDs[0], b = factIDs[1], total = factIDs[2]
      // Rate × time and price × count use the same rectangle. A grounded
      // quotient already proves the inverse product; no redundant check is needed.
      try require(relations.contains {
        $0.operation == .product && Set($0.inputIDs) == Set([a, b]) && $0.outputID == total
          || $0.operation == .quotient && $0.inputIDs == [total, a] && $0.outputID == b
          || $0.operation == .quotient && $0.inputIDs == [total, b] && $0.outputID == a
      }, "面积图缺少两个因子与乘积之间的乘法或逆向除法关系。")
      try require(parts.isEmpty || (parts.count == 2 && parts.allSatisfy { (1...20).contains($0) }), "面积分块需要两个 1 至 20 的整数切分位置。")
      if parts.count == 2 { try require(Double(parts[0]) < lookup[factIDs[0]]!.value! && Double(parts[1]) < lookup[factIDs[1]]!.value!, "面积切分位置必须在长宽范围内。") }
      try require(columns.isEmpty && rows.isEmpty, "面积图包含了其他模板的字段。")
    case .interval:
      try require(factIDs.count == 5 && Set(factIDs).count == 5, "间隔图需要按起点、终点、间隔数、每段数量、总数量顺序引用五个不同事实。")
      let start = lookup[factIDs[0]]!, end = lookup[factIDs[1]]!, count = lookup[factIDs[2]]!
      let per = lookup[factIDs[3]]!, total = lookup[factIDs[4]]!
      let originalEndpoints = start.origin == .given && end.origin == .given
      let measuredEndpoints = start.origin == .constant && start.value == 0 && end.origin == .derived
        && total.origin == .given && relations.contains {
          $0.operation == .quotient && $0.inputIDs == [total.id, per.id] && $0.outputID == end.id
        }
      try require((originalEndpoints || measuredEndpoints) && per.origin == .given,
        "间隔图需原题起终点，或原题总长度除以间距得到的端点及零起点规则。")
      try require([start, end, count].allSatisfy { fact in
        Self.unitPowers(fact.unit).isEmpty && fact.value.map { $0.rounded() == $0 } == true
      }, "间隔图的起点序号、终点序号及间隔数必须是无单位整数；楼层等位置名称写在 label 中。")
      try require(count.origin == .derived && (1...1000).contains(count.value ?? 0), "间隔数必须是 1 至 1000 的推得整数。")
      try require(per.value.map { $0 > 0 } == true && (total.origin == .derived || measuredEndpoints),
        "每段数量必须为正，总数量必须为推得量。")
      try require(relations.contains { $0.operation == .difference && $0.inputIDs == [end.id, start.id] && $0.outputID == count.id },
        "间隔图缺少终点序号减起点序号等于间隔数的关系。")
      try require(relations.contains { $0.operation == .product && Set($0.inputIDs) == Set([count.id, per.id]) && $0.outputID == total.id },
        "间隔图缺少间隔数乘每段数量等于总数量的关系。")
      try require(parts.isEmpty && columns.isEmpty && rows.isEmpty, "间隔图包含了其他模板的字段。")
    case .partWhole:
      try require((3...7).contains(factIDs.count) && Set(factIDs).count == factIDs.count,
        "整体分段图需要整体及二至六个部分。")
      let displayed = factIDs.map { lookup[$0]! }
      let unit = Self.unitPowers(displayed[0].unit)
      try require(displayed.allSatisfy { Self.unitPowers($0.unit) == unit && ($0.value.map { $0 >= 0 } ?? true) },
        "整体与部分必须同单位、非负。")
      try require(relations.contains { $0.operation == .sum && $0.outputID == factIDs[0]
        && $0.inputIDs == Array(factIDs.dropFirst()) }, "整体分段图需要各部分之和等于整体的关系。")
      try require(parts.isEmpty && columns.isEmpty && rows.isEmpty, "整体分段图包含其他模板字段。")
    case .venn:
      try require([4, 6].contains(factIDs.count) && Set(factIDs).count == factIDs.count,
        "韦恩图按仅左、交集、仅右、并集排列，可加圈外、总量。")
      let displayed = factIDs.map { lookup[$0]! }
      let unit = Self.unitPowers(displayed[0].unit)
      try require(displayed.allSatisfy { Self.unitPowers($0.unit) == unit && $0.value.map { $0 >= 0 } == true },
        "韦恩图需要同单位的非负已知区域数量。")
      try require(relations.contains { $0.operation == .sum && $0.inputIDs == Array(factIDs.prefix(3)) && $0.outputID == factIDs[3] },
        "韦恩图需要三个区域相加等于并集。")
      if factIDs.count == 6 {
        try require(relations.contains { $0.operation == .sum && $0.inputIDs == Array(factIDs[3...4]) && $0.outputID == factIDs[5] },
          "韦恩图需要并集与圈外相加等于总量。")
      }
      try require(parts.isEmpty && columns.isEmpty && rows.isEmpty, "韦恩图包含其他模板字段。")
    case .balance:
      try require(factIDs.count == 4 && Set(factIDs).count == 4,
        "平均移量图按较大量、较小量、平均量、移动量引用。")
      let displayed = factIDs.map { lookup[$0]! }
      let unit = Self.unitPowers(displayed[0].unit)
      try require(displayed.allSatisfy { Self.unitPowers($0.unit) == unit && $0.value.map { $0 >= 0 } == true },
        "平均移量图需要同单位非负已知数量。")
      let values = displayed.map { $0.value! }
      try require(values[0] >= values[1] && abs((values[0] + values[1]) / 2 - values[2]) <= 0.000001
        && abs((values[0] - values[1]) / 2 - values[3]) <= 0.000001,
        "平均移量应为和的一半，移动量应为差的一半。")
      try require(parts.isEmpty && columns.isEmpty && rows.isEmpty, "平均移量图包含其他模板字段。")
    case .cycle:
      try require(factIDs.count == 4 && Set(factIDs).count == 4,
        "周期图按总项数、周期项数、完整周期数、余项数引用。")
      let displayed = factIDs.map { lookup[$0]! }
      try require(displayed.allSatisfy { Self.unitPowers($0.unit).isEmpty && $0.value.map { $0 >= 0 && $0.rounded() == $0 } == true },
        "周期图需要无单位非负整数。")
      let values = displayed.map { $0.value! }
      try require((1...1000).contains(values[0]) && (1...12).contains(values[1])
        && values[2] == floor(values[0] / values[1]) && values[3] == values[0].truncatingRemainder(dividingBy: values[1]),
        "周期数与余项数必须与整除和余数一致。")
      try require(relations.contains { $0.operation == .floorQuotient && $0.inputIDs == Array(factIDs.prefix(2)) && $0.outputID == factIDs[2] }
        && relations.contains { $0.operation == .remainder && $0.inputIDs == Array(factIDs.prefix(2)) && $0.outputID == factIDs[3] },
        "周期图缺少从总项数与周期项数出发的整除及余数依据。")
      try require(columns.count == Int(values[1]) && columns.allSatisfy { short($0, 30) }
        && parts.isEmpty && rows.isEmpty, "周期图需要每一项名称，且不使用其他模板字段。")
    }
  }

  /// Both incoming plans and stored graph validation use the same arithmetic.
  /// Callers validate the operation's arity and division denominator first.
  static func computedValue(_ operation: Operation, inputs: [Double]) -> Double {
    let result: Double
    switch operation {
    case .sum: result = inputs.reduce(0, +)
    case .difference: result = inputs[0] - inputs[1]
    case .product: result = inputs[0] * inputs[1]
    case .quotient: result = inputs[0] / inputs[1]
    case .equal: result = inputs[0]
    case .floorQuotient: result = floor(inputs[0] / inputs[1])
    case .remainder: result = inputs[0].truncatingRemainder(dividingBy: inputs[1])
    }
    // Remove binary floating-point noise only within a few ULPs. Never round an
    // unsupported exact fraction or a genuinely smaller-than-six-decimal result.
    let scaled = result * 1_000_000
    if result.isFinite && abs(scaled - scaled.rounded()) <= scaled.ulp * 8 {
      return scaled.rounded() / 1_000_000
    }
    return result
  }

  static func inferredUnit(_ operation: Operation, inputs: [String]) throws -> String {
    guard !inputs.isEmpty, inputs.allSatisfy({ $0.count <= 24 }) else {
      throw ValidationError(message: "单位超出支持范围。")
    }
    let units = inputs.map(unitPowers)
    if operation == .floorQuotient || operation == .remainder {
      guard units.count == 2 && units[0] == units[1] else { throw ValidationError(message: "整除与余数关系的单位不一致。") }
      return operation == .floorQuotient ? "" : inputs[0]
    }
    if operation == .sum || operation == .difference || operation == .equal {
      guard units.allSatisfy({ $0 == units[0] }) else {
        throw ValidationError(message: "加减或相等关系的单位不一致。")
      }
      return inputs[0]
    }
    var result = units[0]
    for (name, exponent) in units[1] {
      result[name, default: 0] += operation == .product ? exponent : -exponent
    }
    result = result.filter { $0.value != 0 }
    guard result.values.allSatisfy({ abs($0) <= 4 }), result.values.reduce(0, { $0 + abs($1) }) <= 8 else {
      throw ValidationError(message: "推得单位维度超出支持范围。")
    }
    func terms(positive: Bool) -> String {
      result.keys.sorted().flatMap { name -> [String] in
        let exponent = result[name]!
        guard (exponent > 0) == positive else { return [] }
        if abs(exponent) == 2 { return [name + "²"] }
        return Array(repeating: name, count: abs(exponent))
      }.joined(separator: "*")
    }
    let numerator = terms(positive: true), denominator = terms(positive: false)
    let inferred = denominator.isEmpty ? numerator : (numerator.isEmpty ? "1" : numerator) + "/" + denominator
    guard inferred.count <= 24 else { throw ValidationError(message: "推得单位超出支持范围。") }
    return inferred
  }

  private static func scaledInteger(_ value: Double) -> Int64? {
    guard value.isFinite, abs(value) <= 1_000_000_000 else { return nil }
    let scaled = value * 1_000_000
    guard abs(scaled - scaled.rounded()) <= scaled.ulp * 8 else { return nil }
    return Int64(scaled.rounded())
  }

  private static func hasSupportedDecimalQuotient(_ numerator: Double, _ denominator: Double) -> Bool {
    guard let a = scaledInteger(numerator), let b = scaledInteger(denominator), b != 0 else { return false }
    var x = abs(a), y = abs(b)
    while y != 0 { let remainder = x % y; x = y; y = remainder }
    var reduced = abs(b) / x
    var twos = 0, fives = 0
    while reduced % 2 == 0 { reduced /= 2; twos += 1 }
    while reduced % 5 == 0 { reduced /= 5; fives += 1 }
    return reduced == 1 && max(twos, fives) <= 6
  }

  private static func unitPowers(_ original: String) -> [String: Int] {
    var unit = original.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "*")
    for (from, to) in [("平方厘米", "cm²"), ("平方千米", "km²"), ("平方米", "m²"), ("厘米", "cm"), ("千米", "km"), ("米", "m"), ("千克", "kg"), ("克", "g")] { unit = unit.replacingOccurrences(of: from, with: to) }
    if unit.isEmpty || unit == "1" || unit == "倍" { return [:] }
    var result: [String: Int] = [:]
    for (index, group) in unit.components(separatedBy: "/").enumerated() {
      for raw in group.components(separatedBy: "*") where !raw.isEmpty && raw != "1" {
        let squared = raw.hasSuffix("²") || raw.hasSuffix("^2")
        let token = squared ? String(raw.dropLast(raw.hasSuffix("²") ? 1 : 2)) : raw
        // Exact aliases share a dimension; distinct time scales are not interchangeable.
        let name = ["分": "分钟", "min": "分钟" ][token] ?? token
        result[name, default: 0] += (index == 0 ? 1 : -1) * (squared ? 2 : 1)
      }
    }
    return result.filter { $0.value != 0 }
  }
}
