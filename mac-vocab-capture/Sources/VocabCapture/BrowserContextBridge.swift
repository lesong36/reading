import Foundation
import Network

/// A loopback-only cache populated by the generic Chromium extension. It lets
/// the existing global hot key and floating button use the browser's exact DOM
/// sentence without changing their interaction model.
final class BrowserContextBridge {
  static let shared = BrowserContextBridge()

  private struct CachedContext {
    let word: String
    let sentence: String
    let receivedAt: Date
  }

  private let queue = DispatchQueue(label: "com.coty.vocab-capture.browser-context")
  private let port: NWEndpoint.Port = 38473
  private var listener: NWListener?
  private var cached: CachedContext?

  private init() {}

  func start() {
    queue.async { [weak self] in
      guard let self, self.listener == nil else { return }
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.receive(on: connection) }
        listener.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.listener = nil } }
        self.listener = listener
        listener.start(queue: self.queue)
      } catch {
        ContextDebugLog.write("浏览器语境桥接无法启动：\(error.localizedDescription)")
      }
    }
  }

  func sentence(for word: String) -> String? {
    queue.sync {
      guard let cached,
            Date().timeIntervalSince(cached.receivedAt) < 15,
            cached.word.caseInsensitiveCompare(word) == .orderedSame else { return nil }
      return cached.sentence
    }
  }

  private func receive(on connection: NWConnection, buffer: Data = Data()) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
      guard let self else { connection.cancel(); return }
      var accumulated = buffer
      if let data { accumulated.append(data) }
      guard let request = self.request(from: accumulated) else {
        if error == nil, !complete { self.receive(on: connection, buffer: accumulated) }
        else { connection.cancel() }
        return
      }
      self.cache(request)
      let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }

  private func request(from data: Data) -> (method: String, body: Data)? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator),
          let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    guard let parts = lines.first?.split(separator: " "), parts.count >= 2,
          parts[1] == "/browser-context" else { return (method: "", body: Data()) }
    let lengthLine = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
    let contentLength = lengthLine.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    return (String(parts[0]), Data(data[bodyStart..<(bodyStart + contentLength)]))
  }

  private func cache(_ request: (method: String, body: Data)) {
    guard request.method == "POST",
          let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let word = payload["word"] as? String,
          let context = payload["context"] as? String,
          let selection = SelectionReader.fromBrowserExtension(word: word, context: context) else { return }
    cached = CachedContext(word: selection.word, sentence: selection.context, receivedAt: Date())
    ContextDebugLog.write("浏览器扩展缓存原句", word: selection.word, context: selection.context)
  }
}
