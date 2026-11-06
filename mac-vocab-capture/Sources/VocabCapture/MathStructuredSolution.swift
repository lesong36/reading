import Foundation
import CoreFoundation

/// Only schema vocabulary crosses the diagnostic boundary; never model values.
struct MathSubmissionDiagnostic: Sendable, Equatable {
  let tool: String
  let path: String
  let rule: String
  private static let fields = Set("larger_hundreds smaller_hundreds repeated_digits turn_order a b starts additional_diagrams allocations amount answer area balance changes checks columns conservation_evidence count count_unit currency_unit cycles deadline diagram diagram_outcome difference direction distance_unit end end_floor endpoint_evidence endpoints equality_evidence evidence factIDs free gaps high id improved_per_item initial inputs intersection item_unit items kind label labels larger layout left leftOnly length low mean method_id mode multiplier name offers operation original_count original_per_item outside outward_speed outward_time paid parts pattern_evidence per per_recipient period portions primary_diagram quantities quantity_policy reason recipient_unit rectangle_evidence reduction relationship remainder required_count resource_unit result return_speed right rightOnly rows rule scenario smaller spacing start start_floor states status steps_per_interval threshold time_unit title total total_sides transfer union unit unit_price unknown value view visual_method_ids whole width solution".split(separator: " ").map(String.init))
  private static let rules = Set("required additionalProperties type enum minLength maxLength minItems maxItems minimum maximum integer finite anyOf".split(separator: " ").map(String.init))
  init?(_ value: Any?) {
    guard let object = value as? [String: Any], Set(object.keys) == ["tool", "path", "rule"],
      let tool = object["tool"] as? String, let path = object["path"] as? String,
      let rule = object["rule"] as? String, Self.rules.contains(rule),
      tool == "submit_general_math_solution" || tool == "submit_math_solution" || tool == "solve_reflected_meetings" || tool == "solve_reported_digit_game"
        || MathStructuredSolution.nativeRecipeKinds.contains(String(tool.dropFirst(7))) && tool.hasPrefix("render_"),
      path.count <= 1000, path.hasPrefix("$") else { return nil }
    let suffix = String(path.dropFirst())
    let pattern = try! NSRegularExpression(pattern: #"\.[A-Za-z_][A-Za-z_0-9]*|\[[0-9]+\]"#)
    let tokens = pattern.matches(in: suffix, range: NSRange(suffix.startIndex..., in: suffix))
      .compactMap { Range($0.range, in: suffix).map { String(suffix[$0]) } }
    guard tokens.joined() == suffix, tokens.count <= 64 else { return nil }
    for token in tokens {
      if token.hasPrefix(".") {
        guard Self.fields.contains(String(token.dropFirst())) else { return nil }
      } else {
        guard let index = Int(token.dropFirst().dropLast()), (0...31).contains(index) else { return nil }
      }
    }
    self.tool = tool; self.path = path; self.rule = rule
  }
  var logDescription: String { "tool=\(tool) path=\(path) rule=\(rule)" }
}

/// Only fixed local protocol labels reach the UI; never provider bodies or values.
struct MathSolutionSubmissionError: LocalizedError {
  static let descriptions = [
    "submission_truncated": "回答未完整返回，请重试或缩小问题范围。",
    "submission_tool": "模型没有提交一个有效的解题工具结果。",
    "submission_json": "模型提交的解题数据不完整。",
    "submission_shape": "模型提交的图解参数缺少必要项目或格式不符。",
    "submission_duplicate_key": "模型提交的数据包含重复字段。",
    "submission_duplicate_id": "模型提交的图解包含重复标识。",
    "submission_inline_grid": "模型提交的分块图数据不完整或格式不符。",
    "submission_inline_geometry": "模型提交的切割图数据不完整或格式不符。",
    "submission_inline_cube": "模型提交的正方体路径图数据不完整或格式不符。",
    "submission_inline_hexagon": "模型提交的正六边形等分图数据不完整或格式不符。",
    "submission_inline_triangle": "模型提交的三角形分割图数据不完整或格式不符。",
    "submission_inline_route": "模型提交的格线路线图数据不完整或格式不符。",
    "submission_number": "模型提交了非有限数值。",
    "submission_mode": "模型提交的图解类型与解题方式不一致。",
    "submission_size": "模型提交的解题数据超过大小限制。",
    "submission_text_only_unauthorized": "模型没有按本次要求提供图解或不画图理由。",
    "submission_relationship_only": "仅收到关系说明，图解资料未通过检查，尚未完成程序计算。",
  ]
  let issue: String
  init?(issue: String) {
    guard Self.descriptions[issue] != nil else { return nil }
    self.issue = issue
  }
  var errorDescription: String? { Self.descriptions[issue] }
}

/// Only known request field names survive the engine boundary; no provider prose.
struct MathProviderRequestError: LocalizedError {
  static let allowedFields: Set<String> = ["tool_choice", "tools", "strict", "temperature", "max_tokens",
    "max_completion_tokens", "image_url", "thinking", "messages", "content", "response_format",
    "stream_options", "$ref", "$defs", "additionalProperties", "maxLength", "minItems", "anyOf", "oneOf"]
  let status: Int
  let fields: [String]
  init?(status: Int, fields: [String]) {
    guard [400, 422].contains(status), !fields.isEmpty, fields.count <= Self.allowedFields.count,
      Set(fields).count == fields.count, fields.allSatisfy(Self.allowedFields.contains) else { return nil }
    self.status = status
    self.fields = fields.sorted()
  }
  var errorDescription: String? {
    "模型拒绝图解请求（HTTP \(status)）；服务提示涉及参数：" + fields.joined(separator: "、") + "。"
  }
}

/// A single answer envelope distinguishes native arithmetic from ordinary
/// reasoning. It does not add a selector, reviewer or repair provider call.
enum MathStructuredSolution {
  static let requestPrefix = "[MATH_STRUCTURED_SOLUTION_V1]\n"
  static let submissionRequestPrefix = "[MATH_SOLUTION_SUBMISSION_V2]\n"
  static let rendererRequestPrefix = "[MATH_RENDERER_TOOLS_V3]\n"
  static let fastRendererRequestPrefix = "[MATH_RENDERER_NATIVE_ONLY_V1]\n"
  static let marker = "```math-solution"
  static let nativeRecipeKinds: Set<String> = Set(["difference_ratio", "two_allocations", "purchase_comparison", "return_deadline", "interval_problem", "cyclic_pattern", "fixed_total", "state_changes", "rectangle_sum_difference", "venn_counts"]).union(MathComparisonRecipe.kinds)

