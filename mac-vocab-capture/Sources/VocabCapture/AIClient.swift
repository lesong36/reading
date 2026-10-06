import Foundation

enum DictionaryBackend: String, Codable, CaseIterable, Sendable {
  case openAICompatible, llamaCpp

  var title: String {
    switch self {
    case .openAICompatible: return "OpenAI 兼容服务"
    case .llamaCpp: return "llama.cpp（支持思考开关）"
    }
  }
}

struct AIConfiguration: Codable, Sendable {
  var baseURL: String
  var model: String
  var apiKey: String
  var thinking: ScreenshotQuestionThinking = .off
  var backend: DictionaryBackend = .openAICompatible

  var isComplete: Bool { (try? DictionaryRequestPolicy.normalized(self)) != nil }

  init(baseURL: String, model: String, apiKey: String, thinking: ScreenshotQuestionThinking = .off, backend: DictionaryBackend = .openAICompatible) {
    self.baseURL = baseURL
    self.model = model
    self.apiKey = apiKey
    self.thinking = thinking
    self.backend = backend
  }

  private enum CodingKeys: String, CodingKey { case baseURL, model, apiKey, thinking, backend }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    baseURL = try values.decode(String.self, forKey: .baseURL)
    model = try values.decode(String.self, forKey: .model)
    apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    thinking = try values.decodeIfPresent(ScreenshotQuestionThinking.self, forKey: .thinking) ?? .off
    backend = try values.decodeIfPresent(DictionaryBackend.self, forKey: .backend) ?? .openAICompatible
  }
}

private actor DictionaryProgress {
  private(set) var hasContent = false
  func receivedContent() { hasContent = true }
}

private struct DictionaryHTTPFailure: Error {
  let status: Int
  let retryAfter: TimeInterval?
  var classified: DictionaryClientError {
    switch status {
    case 401, 403: return .authentication
    case 429: return .rateLimited
    case 500...599: return .serviceUnavailable(status)
    default: return .invalidRequest(status)
    }
  }
}

