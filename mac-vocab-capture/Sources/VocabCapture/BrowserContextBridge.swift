import Foundation
import Network

struct BrowserBridgeRequest {
  let method: String
  let headers: [String: String]
  let body: Data
}
enum BrowserBridgeParseResult {
  case incomplete, rejected(Int), request(BrowserBridgeRequest)
}
enum BrowserBridgeHTTP {
  static let headerLimit = 16 * 1024
  static let bodyLimit = 256 * 1024
  static func parse(_ data: Data, expectedHost: String = "127.0.0.1:38473") -> BrowserBridgeParseResult {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
      return data.count > headerLimit ? .rejected(413) : .incomplete
    }
    guard separator.upperBound <= headerLimit else { return .rejected(413) }
    guard let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return .rejected(400) }
    let lines = header.components(separatedBy: "\r\n")
    guard let first = lines.first?.split(separator: " "), first.count == 3,
      first[1] == "/browser-context", first[2] == "HTTP/1.1" else { return .rejected(400) }
    let method = String(first[0])
    guard ["POST", "OPTIONS"].contains(method) else { return .rejected(405) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return .rejected(400) }
      let key = parts[0].lowercased()
      guard headers[key] == nil else { return .rejected(400) }
      headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    guard headers["host"] == expectedHost, headers["transfer-encoding"] == nil else { return .rejected(400) }
    let raw = headers["content-length"] ?? (method == "OPTIONS" ? "0" : "")
    guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(raw), length <= bodyLimit else { return .rejected(413) }
    let available = data.count - separator.upperBound
    guard available <= bodyLimit else { return .rejected(413) }
    guard available >= length else { return .incomplete }
    guard available == length else { return .rejected(400) }
    if method == "POST", headers["content-type"]?.lowercased().split(separator: ";").first != "application/json" { return .rejected(415) }
    return .request(BrowserBridgeRequest(method: method, headers: headers, body: Data(data[separator.upperBound...])))
  }
}