  /// Request-local handles save the model from copying opaque hash identities.
  /// Avoid every real ID so recorded full-ID responses remain unambiguous.
  private static func handles(for candidates: [MathTeachingMethod]) -> [String] {
    let identities = Set(candidates.map(\.id))
    var prefix = ""
    while candidates.indices.contains(where: { identities.contains(prefix + String($0)) }) {
      prefix += "m"
    }
    return candidates.indices.map { prefix + String($0) }
  }

  static func prompt(_ request: String, candidates: [MathTeachingMethod], requireDiagram: Bool = false, singleSubmission: Bool = false, rendererTools: Bool = false, nativeOnly: Bool = false) -> String {
    let catalogue = candidates.isEmpty ? nil : (try? MathTeachingReviewCatalogue.load())
    let identifiers = singleSubmission && rendererTools ? handles(for: candidates) : candidates.map(\.id)
    let entries = zip(candidates, identifiers).map { method, identifier in
      "id:\(identifier)\nroles:\(MathMethodMatcher.singleCallRolePolicy(for: method, catalogue: catalogue).roles.joined(separator: ","))\n名称：\(method.title)\n全文：\n\(method.instructions)"
    }.joined(separator: "\n\n")
    if singleSubmission && rendererTools {
      return (nativeOnly ? fastRendererRequestPrefix : rendererRequestPrefix) + """
        用户请求（优先）：\(request)
        本机候选全文尚未采用；核对全部前提。主方法可为空，不因单价乘数量把优惠比较强归为归一归总。
        \(entries)

        method_id只填实际采用的solution角色候选id或null；visual_method_ids只填实际采用的visual角色候选id，最多两个，不重复或与主法相同。没有适用方法填null和[]。
        三位数减三位数且百位固定，甲每轮报0至9、乙看见后选一个空格，允许重复，双方分别使差最大和最小：优先调用solve_reported_digit_game。larger_hundreds和smaller_hundreds只抄原题两百位数字，repeated_digits=true、turn_order=report_then_place，evidence引用顺序和重复约定，visual_method_ids=[]。程序生成完整15状态、双向保证及核验最优对局，不要自行写可能非最优的对局。不能重复、库存限制、乙先选位或非减法时不用。
        两车各自匀速、到端点立即折返，端点同时到达不算迎面，若原题首次迎面距左端a、第二次距离b且0<b<a，可调用solve_reflected_meetings。starts=same表示两车都从左端出发，此时b是第二次距右端；starts=opposite表示分别从两端出发，此时b是第二次距左端。a、b只抄原题整数距离，evidence写原题依据，不交全程或自行计算的路程账。该工具只生成路程表，不执行绘图，visual_method_ids必须为空数组。程序穷尽折返分支、核对真实第二次迎面并生成不用未知数方程的讲解。其他起点、停留、变速、端点计数约定、额外限制或读图不清时不用此工具。
        单道2至6阶残缺方形等和表或幻方，若原题仅规定行列及可能的两条主对角线等和、已知数为整数，应调用solve_equal_sum_grid：grid逐格抄原图，空格填null；diagonals只按原题，target按1起算行列，source_evidence说明依据。不先猜幻和或添数字范围。另有互异、限定数字域、分区规则、多题或读图不清时不用此工具，改一般解答明确限制。程序核算不替代适合年级的推理审核，也不证明抄录符合原图。
        单道有限路网题若要求节点不重复的路径总数，且可明确读取不超过12个节点及逐段边，应调用count_simple_graph_paths提交图结构，由程序计数，不在一般解答中自行穷举。node_locations须为每个节点一一填写原图位置说明及归一化x/y（图形左上0,0，右下1000,1000），不得把图旁题号、文字或无路口处臆造为节点。交叉可转向须拆为节点，每条边不得跨越该节点；方向按原图。没有实心点不等于不能转向，题意未明须在crossing_convention说明所采用的条件解释，source_evidence只写原图依据。先检查每个节点的全部出边，尤其起点每一条边都须登记。不可转向但交叉位置不得重访、平行重边、读图不清或多题请求不适用此工具，使用一般解答明确限制，不补造图结构。程序计数不代表原图读取或人工审核通过。
        \(nativeOnly ? "本次快速解题只使用现有原生图形工具；原题前提完整满足且图有帮助时使用，不能为简单连乘强行造图。其它题用一般解答工具完整解题及验算，不输出通用绘图计划或math-center-cut围栏；仅当候选技能明确提供网格约定时，可用inline_grid并在正文输出完整math-grid JSON围栏，图形须符合题目且说明未使用格；若候选技能明确提供正方体路径约定，可用inline_cube并输出完整math-cube-path JSON围栏。若候选技能明确提供正六边形等分约定，可用inline_hexagon并输出math-hexagon-partition围栏；若候选技能明确提供三角形预设，可用inline_triangle并输出math-triangle-dissection围栏；如果题目明确是格线路线，可用inline_route并输出math-grid-route JSON围栏，包含width、height、points和stars，坐标为格点、每一步上下左右相邻，必须与原题一致；若确有帮助的画法未被快速工具覆盖，明确说明工具边界，用户可单独补图；不要把未覆盖说成题目不能画图。" : requireDiagram ? "本次需要真正显示且帮助理解的图，不能只说画图。" : "依据题目需要提供帮助理解的图。")
        一般解答保留关键条件、完整推理、必要计算与验算，但每项只解释一次；不重复抄题或把同一检查再写成多张表。用户要求详细步骤时按其要求展开，不为简短省掉题号、条件或验算。
        \(nativeOnly ? "" : "仅当候选技能明确提供约定时，一般解答工具mode:general可用inline_grid配完整math-grid JSON围栏，或inline_geometry配完整math-center-cut JSON围栏，或inline_triangle配完整math-triangle-dissection JSON围栏，或inline_cube配完整math-cube-path JSON围栏，或inline_route配完整math-grid-route JSON围栏（width、height、points、stars；相邻格点），放在answer正文。diagram_outcome只填status，不填primary_diagram、additional_diagrams或reason。中心切割仅为归一化示意，不是原题测量数据；显示端检查输入，仍须独立核对原题。")
        包含多道题或原生工具未覆盖完整请求时使用一般解答工具，不要为单一配方漏解其他题号。原生工具只填写原题输入、引文和关键关系说明，不提前计算答案、重复验算或生成布局。
        """
    }
    if singleSubmission {
      return submissionRequestPrefix + """
        用户请求（优先）：\(request)
        看原图解题。本机候选全文尚未采用；核对所有前提，可以没有已有主方法，不因单价乘数量把优惠比较归为归一归总。方法例题和历史助手答案不是原图条件。
        \(entries)

        调用submit_math_solution工具一次提交解答，不在工具之外输出正文或JSON。字段结构以工具定义为准。method_id只填实际采用的solution角色候选id或null；visual_method_ids只填实际采用的visual角色候选id，最多两个，不重复或与主法相同。没有适用方法填null和[]，采用声明不是人工核验。
        mode保持native_recipe或general。native_recipe仅在原题满足语义配方且图有帮助时使用，answer只解释关键关系，不提前计算或重复验算；程序生成计算、检查和图。其它题型用general正常解答及必要验算，不能漏解请求中的题号。图解工具不是必选主解法。
        \(requireDiagram ? "本次需要真正显示的有用图解。" : "依据题目需要决定是否提供有用图解。")
        diagram_outcome必须明确选择：renderable提供primary_diagram和additional_diagrams；仅当候选技能明确提供约定时，可用inline_grid配完整math-grid JSON围栏，或inline_geometry配完整math-center-cut JSON围栏，或inline_triangle配完整math-triangle-dissection JSON围栏，或inline_cube配完整math-cube-path JSON围栏，或inline_route配完整math-grid-route JSON围栏（width、height、points、stars；相邻格点），放在answer内，diagram_outcome只填status，不填写数量图或reason；中心切割仅为归一化示意，不是原题测量数据，不代表题意或数学核验通过。其它情况使用unreadable_or_insufficient、no_helpful_diagram或user_requested_text_only并说明具体reason。条件完整且存在有帮助的受支持图时必须renderable，不能只描述画法，也不能因主法为空省略图。原题模糊、图无帮助或用户明确只要文字时允许不画，不能为了出图补造条件或强套方法；这些情况用general。
        """
    }
    return requestPrefix + """
      用户请求（优先）：\(request)
      \(requireDiagram ? "本次同时要求实际图解：条件完整且有合适图解时，diagrams必须返回能解释关键关系的图。不能只在文字里说画图或因主方法为空就省略图。只有原题条件不清、没有适用图解或用户禁止画图时才可为空，并在answer说明原因；不能为出图强套主方法。" : "图解根据原题需要提供，不为套用方法增加无关图。")
      看原图解题。下列为本机候选全文，尚未采用；必须判断全部前提，缺失或不适用时拒绝。可以没有已有主方法，不因单价乘数量把优惠比较归为归一归总。不能抄方法例题或助手答案当作原图条件。
      \(entries)

      只返回一个严格JSON对象，不输出Markdown、数据围栏或JSON之外的正文。恰有schemaVersion:1、mode、method_id、visual_method_ids、answer、diagrams六项。
      method_id为实际采用的solution角色候选id或null；visual_method_ids为实际采用的visual角色候选id数组，最多两个，不重复或与主法相同。没有适用方法填null和[]。采用声明不是人工核验。
      mode只选native_recipe或general。
      native_recipe：原题满足下列语义配方前提且图能帮助理解时使用；answer仅写关键关系解释（最多120字），禁止填写计算结果或重复验算，diagrams为1至3个原题配方。程序将生成完整计算、检查、图解和比较结论，因此用户要求验算也会由程序执行。无需模型先算一遍。这些配方是画图工具，不是必选的主解法，不因使用配方强行填写method_id。
      general：其它题型正常解答；answer填写完整关键推理、步骤与必要验算。diagrams可为空或为1至3个有帮助的通用图解。原图条件不清或配方前提不满足时用此模式说明缺失条件，不编造配方，不强行选择已有技能，不漏解请求中的题号。用户只要文字时用general、diagrams:[]。
      diagrams对象的数据规则如下，仅使用字段规则，不使用独立数据块；schemaVersion和diagrams直接位于本返回对象。
      """
  }

