import CoreFoundation
import Foundation

struct ScreenshotQuestionUsage: Sendable, Equatable {
  var inputTokens: Int? = nil
  var outputTokens: Int? = nil
  var reasoningTokens: Int? = nil

  /// Usage is optional: malformed telemetry must never discard a valid answer.
  static func decode(_ value: Any?) -> Self? {
    guard let object = value as? [String: Any] else { return nil }
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
    guard !counts.isEmpty else { return nil }
    return Self(
      inputTokens: counts["input_tokens"], outputTokens: counts["output_tokens"],
      reasoningTokens: counts["reasoning_tokens"])
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
}
