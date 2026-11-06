import CoreGraphics
import Foundation

/// Separates the readable answer from a bounded, inert diagram payload.
enum MathDiagramAnswer {
  struct Result: Sendable, Equatable {
    var text: String
    var diagrams: [MathDiagram]
    var failure: String?
    var hasDiagramBlock: Bool
  }
  private struct Envelope: Decodable { let schemaVersion: Int; let diagrams: [MathDiagram] }
  private struct Version: Decodable { let schemaVersion: Int }
  static let marker = "```math-diagrams"

  static func displayText(_ answer: String) -> String {
    if let start = blockStart(answer) { return String(answer[..<start]).trimmingCharacters(in: .whitespacesAndNewlines) }
    // Streaming may stop in the middle of the marker. Hide only a matching final line.
    let tail = answer.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    let trimmed = tail.trimmingCharacters(in: .whitespaces)
    let preceding = String(answer.dropLast(tail.count))
    let openFenceCount = preceding.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
    if openFenceCount % 2 == 0 && trimmed.hasPrefix("```") && marker.hasPrefix(trimmed) {
      return String(answer.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return answer
  }

  static func parse(_ answer: String) -> Result {
    guard let start = blockStart(answer) else {
      let tail = answer.split(separator: "\n", omittingEmptySubsequences: false).last?.trimmingCharacters(in: .whitespaces) ?? ""
      let partialMath = tail.hasPrefix("```m") && marker.hasPrefix(tail)
      let visible = partialMath ? displayText(answer) : answer
      return .init(text: visible, diagrams: [], failure: visible == answer ? nil : "图解数据未完整返回。", hasDiagramBlock: visible != answer)
    }
    let text = String(answer[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
    func failure(_ message: String) -> Result { .init(text: text, diagrams: [], failure: message, hasDiagramBlock: true) }
    let afterMarker = answer.index(start, offsetBy: marker.count)
    let remainder = answer[afterMarker...]
    guard remainder.first == "\n" || remainder.first == "\r" else { return failure("图解数据块格式无效。") }
    guard let close = remainder.range(of: "```"), remainder[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return failure("图解数据未完整返回，或数据块不是回答的结尾。")
    }
    let json = remainder[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = json.data(using: .utf8), data.count <= 150_000 else { return failure("图解数据超过支持范围。") }
    do {
      let object = try JSONSerialization.jsonObject(with: data)
      guard JSONSerialization.isValidJSONObject(object) else { return failure("图解数据必须包含有限的 JSON 数值，不能使用溢出指数或无穷大。") }
      guard let envelope = object as? [String: Any], Set(envelope.keys).isSubset(of: ["schemaVersion", "diagrams"]),
        let entries = envelope["diagrams"] as? [[String: Any]] else { return failure("图解需要对象格式及规定字段。") }
      guard try JSONDecoder().decode(Version.self, from: data).schemaVersion == MathDiagram.schemaVersion else { return failure("暂不支持此图解数据版本。") }
      let ids = entries.compactMap { $0["id"] as? String }
      guard (1...3).contains(entries.count), ids.count == entries.count, Set(ids).count == entries.count else {
        return failure("需要 1 至 3 个编号不同的图解。")
      }
      var diagrams: [MathDiagram] = [], errors: [String] = []
      // Every diagram has its own quantity scope. A bad extra diagram must not
      // erase independently verified pictures, nor supply facts to another one.
      for (index, entry) in entries.enumerated() {
        do {
          let single = try JSONSerialization.data(withJSONObject: ["schemaVersion": MathDiagram.schemaVersion, "diagrams": [entry]])
          let normalized = try MathDiagramRecipe.normalizedEnvelope(single)
          try rejectUnknownFields(normalized)
          let diagram = try JSONDecoder().decode(Envelope.self, from: normalized).diagrams[0]
          try validateRendering(diagram)
          diagrams.append(diagram)
        } catch let error as MathDiagram.ValidationError { errors.append("图解\(index + 1)：\(error.message)") }
        catch let error as DecodingError { errors.append("图解\(index + 1)：\(decodingFailure(error))") }
        catch { errors.append("图解\(index + 1)：数据格式无效，未显示未经检查的图形。") }
      }
      return .init(text: text, diagrams: diagrams, failure: errors.isEmpty ? nil : errors.joined(separator: "\n"), hasDiagramBlock: true)
    } catch let error as MathDiagram.ValidationError { return failure(error.message) }
    catch let error as DecodingError { return failure(decodingFailure(error)) }
    catch { return failure("图解数据格式无效，未显示未经检查的图形。") }
  }

  private static func decodingFailure(_ error: DecodingError) -> String {
    func path(_ keys: [CodingKey]) -> String {
      keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
    switch error {
    case .keyNotFound(let key, let context):
      let location = path(context.codingPath + [key])
      let components = context.codingPath.map(\.stringValue)
      if components.contains("relations") {
        return "图解字段 \(location) 缺失；每条关系必须包含 operation、inputIDs、outputID；outputID 必须引用本图已声明的事实编号。"
      }
      if components.contains("difference") || key.stringValue == "difference" {
        return "图解字段 \(location) 缺失；差倍图的 difference 必须包含原题差数 value、unit、evidence；无单位也要写 unit:\"\"。"
      }
      if components.contains("multiplier") || key.stringValue == "multiplier" {
        return "图解字段 \(location) 缺失；差倍图的 multiplier 必须包含原题倍数 value、evidence。"
      }
      if components.contains("facts") {
        return "图解字段 \(location) 缺失；事实必须包含 id、label、unit、origin；无单位也要写 unit:\"\"。"
      }
      return "图解字段 \(location) 缺失；请补齐此对象对应协议的必填字段。"
    case .typeMismatch(let type, let context):
      return "图解字段 \(path(context.codingPath)) 类型无效；\(type == Double.self ? "value 必须为 JSON 数字，未知量省略 value。" : "请使用规定的对象、数组或字符串格式。")"
    case .valueNotFound(_, let context):
      return "图解字段 \(path(context.codingPath)) 不能为空；仅未知量可省略 value。"
    case .dataCorrupted(let context):
      return context.codingPath.isEmpty
        ? "图解需要严格 JSON，不能包含注释、尾逗号或无效转义。"
        : "图解字段 \(path(context.codingPath)) 值无效；kind、origin、operation 只能采用约定名称。"
    @unknown default: return "图解 JSON 字段格式无效。"
    }
  }

  /// Validate the narrowest supported screen layout and the actual A4 appendix layout.
  /// This runs before accepting model output so an illegible diagram gets the same repair
  /// opportunity as an arithmetic error, rather than failing later during saving/export.
  static func validateRendering(_ diagram: MathDiagram) throws {
    _ = try MathDiagramRenderer.size(diagram, width: 360)
    _ = try MathDiagramRenderer.size(diagram, width: 900)
    let pdfSize = try MathDiagramRenderer.size(diagram, width: 507.28)
    guard min(1, 645 / pdfSize.height) >= 0.65 else {
      throw MathDiagram.ValidationError(message: "图解内容过长，无法在 PDF 中清楚显示，请精简或拆分图解。")
    }
  }

  private static func blockStart(_ answer: String) -> String.Index? {
    var search = answer.startIndex
    while let range = answer.range(of: marker, range: search..<answer.endIndex) {
      let lineStart = answer[..<range.lowerBound].lastIndex(of: "\n").map { answer.index(after: $0) } ?? answer.startIndex
      if answer[lineStart..<range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty { return range.lowerBound }
      search = range.upperBound
    }
    return nil
  }

  private static func rejectUnknownFields(_ data: Data) throws {
    func keys(_ object: [String: Any], allowed: Set<String>) throws {
      guard Set(object.keys).isSubset(of: allowed) else { throw MathDiagram.ValidationError(message: "图解包含未支持的字段。") }
    }
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MathDiagram.ValidationError(message: "图解需要对象格式。") }
    try keys(envelope, allowed: ["schemaVersion", "diagrams"])
    for diagram in envelope["diagrams"] as? [[String: Any]] ?? [] {
      try keys(diagram, allowed: ["id", "title", "kind", "facts", "relations", "factIDs", "parts", "columns", "rows"])
      for fact in diagram["facts"] as? [[String: Any]] ?? [] { try keys(fact, allowed: ["id", "label", "value", "unit", "origin", "evidence"]) }
      for relation in diagram["relations"] as? [[String: Any]] ?? [] { try keys(relation, allowed: ["operation", "inputIDs", "outputID"]) }
      for row in diagram["rows"] as? [[String: Any]] ?? [] { try keys(row, allowed: ["label", "factIDs"]) }
    }
  }

  static var instructions: String { prompt }

  /// The caller has selected the difference/ratio method; do not include the broad
  /// free-form graph protocol for a problem supported by this deterministic recipe.
  static let differenceRatioPrompt = """
    本次使用差倍方法与真正渲染的等份线段图。依据原截图和用户本次请求，逐题编号解释原题条件、数量关系、计算过程与验算，再在回答最后附加一个独立的 ```math-diagrams 数据块。处理原图中符合本次请求的各道题；用户指定只解某题时严格遵守该范围。每道题独立使用自己的差数、倍数、单位与来源，不混合不同题目的条件。最多附三张图，超过时明确说明图解数量限制。
    差倍图只使用下面的配方协议，不编写自由格式事实或关系。原题条件不足、倍数不是支持的整数或本题不适合差倍法时，明确说明缺失条件或限制，不编造配方。
    \(differenceRatioDataContract)
    """

  /// The model extracts original conditions; the client owns arithmetic,
  /// unit propagation and layout. No free-form graph or second model call is needed.
  static func distributionPrompt(view: MathDiagram.Kind) -> String {
    """
    先根据原截图和用户请求说明题面、数量关系、步骤及验算。在回答最后附一个独立的 ```math-diagrams 数据块。
    仅在同一批物品、同一组接收者、两个不同每份分配量的条件下使用两次分配配方。确认份数与总量均不变；不同班人数、不同批物品或条件不足时不能套用，说明限制，不补造条件。每题独立编号，最多三图，不混合题目或方法例题数字。
    数据为严格JSON：{"schemaVersion":1,"diagrams":[配方对象]}。
    \(distributionDataContract(view: view))
    """
  }

  static func distributionDataContract(view: MathDiagram.Kind) -> String {
    """
    配方必填 id、title、kind:"two_allocations"、item_unit（物品单位）、recipient_unit（接收者单位）、allocations（恰好两个原题分配条件），view固定"\(view == .barComparison ? "bar_comparison" : "table")"。仅用于同批物品和同组接收者的两次不同每份量分配，总量与份数不变；不同批或组不能套用。
    每个分配条件只有 per_recipient:{"value":原题每份量数字,"evidence":"原题对应条件"} 和 balance:{"kind":"余缺类型","value":原题余缺数字,"evidence":"原题对应条件"}。
    balance.kind只选surplus（剩余物品量）、shortfall（缺少物品量）、extra_recipients（剩余还能按此次每份量发给多少接收者）、missing_recipients（按此次每份量还有多少接收者没分到）、exact（原题明确正好发完）。exact只填写kind和evidence，禁止填写value；其余value为原题非负数字，不能填写算出的结果。必须区分剩余张数和剩余可发人数，不能把人数直接当张数。不能从未核验的助手答案反推原题。
    item_unit只支持张、本、个、只、袋、箱、件、枝、元、千克、米；recipient_unit只支持人、个、组、班、只、辆，两种单位不能相同。不要在内部对象填写unit、答案、运算、编号、关系或布局。程序将自行推导每份差、总差、接收者数量和总量，并画出两种分配的对照。人数不为正整数或条件矛盾会拒绝绘图，不四舍五入。
    """
  }

  /// One focused repair request: the image remains the source of truth, while the
  /// original answer is preserved by the caller instead of becoming a given fact.
  static func differenceRatioRepairPrompt(question: String) -> String {
    """
    用户本次请求：
    \(question.trimmingCharacters(in: .whitespacesAndNewlines))

    仅为本次原截图补充差倍线段图，不重新解题，不重写解答。直接检查原截图或用户明确提供的题面；不要把尚未核验的解答、失败的图解数据或方法例题当作原题条件。遵守用户只解某一道等范围要求；原图中本次请求涉及的各道差倍题分别编号，最多三图，不混合不同题目条件。
    只返回一个完整的结尾 ```math-diagrams 数据块，不写正文、计算关系或图形代码。只使用下面的配方协议，禁止输出 facts、relations、parts、origin、答案或推得数值。若原题缺少条件或无法适配配方，只简短说明缺失条件，不编造图形。
    \(differenceRatioDataContract)
    """
  }

  static let differenceRatioDataContract = """
    数据块必须为严格 JSON 对象：schemaVersion 为 1，diagrams 是一至三个编号不同的配方对象。每个配方只含 id、title、kind、difference、multiplier；kind 固定为 "difference_ratio"。difference 只含 value（原题给定的非负差数，JSON数字）、unit（原题数量单位，无单位写空字符串）、evidence（原题差数的来源）。multiplier 必含 value（原题明确给定的二至二十整数倍数，JSON数字）、evidence（原题倍数的来源），可省略 unit；若填写 multiplier.unit，只能写空字符串或“倍”。倍数是无单位的比例，不把 difference.unit 的年龄等数量单位填入 multiplier.unit。不填答案或计算出的量，界面会自动计算并验算后画出较小量一份、较大量倍数份、差数倍数减一份的线段图。
    十进制整数原题若明确“在得数末尾少添了一个0”，可填写倍数10，evidence只引用原题该句，不补写10倍或计算式；程序将10标为规则常数。只支持差数为整数且能被9整除，小数、多零、中间漏零或否定表述不适用。
    年龄题必须确认原图比较的是同一两人；同一两人的年龄差随年份同时变化保持不变，可用另一年份原题明确给定的两人年龄差，并在 difference.evidence 中注明原题年份、同一两人及年龄差不变的理由。倍数必须属于正在画图的同一时间基准，不把过去的倍数当作现在的倍数，不混用不同人物或不同题条件。每题的来源必须独立，不从未核验解答反推原题差数或倍数。
    """

  /// Repair is data extraction from the original, never a rewrite of an unverified solution.
  static func repairPrompt(question: String, views: [MathDiagram.Kind] = [], failure: String? = nil) -> String {
    """
    用户本次请求：
    \(question.trimmingCharacters(in: .whitespacesAndNewlines))

    仅为原截图和用户明确提供的题面补图，不重新解题，不重写答案。不要将助手答案、失败数据、方法例题当作原题条件。保留用户题号和范围；同图多题独立编号，不混合条件，最多三图。只返回一个完整的 ```math-diagrams 数据块。缺少条件或没有受支持画法时简短说明，不能编造。
    \(repairHint(failure))
    \(dataContract(views: views))
    """
  }

  static var prompt: String { prompt(views: []) }

  static func prompt(views: [MathDiagram.Kind], programArithmetic: Bool = false) -> String {
    let opening = programArithmetic
      ? "适用且有助理解时实际出图。使用原题配方时模型只解释关键关系，由程序生成完整计算步骤和图；其它题型仍说明步骤及验算。末尾附完整math-diagrams数据块。"
      : "本次要求实际图解：先说明题面、数量关系、步骤和验算，再在末尾附完整 ```math-diagrams 数据块。"
    return """
    \(opening)仅文字描述画法不算完成。不输出绘图代码，不混合多题条件。用户未指定只解某题时，处理原图中所有可辨识的题目，逐题编号并分别出图；最多三张图，超出时明确说明需要分批。不得擅自只解第一题。以下结构说明不是原题条件。
    \(dataContract(views: views))
    """
  }

  static let purchaseComparisonDataContract = """
    比较同一商品的满减或买赠方案且恰好取得所需数量时，优先使用购买比较配方，不编写自由运算编号或布局，也不把此思路称为归一归总。若选法建议不适用，可拒绝建议再直接比较优惠。
    配方只含 id、title、kind:"purchase_comparison"、item_unit（本、张或个）、currency_unit:"元"、quantity_policy:"exact_required_quantity"、required_count、unit_price、offers（恰好两项）。required_count和unit_price分别只含原题数字value和对应原题条件evidence，不能抄助手答案。
    每个offer有name。按原价金额每满减：kind:"threshold_reduction"、threshold、reduction；买几送几：kind:"buy_get"、paid、free。这四种条件均只填{"value":原题数字,"evidence":"原题对应条件"}，不填写计算结果。两店商品与原价单价必须相同，金额当前仅支持整数元，数量为正整数，不填额外字段或计算关系。程序会计算组数、余数、付款与差额并生成对照表。
    此配方不覆盖叠加优惠、减后金额重新计算满减、允许超购或放弃赠品的最优策略，不把“至少买”擅改为“恰好取得”。这些情况说明限制，不强行套用；不支持时仍可保留正常解题文字。完整买赠组之外单买的余量须小于再次触发赠品的购买数量；达到该门槛时，恰好数量需要另查条件，程序会拒绝，不把超额赠品偷偷删掉。
    """

  static func dataContract(views: [MathDiagram.Kind], includeEnvelope: Bool = true) -> String {
    let selected: [MathDiagram.Kind] = views.isEmpty
      ? [.barComparison, .equalParts, .state, .table, .area, .interval, .partWhole, .venn, .balance, .cycle] : views
    let core = (includeEnvelope ? "使用严格 JSON 对象 {\"schemaVersion\":1,\"diagrams\":[图解对象...]}。\n" : "") + planDataContract
    return core + (selected.contains(.table) ? "\n" + purchaseComparisonDataContract : "") + "\n本次只从下列画法中选择；用户指定画法时遵守指定，不自行改用其它 view。\n"
      + selected.map { guidance($0) }.joined(separator: "\n")
      + "\n图解要帮助回答本题所问：比较大小用比较线段，累计过程用整体分段，比较不同走法用对照表。行程往返同路时，对照表列速度、时间、路程，去程与回程各一行；回程路程沿用同一路程，速度较慢对应时间较长。若问能否按时返回，还需显示总用时、限时和相差时间；只画一个速度乘时间的矩形不能解释按时返回。仅有乘除算式并不意味着必须选择面积图。用户明确指定画法时尊重指定。"
      + "\n计算所得量不填写 unit，由客户端自动推导。每个显示量必须参与关系。完整解题的可求数量用operation/inputs推导，不停留在unknown；只有用户要求仅示意或原题条件不足时保留未知。规则常数和倍数不使用‘份/个’单位。每人/每套量必须为‘数量单位/人或套’，不是单纯数量单位。所有 value 都来自本题，计算量只能使用 operation 和 inputs。布局必须放入 layout 对象，不填写顶层factIDs/parts/columns/rows，不将所有数量列入显示位置。精确分数不能用近似值替代。条件缺失或不支持请说明，不编造。"
  }

  /// A solving request must not finish with an uncomputed schematic.
  static func requireComputedDisplay(_ result: Result, request: String) -> Result {
    guard ["解题", "solve"].contains(where: request.lowercased().contains),
      !["示意", "只画图", "仅画图"].contains(where: request.contains) else { return result }
    let computed = result.diagrams.filter { diagram in
      let displayed = diagram.kind == .table ? diagram.rows.flatMap(\.factIDs) : diagram.factIDs
      return !displayed.contains { diagram.fact($0)?.origin == .unknown }
    }
    guard computed.count != result.diagrams.count else { return result }
    var pending = result
    pending.diagrams = computed
    pending.failure = [result.failure, "本次要求完整解题，图中仍有未完成推导的数量。"].compactMap { $0 }.joined(separator: "\n")
    return pending
  }

  static func requireViews(_ result: Result, views: [MathDiagram.Kind]) -> Result {
    guard !views.isEmpty, result.diagrams.contains(where: { !views.contains($0.kind) }) else { return result }
    var pending = result
    pending.diagrams = result.diagrams.filter { views.contains($0.kind) }
    pending.failure = [result.failure, "模型未按本次指定画法生成图解。"].compactMap { $0 }.joined(separator: "\n")
    return pending
  }

  /// Error classes contain no source quantities, previous answer or broken graph IDs.
  private static func repairHint(_ failure: String?) -> String {
    guard let failure else { return "上一轮没有图形。请直接抽取原题并按规定结构补图。" }
    if failure.contains("原题数值来源") {
      return "纠错要点：value的evidence必须包含原题实际给出的该数值，不能只引用计算用到的其它数值。计算结果必须用operation和inputs重新推导；每张图各自声明原题输入及完整运算链，不能把上一张图的结果复制为原题value。不从旧答案补原题条件。"
    }
    if failure.contains("指定画法") { return "纠错要点：必须使用本次列出的view，不改为其它画法。重新按该画法的layout命名位置绑定数量。" }
    if failure.contains("自身") || failure.contains("循环") {
      return "纠错要点：计算结果的id不能出现在该步inputs里，每个中间量用不同id。删除重复自证的额外checks，quantity的operation已自动核算；不要用equal(result) result:result。若需要比较两种独立推导，先各自声明中间量，然后equal只有一个inputs编号，result指向另一个编号。只从原题量重新推导，不补造数值。"
    }
    if failure.contains("表格") || failure.contains("列数") {
      return "纠错要点：layout.rows的label已经是行标题，不能再次把‘项目’列入columns。columns只列数据列，各行factIDs数量必须与columns完全相同。例如columns:[‘数量’]，rows:[{label:‘人数’,factIDs:[人数编号]}]。未知可求结果用quantity.operation推导，不通过checks给unknown赋值。"
    }
    if failure.contains("算术") || failure.contains("输入数目") {
      return "纠错要点：quantity的operation会自动计算，省略不必要的checks。需要验算时另声明正确的中间量；分配题中例如每人量乘人数得到已发量，不是剩余量，剩余量为总量减已发量。equal只接受一个输入编号，result必须为另一个已经声明的编号。不要从旧答案填写结果或改写原题条件。"
    }
    if failure.contains("未完成") { return "纠错要点：本次是完整解题，可从原题计算的显示量应通过operation/inputs推导，不能只保留unknown示意。不要把正文答案填value，重新从原题量推导。" }
    if failure.contains("面积图") { return "纠错要点：面积图的length、width是两个因子，area是乘积，不限于几何长宽。直接用product(两因子)推导乘积，或quotient(乘积,已知因子)推导另一因子；绑定同一关系的三个编号，不需要额外重复product验算。行程题可用速度、时间、路程；保持原题单位和原题条件，不把速度写成厘米或将路程写成平方米。" }
    if failure.contains("单位") { return "纠错要点：单位必须符合原题含义。速度为米/分钟、时间为分钟，乘积是米；单价为元/个、数量为个，乘积是元；每套用量为米/套、套数为套。几何长宽用原题长度单位；倍数或份数无单位；相加减必须同单位。计算量不要填unit，自动推导。" }
    if failure.contains("状态") { return "纠错要点：factIDs只能引用先后状态，不包含离开/加入等变化量；每步单独计算，先减再加不能变成三项相加。" }
    if failure.contains("间隔") || failure.contains("起点") { return "纠错要点：interval顺序是起点序号、终点序号、间隔数、每段长度、总长度；树数另行推导，不能放在总长度的位置。零起点用rule，不冒充题面value。" }
    if failure.contains("layout") || failure.contains("引用") { return "纠错要点：填写layout命名位置，每个位置只绑定一个有效数量编号；不要把全部quantities复制到布局，不使用旧顶层factIDs，不遗漏布局字段。显示可求结果，勿另声明无关系的同名unknown。" }
    if failure.contains("整体") { return "纠错要点：整体和每个部分必须是同一单位的实际数量，例如路程，不能把速度直接当路程部分。先推导各部分，再检查相加为整体。" }
    if failure.contains("韦恩") { return "纠错要点：圈内是仅左、交集、仅右三个互不重复区域；并集为三者之和，可求的圈外量用差运算，不能保持unknown。" }
    if failure.contains("等份") || failure.contains("比例") { return "纠错要点：倍数来自原题，总份数由倍数加one推导；先用总量除以总份数求较小量，再乘原题倍数求较大量。不要把总份数当成倍数，不能把推得份数伪造为value。" }
    return "纠错要点：只引用已声明的数量；value来自原题，结果用单步operation/inputs，无循环引用。显示量及额外checks均需真实的运算依据，不重新写解答。"
  }

  private static func guidance(_ view: MathDiagram.Kind) -> String {
    switch view {
    case .barComparison: return "view:bar_comparison，layout:{\"items\":[较大量编号,较小量编号]}，引用2至8个同单位数量，各行对齐比较。和差题可声明sum/difference原题量与two规则；较大量=(sum+difference)/two，较小量=sum−较大量。中间量拆开声明，不把答案填value。"
    case .equalParts: return "view:equal_parts，layout:{\"items\":[较小量编号,较大量编号],\"parts\":[1,原题倍数数字]}。和倍题：原题总量sum、原题倍数ratio、one规则；totalParts=sum(ratio,one)，small=quotient(sum,totalParts)，large=product(small,ratio)。差倍题：excessParts=difference(ratio,one)，small=quotient(原题差数,excessParts)，large=product(small,ratio)。份数均无单位，显示已求得small/large；不要额外声明同名unknown。"
    case .state: return "view:state，layout:{\"states\":[原来编号,中间编号,最终编号]}，只列先后状态，不是变化量。例如原来、减少后、增加后：middle=difference(original,departure)，final=sum(middle,arrival)，layout.states:[original,middle,final]。departure/arrival为单独原题变化数量，仅作为计算输入。不能把离开量加进最终人数。"
    case .table: return "view:table，layout:{\"columns\":[数据列名],\"rows\":[{\"label\":行标题,\"factIDs\":[每个数据列量的编号]}]}。行label自动显示在最左侧，不占columns；columns不重复写‘项目’，各行factIDs数目必须等于columns数目。简洁表可用columns:[\"数量\"]、rows:[{\"label\":\"人数\",\"factIDs\":[人数编号]},{\"label\":\"总量\",\"factIDs\":[总量编号]}]；不要添加任意假设人数的试算行。每个显示量均有真实运算依据，可求结果直接声明operation，不保留unknown并试图通过checks求解。表格通常不需要checks，客户端已核算全部quantity.operation。往返对照表可用columns:[\"速度\",\"时间\",\"路程\"]，rows分别为去程和回程；distance=product(outSpeed,outTime)，returnTime=quotient(distance,returnSpeed)，两行路程引用同一distance。需要判断限时时，另用一个单列时间表显示totalTime=sum(outTime,returnTime)、原题限时及excess=difference(totalTime,limit)。每张图重新声明自己的原题量和推导，不能跨图引用。行内单位可不同；每人/每套量单位为张/人、米/套，人数/套数为人、套。换用量题：total=product(原每套用量,原套数)，newCount=quotient(total,新每套用量)。两种分法比较且较高每人量正好发完时：先求每人增加量gap=difference(较高每人量,较低每人量)，剩余量surplus若题面给的是还能发给几人，则surplus=product(较低每人量,剩余可发人数)；count=quotient(surplus,gap)，usedLow=product(较低每人量,count)，total=sum(usedLow,surplus)，usedHigh=product(较高每人量,count)。必须求出count和total；完整解题时不要声明同名unknown。正好发完的剩余量可以difference(total,usedHigh)推导，不能用带数量单位的规则zero。不得把每人量乘人数当作剩余量。若两种分法都有余缺：同盈或同亏取余缺量之差，一盈一亏取余缺量之和，再除以每人分配量之差；按原题确认大小顺序和总量关系，不套用正好发完的特例。"
    case .area: return "view:area，layout:{\"length\":第一因子编号,\"width\":第二因子编号,\"area\":乘积编号}。字段名保持兼容，矩形表达两个因子相乘，不限于几何面积：长×宽=面积；速度×时间=路程；单价×数量=总价；效率×时间=工作量。已知两因子时乘积quantity用operation:product、inputs:[第一因子,第二因子]，输入顺序可交换。已知乘积和一因子时，另一因子quantity用operation:quotient、inputs:[乘积,已知因子]；无需额外product检查或重复声明同名结果。layout必须引用这一步关系中的三个编号。原题量保留真实单位，例如米/分钟与分钟，推导路程为米；几何长宽按原题长度单位。计算量不填unit，自动推导。去返程路程相同可各画一个矩形，分别绑定各自速度、时间和同一路程；不能把去程时间放进返程矩形。标题和label说明因子含义，路程不是几何面积。用户指定面积图时不可替换成比较线段图。"
    case .interval: return "view:interval，layout:{\"start\":起点编号,\"end\":终点编号,\"gaps\":间隔数编号,\"per\":每段量编号,\"total\":总长度或总台阶量编号}。楼梯原题起终序号作为原题value（无单位），gaps=difference(end,start)，total=product(gaps,per)。长度间距题：原题total长度和per间距；start用zero规则，end=quotient(total,per)，gaps=difference(end,start)；另用checks检验product(gaps,per) result:total。端点树数可再声明trees=sum(gaps,one规则)，无单位并在label说明棵数，绝不把trees放total的位置。"
    case .partWhole: return "view:part_whole，layout:{\"whole\":整体编号,\"portions\":[部分路程编号...]}，只绑定整体与部分，整体和部分同单位；路程分段不能包含速度或时间，时间分段则全部使用时间单位。时间线用whole:totalTime、portions:[outTime,returnTime]，totalTime=sum(outTime,returnTime)；returnTime需先由同路程与回程速度推导。whole须有sum各部分关系（原题whole可用checks验证sum）。路程图：原题总路程、各速度；先求速度和，再time=quotient(totalDistance,speedSum)，partA=product(speedA,time)，partB=product(speedB,time)，checks sum(partA,partB) result:totalDistance。绝不能把速度编号当作路程部分。"
    case .venn: return "view:venn，layout:{\"leftOnly\":仅左编号,\"intersection\":交集编号,\"rightOnly\":仅右编号,\"union\":并集编号,\"outside\":圈外编号,\"total\":全班编号}。原题leftTotal,rightTotal,both,total：leftOnly=difference(leftTotal,both)，rightOnly=difference(rightTotal,both)，union=sum(leftOnly,both,rightOnly)，outside=difference(total,union)，checks sum(union,outside) result:total。可求量全部推导，不用unknown，不混淆leftTotal和leftOnly。"
    case .balance: return "view:balance，layout:{\"high\":较大量编号,\"low\":较小量编号,\"mean\":平均量编号,\"transfer\":移动量编号}，只绑定这四个位置，不绑定总数、差数或其它中间量。原题high/low同单位；two规则无单位；sumValue=sum(high,low)，differenceValue=difference(high,low)，mean=quotient(sumValue,two)，transfer=quotient(differenceValue,two)。结果用运算不填value。"
    case .cycle: return "view:cycle，layout:{\"count\":总项数编号,\"period\":周期项数编号,\"cycles\":整周期数编号,\"remainder\":余项数编号,\"labels\":[按周期顺序的每项名称]}，全部数量无单位整数；cycles=floor_quotient(totalCount,periodCount)，remainder=remainder(totalCount,periodCount)；layout.labels按周期项顺序写每一项名称，与periodCount相等；周期项数1至12、总项数1至1000。"
    }
  }
  private static let planDataContract = """
    通用图解对象字段为 id（唯一短编号）、title（中文标题）、kind:"quantity_plan"、view（下列原生画法）、quantities（最多32个数量）、layout（所需的命名布局位置）。这些字段只适用于quantity_plan，不能用于其它配方kind。每张图独立编译，不跨图引用编号；另一张图需要相同量时，在该图重新声明原题条件及推导步骤。不要为了放入同一画法强行增加图，例如总时间的加法比较不能绑定成面积图的乘积。不要输出 facts、relations、origin、outputID；计算值、推导来源和单位由客户端自动编译与核算。
    quantities 内每个对象必填 id、label；单位 unit 可省略，无单位可写空字符串。每个数量只选一种声明：
    - 原题已知量：value 为原题 JSON 数字，evidence 引用原题中包含这个数值的对应条件，保留数值及单位；不能只写其计算用到的两个源数。图片文字可转写，但不能把运算说明当作原题条件。
    - 运算所得量：operation 和 inputs（输入数量 id 数组）。禁止填 value 或 evidence；不要把算出的答案写成原题 value。每步只做一次运算，中间量独立声明。另一张图需要该结果时，重新声明其原题输入和运算链，不能复制上一张图的结果为value；例如回程时间须在每张相关图中由原速度、去程时间推导路程，再除以回程速度。
    - 规则常数：rule 只选 zero、one、two、ten、hundred、thousand，必须无单位，不填 value；仅用于真实数学规则（例如平分两份），不能冒充题面数量。
    - 未知量：unknown:true，不填 value。示意图仍需对应的关系，不能自行假定比例。
    operation 支持 sum（2至12输入）、difference / product / quotient（2输入）、equal（1输入）、floor_quotient / remainder（非负整数整除/余数，2输入且除数为正）。inputs 只能引用本图 quantities 的编号，不能直接写数字或算式，也不能包含本quantity的id。加减单位必须一致；乘除单位自动推导，如张/人乘人得张。所有计算需从原题量或规则出发，不能循环引用。quantity.operation会自动生成并核算关系，不重复编写checks。只有画法明确需要额外关系时用checks:[{"operation":"运算名","inputs":[编号...],"result":"已有数量编号"}]；checks只验证已经声明的结果，不能给unknown赋值或求解；result不得包含在inputs，equal必须且只能有一个输入。需要比较两个已独立推得的结果时格式为{"operation":"equal","inputs":["computedA"],"result":"computedB"}；不能写equal的两个输入，不能给未推导的unknown写checks假装已求解。
    """
}
