import CoreFoundation
import Foundation

struct ScreenshotQuestionUsage: Sendable, Equatable {
  var inputTokens: Int? = nil
  var outputTokens: Int? = nil
  var reasoningTokens: Int? = nil
  var engineTimings: [String: Double] = [:]
  var failurePhase: String? = nil
  var failureIssue: String? = nil
  var streamTermination: String? = nil
  var submissionDiagnostic: MathSubmissionDiagnostic? = nil

  /// Usage is optional: malformed telemetry must never discard a valid answer.
  static func decode(_ value: Any?, timings: Any? = nil) -> Self? {
    let durations = decodeEngineTimings(timings)
    guard value == nil || value is [String: Any] else { return nil }
    let object = value as? [String: Any] ?? [:]
    var counts: [String: Int] = [:]
    for key in ["input_tokens", "output_tokens", "reasoning_tokens"] {
      guard let value = object[key] else { continue }
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
          String(cString: number.objCType)),
        number.compare(NSNumber(value: 0)) != .orderedAscending,
        number.compare(NSNumber(value: Int.max)) != .orderedDescending
      else { return nil }
      counts[key] = number.intValue
    }
    guard !counts.isEmpty || !durations.isEmpty else { return nil }
    return Self(
      inputTokens: counts["input_tokens"], outputTokens: counts["output_tokens"],
      reasoningTokens: counts["reasoning_tokens"], engineTimings: durations)
  }

  /// Failed math calls may have clocks without token usage or a usable answer.
  static func decodeFailure(_ object: [String: Any]) -> Self? {
    let phases: Set<String> = ["preparation", "model_acquisition", "tool_binding", "stream", "submission_validation"]
    guard let phase = object["failure_phase"] as? String, phases.contains(phase) else { return nil }
    let timings = decodeEngineTimings(object["timings"])
    guard !timings.isEmpty else { return nil }
    let issue = (object["submission_issue"] as? String).flatMap { MathSolutionSubmissionError(issue: $0)?.issue }
    let termination = object["stream_termination"] as? String
    let allowedTerminations: Set<String> = ["missing_terminal", "token_limit", "content_filter", "incomplete", "provider_failure", "other_terminal"]
    let safeTermination = issue == "submission_truncated" && termination.map(allowedTerminations.contains) == true ? termination : nil
    return Self(engineTimings: timings, failurePhase: phase, failureIssue: issue,
      streamTermination: safeTermination, submissionDiagnostic: MathSubmissionDiagnostic(object["submission_diagnostic"]))
  }

  private static func decodeEngineTimings(_ timings: Any?) -> [String: Double] {
    var durations: [String: Double] = [:]
    let allowed: Set<String> = ["engine_preparation", "model_acquisition", "tool_binding", "stream_total", "submission_validation", "first_sdk_chunk", "first_tool_arguments", "arguments_to_stream_end", "engine_total"]
    if let telemetry = timings as? [String: Any] {
      for (key, value) in telemetry where allowed.contains(key) {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 0 else { continue }
        durations[key] = number.doubleValue
      }
    }
    return durations
  }

}

/// All timestamps use the same monotonic clock, including model wait and network time.
struct ScreenshotQuestionPerformance: Sendable, Equatable {
  var startedAt: TimeInterval
  var firstTextAt: TimeInterval? = nil
  var completedAt: TimeInterval? = nil
  var usage: ScreenshotQuestionUsage? = nil

  /// Time until the first visible text; hidden reasoning does not count as visible output.
  var firstTokenLatency: TimeInterval? {
    guard startedAt.isFinite, let firstTextAt, firstTextAt.isFinite,
      firstTextAt >= startedAt
    else { return nil }
    let latency = firstTextAt - startedAt
    return latency.isFinite ? latency : nil
  }

  var elapsed: TimeInterval? {
    guard startedAt.isFinite, let completedAt, completedAt.isFinite,
      completedAt >= startedAt
    else { return nil }
    let duration = completedAt - startedAt
    return duration.isFinite ? duration : nil
  }

  /// Provider-reported output tokens / full request duration, including wait time
  /// and any reasoning tokens counted by the provider. This is not decoding speed.
  var averageTokensPerSecond: Double? {
    guard let outputTokens = usage?.outputTokens, outputTokens >= 0,
      let elapsed, elapsed > 0
    else { return nil }
    let rate = Double(outputTokens) / elapsed
    return rate.isFinite ? rate : nil
  }