  static func diagramContract(views: [MathDiagram.Kind]) -> String {
    """
      diagrams是有明确kind的联合类型，一个对象只用该kind的字段，禁止混合两种格式。以下所有对象直接放入本次六字段响应的diagrams数组，不另建schemaVersion/diagrams对象。
      native_recipe模式可用\(nativeRecipeKinds.sorted().joined(separator:"、"))。原题完整满足某配方前提且用户未禁止图时，提供对应图，不能选择native_recipe却填quantity_plan或空数组。无需匹配已有主方法。
      \(MathComparisonRecipe.contract)
      \(MathRectangleSumDifferenceRecipe.contract)
      \(MathVennCountsRecipe.contract)
      \(MathStateChangesRecipe.contract)
      \(MathCycleRecipe.contract)
      \(MathFixedTotalRecipe.contract)
      \(MathDiagramAnswer.differenceRatioDataContract)
      \(MathDiagramAnswer.distributionDataContract(view: .table))
      \(MathDiagramAnswer.purchaseComparisonDataContract)
      \(MathReturnDeadlineRecipe.contract)
      \(MathIntervalRecipe.contract)
      general模式用于不满足以上配方的题型。以下规则仅描述kind:quantity_plan的通用图对象，不能覆盖上面的配方字段；保留有帮助的图，题目条件不足或图无帮助时可为空。
      \(MathDiagramAnswer.dataContract(views: views, includeEnvelope: false))
      """
  }

