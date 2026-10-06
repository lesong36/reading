import CoreFoundation
import Darwin
import Foundation

enum LangChainTransportError: LocalizedError {
  case unavailable, incompatibleRuntime, startupTimeout, requestTimeout, disconnected, connection

  var errorDescription: String? {
    switch self {
    case .unavailable: return "问一问引擎无法启动，请重新安装应用。"
    case .incompatibleRuntime: return "问一问引擎版本不兼容，需要 LangChain 1.4 或更高版本。"
    case .startupTimeout: return "问一问引擎启动超时，请重试。"
    case .requestTimeout: return "回答超时，请稍后重试。"
    case .disconnected: return "问一问引擎已断开，请重新提问。"
    case .connection: return "无法连接模型服务，请检查网络和系统代理后重试。"
    }
  }
}

/// Credentials travel only through anonymous pipes; they never enter arguments or logs.
actor LangChainQuestionTransport {
  private struct Request {
    let continuation: CheckedContinuation<String, Error>
    let onUsage: @MainActor @Sendable (ScreenshotQuestionUsage) -> Void
    let onProgress: @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void
    let onPartial: @MainActor @Sendable (String) -> Void
    let deadline: Task<Void, Never>
    var text = ""
    var byteCount = 0
  }

  private let executableURL: URL
  private let arguments: [String]
  private let environment: [String: String]?
  private let startupTimeout: TimeInterval
  private let requestTimeout: TimeInterval
  private let writer = DispatchQueue(label: "VocabCapture.questionEngine.stdin")
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var generation: UUID?
  private var ready = false
  private var reader: Task<Void, Never>?
  private var startupDeadline: Task<Void, Never>?
  private var startupWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var requests: [UUID: Request] = [:]

  init(
    executableURL: URL, arguments: [String] = [], environment: [String: String]? = nil,
    startupTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 95
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.startupTimeout = startupTimeout
    self.requestTimeout = requestTimeout
  }

  deinit {
    startupDeadline?.cancel()
    reader?.cancel()
    Self.terminate(process)
    try? input?.close()
    try? output?.close()
  }

  func warmUp() async throws {
    try Task.checkCancellation()
    if ready { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        startupWaiters[id] = continuation
        if process == nil { start() }
      }
    } onCancel: {
      Task { await self.cancelStartupWaiter(id) }
    }
  }

  func answer(
    payload: Data,
    onUsage: @escaping @MainActor @Sendable (ScreenshotQuestionUsage) -> Void = { _ in },
    onProgress: @escaping @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void = { _ in },
    onPartial: @escaping @MainActor @Sendable (String) -> Void
  ) async throws -> String {
    try await warmUp()
    try Task.checkCancellation()
    guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      throw ScreenshotQuestionError.invalidResponse
    }
    let id = UUID()
    object["id"] = id.uuidString
    object["op"] = "answer"
    let frame = try Self.frame(object)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        guard ready, let generation else {
          continuation.resume(throwing: LangChainTransportError.disconnected)
          return
        }
        let deadline = Task {
          do { try await Task.sleep(nanoseconds: Self.nanoseconds(requestTimeout)) } catch {
            return
          }
          expireRequest(id)
        }
        requests[id] = Request(
          continuation: continuation, onUsage: onUsage, onProgress: onProgress,
          onPartial: onPartial, deadline: deadline)
        write(frame, generation: generation)
      }
    } onCancel: {
      Task { await self.cancelRequest(id) }
    }
  }

  func shutdown() { stop(error: LangChainTransportError.disconnected) }

  private func start() {
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let token = UUID()
    child.executableURL = executableURL
    child.arguments = arguments
    child.environment = Self.sanitizedEnvironment(
      environment ?? ProcessInfo.processInfo.environment)
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    // A dead child must produce a write error instead of killing the application.
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      try? stdin.fileHandleForWriting.close()
      try? stdin.fileHandleForReading.close()
      try? stdout.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
      stop(error: LangChainTransportError.unavailable)
      return
    }
    do { try child.run() } catch {
      try? stdin.fileHandleForWriting.close()
      try? stdin.fileHandleForReading.close()
      try? stdout.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
      stop(error: LangChainTransportError.unavailable)
      return
    }
    // Parent-held child ends must close so process death reliably produces EOF.
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    process = child
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    generation = token
    let handle = stdout.fileHandleForReading
    // The read worker owns a duplicate until EOF. Closing the actor's handle
    // during restart cannot make it accidentally read a reused descriptor.
    let descriptor = dup(handle.fileDescriptor)
    guard descriptor >= 0 else {
      fail(token, error: LangChainTransportError.unavailable)
      return
    }
    let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(64)) { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
          // FileHandle.read(upToCount:) may wait to fill its buffer on pipes.
          // POSIX read returns currently available bytes, preserving first-token latency.
          let count = Darwin.read(descriptor, &bytes, bytes.count)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          switch continuation.yield(Data(bytes.prefix(count))) {
          case .dropped, .terminated:
            continuation.finish()
            return
          case .enqueued: break
          @unknown default:
            continuation.finish()
            return
          }
        }
        continuation.finish()
      }
    }
    reader = Task { [weak self] in
      var buffer = Data()
      for await chunk in stream {
        guard !Task.isCancelled else { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          guard line.count <= 1_048_576 else {
            await self?.fail(token, error: ScreenshotQuestionError.invalidResponse)
            return
          }
          await self?.consume(line, generation: token)
        }
        guard buffer.count <= 1_048_576 else {
          await self?.fail(token, error: ScreenshotQuestionError.invalidResponse)
          return
        }
      }
      await self?.fail(token, error: LangChainTransportError.disconnected)
    }
    startupDeadline = Task {
      do { try await Task.sleep(nanoseconds: Self.nanoseconds(startupTimeout)) } catch { return }
      fail(token, error: LangChainTransportError.startupTimeout)
    }
  }

  private func consume(_ data: Data, generation token: UUID) async {
    guard generation == token else { return }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      fail(token, error: ScreenshotQuestionError.invalidResponse)
      return
    }
    if !ready {
      guard type == "ready", let protocolVersion = object["protocol"] as? NSNumber,
        CFGetTypeID(protocolVersion) != CFBooleanGetTypeID(), protocolVersion == 1,
        let version = object["langchain_version"] as? String, Self.supports(version)
      else {
        fail(token, error: LangChainTransportError.incompatibleRuntime)
        return
      }
      ready = true
      startupDeadline?.cancel()
      startupDeadline = nil
      let waiters = startupWaiters.values
      startupWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      return
    }
    guard let rawID = object["id"] as? String, let id = UUID(uuidString: rawID),
      var request = requests[id]
    else { return }  // Late frames from cancelled requests are deliberately ignored.
    switch type {
    case "progress":
      guard let stage = object["stage"] as? String,
        let progress = ScreenshotQuestionSearchStage(rawValue: stage)
      else {
        finish(id, result: .failure(ScreenshotQuestionError.invalidResponse))
        sendCancel(id)
        return
      }
      await request.onProgress(progress)
    case "delta":
      guard let text = object["text"] as? String else {
        finish(id, result: .failure(ScreenshotQuestionError.invalidResponse))
        return
      }
      let byteCount = request.byteCount + text.utf8.count
      guard byteCount <= 1_048_576 else {
        finish(id, result: .failure(ScreenshotQuestionError.invalidResponse))
        sendCancel(id)
        return
      }
      requests.removeValue(forKey: id)
      request.text += text
      request.byteCount = byteCount
      requests[id] = request
      await request.onPartial(request.text)
    case "done":
      guard let text = object["text"] as? String else {
        finish(id, result: .failure(ScreenshotQuestionError.invalidResponse))
        return
      }
      let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !answer.isEmpty else {
        finish(id, result: .failure(ScreenshotQuestionError.emptyResponse))
        return
      }
      // Claim completion before yielding to the main actor, so duplicate or late
      // frames cannot report usage twice or attach it to a different request.
      requests.removeValue(forKey: id)
      request.deadline.cancel()
      if let usage = ScreenshotQuestionUsage.decode(object["usage"]) {
        await request.onUsage(usage)
      }
      request.continuation.resume(returning: answer)
    case "error":
      let error: Error
      switch object["code"] as? String {
      case "searchConfiguration": error = ScreenshotQuestionWebSearchError.notConfigured
      case "searchAuthentication": error = ScreenshotQuestionWebSearchError.authentication
      case "searchLimit": error = ScreenshotQuestionWebSearchError.limit
      case "searchTimeout": error = ScreenshotQuestionWebSearchError.timeout
      case "searchConnection": error = ScreenshotQuestionWebSearchError.connection
      case "searchResponse": error = ScreenshotQuestionWebSearchError.invalidResponse
      case "searchEmpty": error = ScreenshotQuestionWebSearchError.emptyResults
      case "searchQuery": error = ScreenshotQuestionWebSearchError.missingQuery
      case "server":
        if let status = object["status"] as? NSNumber,
          CFGetTypeID(status) != CFBooleanGetTypeID(),
          (100...599).contains(status.intValue), status.doubleValue == Double(status.intValue)
        {
          error = ScreenshotQuestionError.server(status.intValue)
        } else {
          error = ScreenshotQuestionError.invalidResponse
        }
      case "connection": error = LangChainTransportError.connection
      case "thinkingUnsupported": error = ScreenshotQuestionError.unsupportedThinking
      case "truncated": error = ScreenshotQuestionError.truncatedResponse
      case "empty": error = ScreenshotQuestionError.emptyResponse
      case "timeout": error = LangChainTransportError.requestTimeout
      default: error = ScreenshotQuestionError.invalidResponse
      }
      finish(id, result: .failure(error))
    default: finish(id, result: .failure(ScreenshotQuestionError.invalidResponse))
    }
  }

  private func write(_ data: Data, generation token: UUID) {
    guard let input else { return }
    writer.async { [weak self] in
      do { try input.write(contentsOf: data) } catch {
        Task { await self?.fail(token, error: LangChainTransportError.disconnected) }
      }
    }
  }

  private func finish(_ id: UUID, result: Result<String, Error>) {
    guard let request = requests.removeValue(forKey: id) else { return }
    request.deadline.cancel()
    request.continuation.resume(with: result)
  }

  private func cancelRequest(_ id: UUID) {
    guard requests[id] != nil else { return }
    finish(id, result: .failure(CancellationError()))
    sendCancel(id)
  }

  private func expireRequest(_ id: UUID) {
    guard requests[id] != nil else { return }
    finish(id, result: .failure(LangChainTransportError.requestTimeout))
    sendCancel(id)
  }

  private func sendCancel(_ id: UUID) {
    guard let generation, let frame = try? Self.frame(["op": "cancel", "id": id.uuidString]) else {
      return
    }
    write(frame, generation: generation)
  }

  private func cancelStartupWaiter(_ id: UUID) {
    startupWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func fail(_ token: UUID, error: Error) {
    guard generation == token else { return }
    stop(error: error)
  }

  private func stop(error: Error) {
    generation = nil
    ready = false
    startupDeadline?.cancel()
    startupDeadline = nil
    reader?.cancel()
    reader = nil
    Self.terminate(process)
    try? input?.close()
    input = nil
    process = nil
    try? output?.close()
    output = nil
    let waiters = startupWaiters.values
    startupWaiters.removeAll()
    for waiter in waiters { waiter.resume(throwing: error) }
    for id in Array(requests.keys) { finish(id, result: .failure(error)) }
  }

  private static func frame(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(10)
    return data
  }

  private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
  }

  private static func supports(_ version: String) -> Bool {
    let pieces = version.split(separator: ".")
    guard pieces.count >= 2, let major = Int(pieces[0]), let minor = Int(pieces[1]) else {
      return false
    }
    guard major == 1, minor >= 4, pieces.count >= 3,
      Int(pieces[2]) != nil
    else { return false }
    return true
  }

  private static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.filter { key, _ in
      let key = key.uppercased()
      return !["LANGSMITH", "LANGCHAIN", "OPENAI", "ANTHROPIC", "AZURE"].contains(
        where: key.hasPrefix)
        && key != "PYTHONPATH" && key != "PYTHONHOME"
    }
  }

  private static func terminate(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
}