  /// Only the outer local stages are added together. Engine and SDK landmarks
  /// are nested observations, not additional time or inferred provider phases.
  func breakdown(localDurations: [String: Double]) -> String {
    func valid(_ value: Double?) -> Double? {
      guard let value, value.isFinite, value >= 0 else { return nil }
      return value
    }
    func seconds(_ value: Double?) -> String {
      guard let value = valid(value) else { return "未记录" }
      if value > 0 && value < 0.001 { return "小于 0.001 秒" }
      return String(format: "%.3f 秒", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    let localStages = [
      ("methodLookup", "本机方法读取"), ("sourceIndex", "原图 OCR 索引"),
      ("skillRetrieval", "技能候选检索"), ("reviewedExampleRetrieval", "已审核例题检索"),
      ("promptAssembly", "提问组装"),
      ("modelRequest", "模型请求往返（含本机通信与引擎）"),
      ("answerProcessing", "答案校验与图解处理"), ("transcriptRendering", "界面排版"),
    ]
    var lines = ["本次总耗时：\(seconds(elapsed))", "首次可见文字：\(seconds(firstTokenLatency))（从本次提问开始，不另计）", "", "本机分段（以下阶段可相加）"]
    lines += localStages.map { "\($0.1)：\(seconds(localDurations[$0.0]))" }
    let observedLocal = localStages.compactMap { valid(localDurations[$0.0]) }.reduce(0, +)
    if let elapsed, observedLocal.isFinite {
      if observedLocal <= elapsed + 0.000_001 {
        lines.append("未单独记录的其余耗时：\(seconds(max(0, elapsed - observedLocal)))")
      } else {
        lines.append("本机分段合计超过总耗时；时钟存在重叠或不一致，不能计算其余耗时。")
      }
    } else {
      lines.append("总耗时未记录，不能计算其余耗时。")
    }
    let clocks = usage?.engineTimings ?? [:]
    let engineTotal = valid(clocks["engine_total"])
    lines += ["", "请求内的引擎明细（已包含在模型请求往返中，不再相加）", "引擎总计：\(seconds(engineTotal))"]
    let engineStages = [
      ("engine_preparation", "引擎准备"), ("model_acquisition", "模型客户端获取"),
      ("tool_binding", "工具绑定"), ("stream_total", "SDK 请求流（等待与接收）"),
      ("submission_validation", "引擎提交校验"),
    ]
    lines += engineStages.map { "\($0.1)：\(seconds(clocks[$0.0]))" }
    let terminationLabels = ["missing_terminal": "未收到有效结束标记", "token_limit": "服务报告达到输出上限",
      "content_filter": "服务报告内容过滤", "incomplete": "服务报告未完成",
      "provider_failure": "服务报告失败", "other_terminal": "其他未成功结束状态"]
    if let termination = usage?.streamTermination, let label = terminationLabels[termination] {
      lines += ["", "回答流结束状态：\(label)。未保存为完整答案。"]
    }
    if let diagnostic = usage?.submissionDiagnostic {
      lines += ["", "提交校验定位（仅记录字段名称，不记录题目或密钥）", "工具：\(diagnostic.tool)",
        "字段：\(diagnostic.path)", "规则：\(diagnostic.rule)"]
    }
    let observedEngine = engineStages.compactMap { valid(clocks[$0.0]) }.reduce(0, +)
    if let engineTotal, observedEngine.isFinite {
      if observedEngine <= engineTotal + 0.000_001 {
        lines.append("引擎其余未细分耗时：\(seconds(max(0, engineTotal - observedEngine)))")
      } else {
        lines.append("引擎分段合计超过引擎总计；时钟存在重叠或不一致，不能计算其余耗时。")
      }
    }
    if let request = valid(localDurations["modelRequest"]), let engineTotal {
      if engineTotal <= request + 0.000_001 {
        lines.append("请求往返中引擎以外的未细分耗时：\(seconds(max(0, request - engineTotal)))（不能据此区分进程启动、通信或调度）")
      } else {
        lines.append("引擎总计超过模型请求往返；时钟不一致，不能计算请求其余耗时。")
      }
    }
    lines += ["", "SDK 流内时间点（均从 SDK 请求流开始计时，不与上面累加）", "首个 SDK 数据块：\(seconds(clocks["first_sdk_chunk"]))", "首段工具参数：\(seconds(clocks["first_tool_arguments"]))"]
    if let stream = valid(clocks["stream_total"]),
      let first = valid(clocks["first_sdk_chunk"]),
      let arguments = valid(clocks["first_tool_arguments"]) {
      let tail = valid(clocks["arguments_to_stream_end"])
      if first <= arguments, arguments <= stream,
        tail.map({ abs(arguments + $0 - stream) <= 0.000_001 }) ?? true {
        lines.append("流内不重叠分段：开始至首块 \(seconds(first))；首块至首段参数 \(seconds(arguments - first))；首段参数至流结束 \(seconds(stream - arguments))。")
      } else {
        lines.append("SDK 流内时间点顺序或总长不一致，不能拆分流内耗时。")
      }
    }
    let failureLabels = ["preparation": "引擎准备", "model_acquisition": "模型客户端获取", "tool_binding": "工具绑定", "stream": "SDK 请求流", "submission_validation": "引擎提交校验"]
    if let phase = usage?.failurePhase, let label = failureLabels[phase] {
      lines += ["", "本次失败阶段：\(label)。已记录的耗时仍保留，缺失阶段不视为零。"]
    }
    lines += ["", "现有时钟无法分别测出网络、服务端排队、模型思考和生成耗时；首个 SDK 数据块也不代表用户已看到答案。"]
    return lines.joined(separator: "\n")
  }
}