  /// Tool schemas own field structure; this contract supplies mathematical
  /// applicability and source discipline without a competing response envelope.
  static let submissionDiagramContract = """
    图解语义约束：配方仅填写原题条件和对应原文引文，不填推算的答案、关系或布局。数字引文须含对应原题数字，单位须一致；原图优先，OCR仅为辅助，不能把总量当差量、把计算结果当已知数。
    difference_ratio：原题明确给两量之差及倍数；唯一十进制规则例外：整数“在得数末尾少添了一个0”可填写multiplier.value为10，evidence只保留原题这句（不要增写计算式或倍数）；程序将10标为规则常数而非原题数字。只支持少写一个末尾0且差能被9整除；小数、多零、中间漏零或含否定条件不用此例外。sum_difference：原题明确给两量总和及差；sum_ratio：原题明确给总和及倍数。三者不能相互冒充。
    equalize_transfer：两方直接转移、总量保持不变并要求相等；填写两方原持有量，不填写算出的差或平分常数。
    rectangle_sum_difference：长方形原题明确给出长宽之和与差，程序求长宽及面积；不能把周长当边长之和。
    venn_counts：原题明确总体、两组含交集人数、两者都参加人数，程序推导独有区域、并集、圈外。
    state_changes：已知初始量与按顺序发生的明确增减，同单位，最多5次，不是周期；只提交原题数和方向，程序计算中间和最终状态。
    two_allocations：同一总量按两种每人分量分配，原题明确给余缺条件；只填原题每份数及余缺，不填算出人数。
    purchase_comparison：按原题每店的单价、满减或买赠条件分别求实付比较；优惠比较不因此属于归一归总。
    return_deadline：原题给去返速度、去程时间与总时限，原路返回；不能补造未给的速度或时间。
    interval_problem：原题明确楼层或点的起止、每段数量及端点规则；点数与间隔数有别。
    fixed_total：同一批资源总量保持不变，给原来每件用量及件数、改进后每件用量，才可求新件数；不能混用单位或补造资源。
    cyclic_pattern：原题明确总项数及完整有序重复周期；保留重复名称和顺序，周期长度由列出的原题位置数得出，不写成没有引文的已知数。
    general的quantity_plan：只选择帮助理解关键数量关系的图。给定量含原图引文，推导量由无环运算关系得出，未知量保持未知；运算结果不能引用自身为输入。规则常数须说明数学规则，不能冒充原题条件。布局由程序决定，不输出坐标或SVG。
    """