actor DictionaryClient {
  private struct CacheKey: Hashable {
    let word: String
    let context: String
    let baseURL: String
    let model: String
    let credential: String
    let thinking: String
    let backend: String
  }
  private struct Subscriber {
    let continuation: CheckedContinuation<DictionaryResult, Error>
    let meaning: (@MainActor @Sendable (String) -> Void)?
    let performance: (@MainActor @Sendable (DictionaryPerformance) -> Void)?
  }
  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
    var subscribers: [UUID: Subscriber]
    var meaning: String?
  }
  private struct Completed: Sendable {
    let result: DictionaryResult
    let performance: DictionaryPerformance
  }

  private let session: URLSession
  private let cacheLimit: Int
  private let budget: DictionaryRequestBudget
  private var cache: [CacheKey: DictionaryResult] = [:]
  private var cacheOrder: [CacheKey] = []
  private var flights: [CacheKey: Flight] = [:]

  init(session: URLSession? = nil, cacheLimit: Int = 100, budget: DictionaryRequestBudget = DictionaryRequestBudget()) {
    if let session { self.session = session }
    else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = max(1, budget.firstContentTimeout)
      configuration.timeoutIntervalForResource = max(1, budget.totalTimeout)
      self.session = URLSession(configuration: configuration)
    }
    self.cacheLimit = max(0, cacheLimit)
    self.budget = budget
  }

  func lookup(
    _ selection: SelectedText, configuration input: AIConfiguration,
    onMeaning: (@MainActor @Sendable (String) -> Void)? = nil,
    onPerformance: (@MainActor @Sendable (DictionaryPerformance) -> Void)? = nil
  ) async throws -> DictionaryResult {
    try Task.checkCancellation()
    guard input.isComplete else { throw VocabularyError.missingConfiguration }
    let configuration = try DictionaryRequestPolicy.normalized(input)
    let key = CacheKey(word: selection.word, context: selection.context,
      baseURL: configuration.baseURL, model: configuration.model, credential: configuration.apiKey,
      thinking: configuration.thinking.rawValue, backend: configuration.backend.rawValue)
    if let result = cache[key] {
      let started = ProcessInfo.processInfo.systemUptime
      if let onMeaning { await onMeaning(result.meaning) }
      try Task.checkCancellation()
      if let onPerformance {
        await onPerformance(DictionaryPerformance(totalSeconds: ProcessInfo.processInfo.systemUptime - started, cacheHit: true))
      }
      try Task.checkCancellation()
      return result
    }
    let subscriberID = UUID()
    let result: DictionaryResult = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        let subscriber = Subscriber(continuation: continuation, meaning: onMeaning, performance: onPerformance)
        if var flight = flights[key] {
          flight.subscribers[subscriberID] = subscriber
          flights[key] = flight
          if let meaning = flight.meaning, let onMeaning {
            Task { @MainActor in
              guard await self.isSubscribed(key, id: subscriberID) else { return }
              onMeaning(meaning)
            }
          }
        } else {
          let flightID = UUID()
          let task = Task {
            do {
              let value = try await self.performLookup(selection, configuration: configuration, key: key, flightID: flightID)
              await self.finish(key, flightID: flightID, completed: value, error: nil)
            } catch {
              await self.finish(key, flightID: flightID, completed: nil, error: error)
            }
          }
          flights[key] = Flight(id: flightID, task: task, subscribers: [subscriberID: subscriber])
        }
      }
    } onCancel: {
      Task { await self.unsubscribe(key, id: subscriberID) }
    }
    try Task.checkCancellation()
    return result
  }

  private func isSubscribed(_ key: CacheKey, id: UUID) -> Bool { flights[key]?.subscribers[id] != nil }

  private func unsubscribe(_ key: CacheKey, id: UUID) {
    guard var flight = flights[key], let subscriber = flight.subscribers.removeValue(forKey: id) else { return }
    subscriber.continuation.resume(throwing: CancellationError())
    if flight.subscribers.isEmpty {
      flights.removeValue(forKey: key)
      flight.task.cancel()
    } else { flights[key] = flight }
  }

  private func publish(_ meaning: String, key: CacheKey, flightID: UUID) async {
    guard var flight = flights[key], flight.id == flightID else { return }
    flight.meaning = meaning
    flights[key] = flight
    for (id, subscriber) in flight.subscribers {
      guard isSubscribed(key, id: id), let callback = subscriber.meaning else { continue }
      await callback(meaning)
    }
  }

  private func finish(_ key: CacheKey, flightID: UUID, completed: Completed?, error: Error?) async {
    guard let flight = flights[key], flight.id == flightID else { return }
    // Remove before resuming callers so the next retry cannot join an ended request.
    flights.removeValue(forKey: key)
    if let completed, !flight.subscribers.isEmpty, cacheLimit > 0 {
      if cache[key] == nil { cacheOrder.append(key) }
      cache[key] = completed.result
      if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    for subscriber in flight.subscribers.values {
      if let completed {
        if let callback = subscriber.performance { await callback(completed.performance) }
        subscriber.continuation.resume(returning: completed.result)
      } else { subscriber.continuation.resume(throwing: error ?? DictionaryClientError.invalidResponse) }
    }
  }

  private func performLookup(_ selection: SelectedText, configuration: AIConfiguration, key: CacheKey, flightID: UUID) async throws -> Completed {
    let started = ProcessInfo.processInfo.systemUptime
    let progress = DictionaryProgress()
    let budget = self.budget
    return try await withThrowingTaskGroup(of: Completed?.self) { group in
      group.addTask {
        try await self.load(selection, configuration: configuration, key: key, flightID: flightID, progress: progress, started: started)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0.001, budget.firstContentTimeout) * 1_000_000_000))
        guard await !progress.hasContent else { return nil }
        throw DictionaryClientError.firstContentTimeout
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(max(0.001, budget.totalTimeout) * 1_000_000_000))
        throw DictionaryClientError.requestTimedOut
      }
      defer { group.cancelAll() }
      for try await value in group { if let value { return value } }
      throw DictionaryClientError.invalidResponse
    }
  }

  private func load(_ selection: SelectedText, configuration: AIConfiguration, key: CacheKey, flightID: UUID, progress: DictionaryProgress, started: TimeInterval) async throws -> Completed {
    var request = try DictionaryRequestPolicy.request(selection: selection, configuration: configuration)
    request.timeoutInterval = max(1, budget.firstContentTimeout)
    for attempt in 0...1 {
      do {
        return try await consume(request, key: key, flightID: flightID, progress: progress, started: started)
      } catch let failure as DictionaryHTTPFailure {
        guard attempt == 0, [429, 502, 503, 504].contains(failure.status),
          flights[key]?.meaning == nil
        else { throw failure.classified }
        let remaining = budget.totalTimeout - (ProcessInfo.processInfo.systemUptime - started)
        let delay = max(0, failure.retryAfter ?? 0.25)
        guard delay < remaining else { throw failure.classified }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      } catch is CancellationError { throw CancellationError() }
      catch let error as DictionaryClientError { throw error }
      catch let error as VocabularyError { throw error }
      catch let error as URLError {
        if error.code == .cancelled { throw CancellationError() }
        if error.code == .timedOut { throw DictionaryClientError.requestTimedOut }
        throw DictionaryClientError.network
      } catch { throw DictionaryClientError.invalidResponse }
    }
    throw DictionaryClientError.invalidResponse
  }

  private func consume(_ request: URLRequest, key: CacheKey, flightID: UUID, progress: DictionaryProgress, started: TimeInterval) async throws -> Completed {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw DictionaryClientError.invalidResponse }
    guard 200..<300 ~= http.statusCode else {
      let value = http.value(forHTTPHeaderField: "Retry-After")
      let seconds = DictionaryRequestPolicy.retryDelay(value)
      throw DictionaryHTTPFailure(status: http.statusCode, retryAfter: seconds)
    }
    var metrics = DictionaryPerformance(headersSeconds: ProcessInfo.processInfo.systemUptime - started)
    var content = ""
    var totalBytes = 0
    var meaningPublished = false
    var successfulTerminal = false
    if http.mimeType == "text/event-stream" {
      var payload = ""
      var lineBytes = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        totalBytes += 1
        guard totalBytes <= budget.maximumResponseBytes else { throw DictionaryClientError.responseTooLarge }
        if byte != 10 {
          lineBytes.append(byte)
          guard lineBytes.count <= budget.maximumLineBytes else { throw DictionaryClientError.responseTooLarge }
          continue
        }
        if lineBytes.last == 13 { lineBytes.removeLast() }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.isEmpty {
          if !payload.isEmpty {
            successfulTerminal = try await consumeEvent(payload, content: &content, meaningPublished: &meaningPublished,
              metrics: &metrics, key: key, flightID: flightID, progress: progress, started: started)
            payload = ""
            if successfulTerminal { break }
          }
        } else if line.hasPrefix("data:") {
          if !payload.isEmpty { payload += "\n" }
          let value = line.dropFirst(5)
          payload += value.first == " " ? String(value.dropFirst()) : String(value)
          guard payload.utf8.count <= budget.maximumEventBytes else { throw DictionaryClientError.responseTooLarge }
        }
      }
      if !successfulTerminal {
        if !lineBytes.isEmpty {
          let line = String(decoding: lineBytes, as: UTF8.self)
          if line.hasPrefix("data:") { payload += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }
        guard payload.utf8.count <= budget.maximumEventBytes else { throw DictionaryClientError.responseTooLarge }
        if !payload.isEmpty {
          successfulTerminal = try await consumeEvent(payload, content: &content, meaningPublished: &meaningPublished,
            metrics: &metrics, key: key, flightID: flightID, progress: progress, started: started)
        }
      }
      guard successfulTerminal else { throw DictionaryClientError.incompleteResponse }
    } else {
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        totalBytes += 1
        guard totalBytes <= budget.maximumResponseBytes else { throw DictionaryClientError.responseTooLarge }
        data.append(byte)
      }
      guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        envelope["error"] == nil,
        let choice = (envelope["choices"] as? [[String: Any]])?.first,
        choice["finish_reason"] as? String == "stop",
        let message = choice["message"] as? [String: Any], let value = message["content"] as? String
      else { throw DictionaryClientError.incompleteResponse }
      content = value
      metrics.firstTokenSeconds = ProcessInfo.processInfo.systemUptime - started
      await progress.receivedContent()
    }
    try Task.checkCancellation()
    let result: DictionaryResult
    do { result = try JSONDecoder().decode(DictionaryResult.self, from: Data(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) }
    catch { throw DictionaryClientError.invalidResponse }
    guard !result.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DictionaryClientError.invalidResponse }
    if !meaningPublished {
      metrics.firstMeaningSeconds = ProcessInfo.processInfo.systemUptime - started
      await publish(result.meaning, key: key, flightID: flightID)
    }
    try Task.checkCancellation()
    metrics.totalSeconds = ProcessInfo.processInfo.systemUptime - started
    ContextDebugLog.write("取词完成：\(metrics.summary)")
    return Completed(result: result, performance: metrics)
  }

  private func consumeEvent(_ payload: String, content: inout String, meaningPublished: inout Bool, metrics: inout DictionaryPerformance, key: CacheKey, flightID: UUID, progress: DictionaryProgress, started: TimeInterval) async throws -> Bool {
    if payload == "[DONE]" { return true }
    guard let envelope = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], envelope["error"] == nil
    else { throw DictionaryClientError.invalidResponse }
    guard let choice = (envelope["choices"] as? [[String: Any]])?.first else { return false }
    let reason = choice["finish_reason"] as? String
    if let reason, reason != "stop" { throw DictionaryClientError.incompleteResponse }
    if let delta = choice["delta"] as? [String: Any], let fragment = delta["content"] as? String, !fragment.isEmpty {
      content += fragment
      if metrics.firstTokenSeconds == nil {
        metrics.firstTokenSeconds = ProcessInfo.processInfo.systemUptime - started
        await progress.receivedContent()
      }
    }
    if !meaningPublished, let meaning = Self.completedMeaning(in: content), !meaning.isEmpty {
      meaningPublished = true
      metrics.firstMeaningSeconds = ProcessInfo.processInfo.systemUptime - started
      await publish(meaning, key: key, flightID: flightID)
    }
    return reason == "stop"
  }

  // Scan JSON structure, then let JSONDecoder handle escapes and Unicode surrogate pairs.
  // A closing quote is required before a preview can be published.
  static func completedMeaning(in content: String) -> String? {
    let bytes = Array(content.utf8)
    guard let first = bytes.firstIndex(of: 123) else { return nil }
    var depth = 1
    var expectsKey = true
    var index = first + 1
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 34 {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
          if !escaped && bytes[index] == 34 { break }
          if !escaped && bytes[index] == 92 { escaped = true } else { escaped = false }
          index += 1
        }
        guard index < bytes.count else { return nil }
        if depth == 1 && expectsKey {
          guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
          else { return nil }
          expectsKey = false
          index += 1
          while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
          guard index < bytes.count && bytes[index] == 58 else { return nil }
          index += 1
          while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
          if key == "meaning" {
            guard index < bytes.count && bytes[index] == 34 else { return nil }
            let valueStart = index
            index += 1
            escaped = false
            while index < bytes.count {
              if !escaped && bytes[index] == 34 {
                return try? JSONDecoder().decode(String.self, from: Data(bytes[valueStart...index]))
              }
              if !escaped && bytes[index] == 92 { escaped = true } else { escaped = false }
              index += 1
            }
            return nil
          }
          continue
        }
      } else if byte == 123 || byte == 91 {
        depth += 1
      } else if byte == 125 || byte == 93 {
        depth -= 1
        if depth == 0 { return nil }
      } else if byte == 44 && depth == 1 {
        expectsKey = true
      }
      index += 1
    }
    return nil
  }
}