/// Authenticated loopback bridge. Only a recently confirmed active browser selection is cached.
// Mutable bridge state is accessed only on its serial queue; selection reads
// can therefore share the same bridge across the AX executor and main actor.
final class BrowserContextBridge: @unchecked Sendable {
  static let shared = BrowserContextBridge()
  private struct CachedContext {
    let word: String
    let sentence: String
    let receivedAt: Date
  }
  private struct PublisherState {
    var cached: CachedContext?
    var sessionID: String?
    var sequence = -1
    var retiredSessions: [String: Date] = [:]
  }
  // Fixed allowlist bounds publisher state and matches the actual foreground app.
  private static let browserIDs = ["com.google.Chrome": "chrome", "com.microsoft.edgemac": "edge"]
  private let queue = DispatchQueue(label: "com.coty.vocab-capture.browser-context")
  private let queueKey = DispatchSpecificKey<Bool>()
  private let defaults: UserDefaults
  private let now: () -> Date
  private let listenPort: NWEndpoint.Port
  private let connectionDeadline: TimeInterval
  private var listener: NWListener?
  private var publishers: [String: PublisherState] = [:]
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var captureNonces: [String: Date] = [:]
  private var token: String
  private var origin: String?
  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, port: UInt16 = 38473, connectionDeadline: TimeInterval = 10) {
    self.defaults = defaults
    self.now = now
    self.listenPort = NWEndpoint.Port(rawValue: port)!
    self.connectionDeadline = connectionDeadline
    token = defaults.string(forKey: "browserBridgePairingToken") ?? UUID().uuidString + UUID().uuidString
    origin = defaults.string(forKey: "browserBridgePairedOrigin")
    defaults.set(token, forKey: "browserBridgePairingToken")
    queue.setSpecific(key: queueKey, value: true)
  }
  var activeConnectionCount: Int { queue.sync { connections.count } }
  func stop() { queue.sync { listener?.cancel(); listener = nil; for connection in connections.values { connection.cancel() }; connections.removeAll() } }
  var pairingToken: String { queue.sync { token } }
  func isAuthorizedCapture(token candidate: String?) -> Bool {
    queue.sync {
      captureNonces = captureNonces.filter { now().timeIntervalSince($0.value) < 15 }
      guard let candidate, captureNonces.removeValue(forKey: candidate) != nil else { return false }
      return true
    }
  }
  func rotatePairingToken() {
    queue.sync {
      token = UUID().uuidString + UUID().uuidString
      origin = nil; publishers.removeAll(); captureNonces.removeAll()
      defaults.set(token, forKey: "browserBridgePairingToken")
      defaults.removeObject(forKey: "browserBridgePairedOrigin")
    }
  }
  func start() {
    queue.async { [weak self] in
      guard let self, self.listener == nil else { return }
      do {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.listenPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.listener = nil } }
        self.listener = listener; listener.start(queue: self.queue)
      } catch { ContextDebugLog.write("浏览器语境桥接无法启动") }
    }
  }
  func sentence(for word: String, browserBundleIdentifier: String?) -> String? {
    queue.sync {
      guard let identifier = browserBundleIdentifier, let browserID = Self.browserIDs[identifier],
        let cached = publishers[browserID]?.cached else { return nil }
      guard now().timeIntervalSince(cached.receivedAt) < 2.5 else {
        publishers[browserID]?.cached = nil; return nil
      }
      guard cached.word.caseInsensitiveCompare(word) == .orderedSame else { return nil }
      return cached.sentence
    }
  }
  /// Deterministic authenticated request seam, serialized with production cache updates.
  func handle(_ request: BrowserBridgeRequest) -> Int {
    if DispatchQueue.getSpecific(key: queueKey) == true { return handleOnQueue(request) }
    return queue.sync { handleOnQueue(request) }
  }
  private func handleOnQueue(_ request: BrowserBridgeRequest) -> Int {
    guard let proposedOrigin = request.headers["origin"],
      proposedOrigin.range(of: "^chrome-extension://[a-p]{32}$", options: .regularExpression) != nil else { return 403 }
    if request.method == "OPTIONS" { return 204 }
    guard request.headers["x-vocab-token"] == token, origin == nil || origin == proposedOrigin else { return 401 }
    guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
      let action = payload["action"] as? String else { return 400 }
    guard let browserID = payload["browserID"] as? String,
      Self.browserIDs.values.contains(browserID) else { return 422 }
    if action == "pair" {
      origin = proposedOrigin; defaults.set(origin, forKey: "browserBridgePairedOrigin"); return 204
    }
    guard ["context", "capture", "invalidate"].contains(action) else { return 400 }
    var publisher = publishers[browserID] ?? PublisherState()
    publisher.retiredSessions = publisher.retiredSessions.filter { now().timeIntervalSince($0.value) < 15 }
    guard origin == proposedOrigin, let session = payload["session"] as? String,
      !session.isEmpty, session.count <= 80, publisher.retiredSessions[session] == nil,
      let revision = payload["revision"] as? Int, revision >= 0 else { return 409 }
    if publisher.sessionID != session {
      // Guard stale workers within this browser without retiring other browsers.
      if let previous = publisher.sessionID {
        guard publisher.retiredSessions.count < 32 else { return 409 }
        publisher.retiredSessions[previous] = now()
      }
      publisher.sessionID = session; publisher.sequence = -1; publisher.cached = nil
    }
    guard revision > publisher.sequence else { return 409 }
    publisher.sequence = revision
    defer { publishers[browserID] = publisher }
    if action == "invalidate" { publisher.cached = nil; return 204 }
    guard payload["active"] as? Bool == true,
      let tab = payload["tabID"] as? Int, tab >= 0,
      let window = payload["windowID"] as? Int, window >= 0,
      let url = payload["url"] as? String, url.count <= 4096,
      let sourceURL = URL(string: url), ["http", "https", "file"].contains(sourceURL.scheme ?? ""),
      let word = payload["word"] as? String, let context = payload["context"] as? String,
      let selection = SelectionReader.fromBrowserExtension(word: word, context: context) else { publisher.cached = nil; return 422 }
    if action == "capture" {
      guard let nonce = payload["captureToken"] as? String, UUID(uuidString: nonce) != nil else { return 422 }
      captureNonces = captureNonces.filter { now().timeIntervalSince($0.value) < 15 }
      guard captureNonces.count < 8 else { return 429 }
      captureNonces[nonce] = now()
    }
    let receivedAt = now()
    publisher.cached = CachedContext(word: selection.word, sentence: selection.context, receivedAt: receivedAt)
    queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      guard let self, let cached = self.publishers[browserID]?.cached, self.now().timeIntervalSince(cached.receivedAt) >= 2.5 else { return }
      self.publishers[browserID]?.cached = nil
    }
    ContextDebugLog.write("浏览器扩展缓存原句", word: selection.word, context: selection.context)
    return 204
  }
  private func accept(_ connection: NWConnection) {
    guard connections.count < 8 else { connection.cancel(); return }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + connectionDeadline) { [weak self, weak connection] in
      guard let self, let connection, self.connections[id] != nil else { return }
      self.close(connection)
    }
    receive(on: connection, buffer: Data())
  }
  private func close(_ connection: NWConnection) {
    connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel()
  }
  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
      guard let self, self.connections[ObjectIdentifier(connection)] != nil else { connection.cancel(); return }
      var accumulated = buffer
      if let data { accumulated.append(data) }
      switch BrowserBridgeHTTP.parse(accumulated, expectedHost: "127.0.0.1:\(self.listenPort.rawValue)") {
      case .incomplete:
        if error == nil, !complete { self.receive(on: connection, buffer: accumulated) }
        else { self.reply(400, origin: nil, connection: connection) }
      case .rejected(let status): self.reply(status, origin: nil, connection: connection)
      case .request(let request):
        let status = self.handle(request)
        self.reply(status, origin: status == 204 ? request.headers["origin"] : nil, connection: connection)
      }
    }
  }
  private func reply(_ status: Int, origin: String?, connection: NWConnection) {
    let cors = origin.map { "Access-Control-Allow-Origin: \($0)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-Vocab-Token\r\n" } ?? ""
    let response = "HTTP/1.1 \(status) \(status == 204 ? "No Content" : "Rejected")\r\n\(cors)Content-Length: 0\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in self?.close(connection) })
  }
}