  /// Renderer functions already own these applicability descriptions. Keep the
  /// older submission contract intact and retain every nonduplicated rule,
  /// including the decimal exception, repeated-cycle items and general DAGs.
  static var rendererDiagramContract: String {
    let describedByTools = ["equalize_transfer：", "rectangle_sum_difference：", "venn_counts：",
      "state_changes：", "two_allocations：", "purchase_comparison：", "return_deadline：", "interval_problem："]
    return submissionDiagramContract.split(separator: "\n").filter { line in
      !describedByTools.contains { line.hasPrefix($0) }
    }.joined(separator: "\n")
  }

  static var fastRendererDiagramContract: String {
    rendererDiagramContract.split(separator: "\n").filter { !$0.hasPrefix("general的quantity_plan：") }.joined(separator: "\n")
  }

  static func parse(_ response: String, candidates: [MathTeachingMethod], rendererTools: Bool = false) -> MathSinglePassSolution.Result {
    var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix(marker + "\n"), json.hasSuffix("```") {
      json = String(json.dropFirst(marker.count).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let object = json.utf8.count <= 150_000
      ? json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
    func rejected() -> MathSinglePassSolution.Result {
      let text = object?["answer"] as? String
        ?? (json.hasPrefix("{") || json.hasPrefix("```") ? "本次结构化解答未有效返回，原图仍可保存。" : MathSinglePassSolution.displayText(response))
      return .init(answer: text, method: nil, visualMethods: [], failure: "结构化解答协议未通过；未自动重试，回答仍待核验。")
    }
    let expected: Set<String> = ["schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"]
    guard let object,
      Set(object.keys) == expected || (rendererTools && (Set(object.keys) == expected.union(["diagram_omission"])
        || Set(object.keys) == expected.union(["diagram_submission_failure"]))),
      let version = object["schemaVersion"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
      let mode = object["mode"] as? String, ["native_recipe", "general"].contains(mode),
      let text = object["answer"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.count <= 40_000,
      let diagrams = object["diagrams"] as? [[String: Any]], diagrams.count <= 3 else { return rejected() }
    if mode == "native_recipe" {
      guard !diagrams.isEmpty,
        diagrams.allSatisfy({ nativeRecipeKinds.contains($0["kind"] as? String ?? "") }) else { return rejected() }
    }
    var omissionReason: String?
    var submissionFailure: String?
    if let issue = object["diagram_submission_failure"] {
      guard rendererTools, mode == "general", let issue = issue as? String,
        let error = MathSolutionSubmissionError(issue: issue) else { return rejected() }
      submissionFailure = error.localizedDescription
    }
    if let omission = object["diagram_omission"] {
      guard rendererTools, mode == "general", diagrams.isEmpty,
        let omission = omission as? [String: Any], Set(omission.keys) == ["status", "reason"],
        let status = omission["status"] as? String,
        ["no_helpful_diagram", "unreadable_or_insufficient"].contains(status),
        let reason = omission["reason"] as? String, reason.count <= 500,
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rejected() }
      omissionReason = reason
    }
    let identities = Dictionary(uniqueKeysWithValues: zip(handles(for: candidates), candidates.map(\.id)))
    func identity(_ value: Any?) -> Any {
      guard rendererTools, let identifier = value as? String else { return value ?? NSNull() }
      return identities[identifier] ?? identifier
    }
    let visualIDs: Any = (object["visual_method_ids"] as? [String]).map { $0.map { identity($0) } }
      ?? (object["visual_method_ids"] ?? NSNull())
    guard let metadata = try? JSONSerialization.data(withJSONObject: [
      "method_id": identity(object["method_id"]), "visual_method_ids": visualIDs]),
      let envelope = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "diagrams": diagrams]) else { return rejected() }
    let combined = text + "\n" + MathSinglePassSolution.marker + "\n"
      + String(decoding: metadata, as: UTF8.self) + "\n```"
      + (diagrams.isEmpty ? "" : "\n" + MathDiagramAnswer.marker + "\n" + String(decoding: envelope, as: UTF8.self) + "\n```")
    var result = MathSinglePassSolution.parse(combined, candidates: candidates)
    result.diagramOmissionReason = omissionReason
    result.diagramSubmissionFailure = submissionFailure
    result.answerIncomplete = object["diagram_submission_failure"] as? String == "submission_relationship_only"
    return result
  }

  /// JSON fragments are never rendered as an answer. The complete envelope
  /// is validated and converted to readable text and pictures when it arrives.
  static func displayText(_ partial: String) -> String { "" }
}
