import Foundation
import Network

/// Receives the exact selection and sentence from the Reading Master page on
/// localhost. This closes the gap where Chromium exposes selected text through
/// Accessibility but deliberately withholds the surrounding web content.
final class ReaderContextBridge {
  static let shared = ReaderContextBridge()

  private struct CachedContext {
    let word: String
    let sentence: String
    let receivedAt: Date
  }

  private let queue = DispatchQueue(label: "com.coty.vocab-capture.reader-context")
  private var listener: NWListener?
  private var cachedContext: CachedContext?
  private let port: NWEndpoint.Port = 38473

  private init() {}

  func start() {
    queue.async { [weak self] in
      guard let self, self.listener == nil else { return }
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.port)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
          self?.receive(on: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
          if case .failed = state { self?.listener = nil }
        }
        self.listener = listener
        listener.start(queue: self.queue)
      } catch {
        self.listener = nil
      }
    }
  }

  func sentence(for word: String) -> String? {
    queue.sync {
      guard let cachedContext,
            Date().timeIntervalSince(cachedContext.receivedAt) < 12,
            cachedContext.word.caseInsensitiveCompare(word) == .orderedSame else { return nil }
      return cachedContext.sentence
    }
  }

  private func receive(on connection: NWConnection, buffer: Data = Data()) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { connection.cancel(); return }
      var accumulated = buffer
      if let data { accumulated.append(data) }
      guard let request = self.parseRequest(accumulated) else {
        if error == nil, !isComplete { self.receive(on: connection, buffer: accumulated) }
        else { connection.cancel() }
        return
      }
      self.handle(request: request)
      let response = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }

  private func parseRequest(_ data: Data) -> (method: String, body: Data)? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator),
          let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    guard let first = lines.first?.split(separator: " ").map(String.init), first.count >= 2,
          first[1] == "/reader-context" else { return (method: "", body: Data()) }
    let contentLength = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") })
      .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    return (first[0], Data(data[bodyStart..<(bodyStart + contentLength)]))
  }

  private func handle(request: (method: String, body: Data)) {
    guard request.method == "POST",
          let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let word = payload["word"] as? String,
          let context = payload["context"] as? String else { return }
    let cleanedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedWord.isEmpty, cleanedWord.count <= 120,
          cleanedContext.count > cleanedWord.count, cleanedContext.count <= 800,
          cleanedContext.range(of: cleanedWord, options: .caseInsensitive) != nil else { return }
    cachedContext = CachedContext(word: cleanedWord, sentence: cleanedContext, receivedAt: Date())
  }
}
