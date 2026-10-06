import XCTest
import Network
@testable import VocabCapture

final class BrowserBridgeSecurityTests: XCTestCase {
  private let origin = "chrome-extension://" + String(repeating: "a", count: 32)
  private func parse(_ length: String, body: String = "", extra: String = "") -> BrowserBridgeParseResult {
    BrowserBridgeHTTP.parse(Data("POST /browser-context HTTP/1.1\r\nHost: 127.0.0.1:38473\r\nContent-Type: application/json\r\nContent-Length: \(length)\r\n\(extra)\r\n\(body)".utf8))
  }
  func testRejectsMalformedLengthWithoutOverflowAndBoundsAllBytes() {
    for length in ["-1", String(Int.max), String(Int.max) + "0", "abc", "", "262145"] {
      if case .rejected = parse(length) {} else { XCTFail("Accepted invalid length \(length)") }
    }
    if case .incomplete = parse("3", body: "{") {} else { XCTFail("Half body must await completion") }
    if case .rejected(400) = parse("0", extra: "Content-Length: 0\r\n") {} else { XCTFail("Duplicate length") }
    if case .rejected(413) = BrowserBridgeHTTP.parse(Data(repeating: 65, count: 16385)) {} else { XCTFail("Unterminated headers") }
    if case .rejected(413) = parse("0", body: String(repeating: "x", count: 262145)) {} else { XCTFail("Accumulated body") }
    if case .rejected(400) = parse("0", body: "x") {} else { XCTFail("Extra bytes") }
  }
  func testOnlyExpectedHostMethodAndContentTypeAreAccepted() {
    let request = "POST /browser-context HTTP/1.1\r\nHost: 127.0.0.1:38473\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"
    for invalid in [request.replacingOccurrences(of: "127.0.0.1:38473", with: "evil.test"), request.replacingOccurrences(of: "POST", with: "GET"), request.replacingOccurrences(of: "application/json", with: "text/plain"), request.replacingOccurrences(of: "Content-Length: 0", with: "Transfer-Encoding: chunked")] {
      if case .rejected = BrowserBridgeHTTP.parse(Data(invalid.utf8)) {} else { XCTFail("Accepted invalid request") }
    }
    if case .request = BrowserBridgeHTTP.parse(Data(request.utf8)) {} else { XCTFail("Rejected valid request") }
  }
  func testPairingRevocationActiveRevisionAndTTL() throws {
    let suite = "BrowserBridgeSecurityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var date = Date(timeIntervalSince1970: 100)
    let bridge = BrowserContextBridge(defaults: defaults, now: { date })
    let token = bridge.pairingToken
    func request(_ payload: [String: Any], key: String? = nil, source: String? = nil) throws -> BrowserBridgeRequest {
      BrowserBridgeRequest(method: "POST", headers: ["origin": source ?? origin, "x-vocab-token": key ?? token], body: try JSONSerialization.data(withJSONObject: ["browserID": "chrome"].merging(payload) { _, value in value }))
    }
    XCTAssertEqual(try bridge.handle(request(["action": "pair"], key: "wrong")), 401)
    XCTAssertEqual(try bridge.handle(request(["action": "pair"], source: "https://evil.test")), 403)
    XCTAssertEqual(try bridge.handle(request(["action": "pair"])), 204)
    let context: [String: Any] = ["action": "context", "session": "test", "revision": 1,
      "active": true, "tabID": 1, "windowID": 2, "url": "https://example.test/", "word": "bank", "context": "The bank is closed."]
    XCTAssertEqual(try bridge.handle(request(context)), 204)
    XCTAssertEqual(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"), "The bank is closed.")
    XCTAssertNil(bridge.sentence(for: "cat", browserBundleIdentifier: "com.google.Chrome"))
    XCTAssertEqual(try bridge.handle(request(["action": "invalidate", "session": "test", "revision": 2])), 204)
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"))
    XCTAssertEqual(try bridge.handle(request(context)), 409)
    var latest = context; latest["revision"] = 3
    XCTAssertEqual(try bridge.handle(request(latest)), 204)
    date = date.addingTimeInterval(3)
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"))
    let nonce = UUID().uuidString
    latest["action"] = "capture"; latest["captureToken"] = nonce; latest["revision"] = 4
    XCTAssertEqual(try bridge.handle(request(latest)), 204)
    XCTAssertTrue(bridge.isAuthorizedCapture(token: nonce))
    XCTAssertFalse(bridge.isAuthorizedCapture(token: nonce))
    XCTAssertFalse(bridge.isAuthorizedCapture(token: token), "Long-lived pairing token cannot authorize a URL")
    bridge.rotatePairingToken()
    XCTAssertNotEqual(bridge.pairingToken, token)
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"))
    XCTAssertEqual(try bridge.handle(request(["action": "pair"])), 401)
  }
  func testSwitchingEdgeChromeEdgeDoesNotRetireEdgePublisher() throws {
    let suite = "BrowserBridgePublishers.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let bridge = BrowserContextBridge(defaults: defaults)
    func send(_ browser: String, _ session: String, _ revision: Int, _ sentence: String) throws -> Int {
      let payload: [String: Any] = ["action": "context", "browserID": browser, "session": session,
        "revision": revision, "active": true, "tabID": 1, "windowID": 2,
        "url": "https://example.test/", "word": "bank", "context": sentence]
      return bridge.handle(BrowserBridgeRequest(method: "POST", headers: ["origin": origin,
        "x-vocab-token": bridge.pairingToken], body: try JSONSerialization.data(withJSONObject: ["browserID": "chrome"].merging(payload) { _, value in value })))
    }
    XCTAssertEqual(bridge.handle(BrowserBridgeRequest(method: "POST", headers: ["origin": origin,
      "x-vocab-token": bridge.pairingToken], body: Data("{\"action\":\"pair\",\"browserID\":\"chrome\"}".utf8))), 204)
    XCTAssertEqual(try send("edge", "edge-worker", 1, "The bank is beside the river."), 204)
    XCTAssertEqual(try send("chrome", "chrome-worker", 1, "The bank is closed."), 204)
    XCTAssertEqual(try send("edge", "edge-worker", 2, "The bank is beside the river."), 204)
  }
  func testUnseenEdgeInvalidationCannotEraseChromeContext() throws {
    let suite = "BrowserBridgeInvalidation.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let bridge = BrowserContextBridge(defaults: defaults)
    func send(_ payload: [String: Any]) throws -> Int {
      bridge.handle(BrowserBridgeRequest(method: "POST", headers: ["origin": origin,
        "x-vocab-token": bridge.pairingToken], body: try JSONSerialization.data(withJSONObject: ["browserID": "chrome"].merging(payload) { _, value in value })))
    }
    XCTAssertEqual(try send(["action": "pair"]), 204)
    XCTAssertEqual(try send(["action": "context", "browserID": "chrome", "session": "chrome-worker", "revision": 1,
      "active": true, "tabID": 1, "windowID": 2, "url": "https://example.test/",
      "word": "bank", "context": "The bank is closed."]), 204)
    XCTAssertEqual(try send(["action": "invalidate", "browserID": "edge", "session": "edge-worker", "revision": 1]), 204)
    XCTAssertEqual(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"), "The bank is closed.")
  }
  func testBrowserScopedSentencesStaleWorkersTTLAndTokenRotation() throws {
    let suite = "BrowserBridgeIsolation.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var date = Date(timeIntervalSince1970: 100)
    let bridge = BrowserContextBridge(defaults: defaults, now: { date })
    var token = bridge.pairingToken
    func send(_ browser: String, _ session: String, _ revision: Int, _ sentence: String) throws -> Int {
      let payload: [String: Any] = ["action": "context", "browserID": browser, "session": session,
        "revision": revision, "active": true, "tabID": 1, "windowID": 2,
        "url": "https://example.test/", "word": "bank", "context": sentence]
      return bridge.handle(BrowserBridgeRequest(method: "POST", headers: ["origin": origin,
        "x-vocab-token": token], body: try JSONSerialization.data(withJSONObject: payload)))
    }
    let pair = BrowserBridgeRequest(method: "POST", headers: ["origin": origin, "x-vocab-token": token],
      body: Data("{\"action\":\"pair\",\"browserID\":\"chrome\"}".utf8))
    XCTAssertEqual(bridge.handle(pair), 204)
    XCTAssertEqual(try send("chrome", "chrome-worker", 4, "The bank is closed."), 204)
    XCTAssertEqual(try send("edge", "edge-worker", 1, "The bank is beside the river."), 204)
    XCTAssertEqual(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"), "The bank is closed.")
    XCTAssertEqual(bridge.sentence(for: "bank", browserBundleIdentifier: "com.microsoft.edgemac"), "The bank is beside the river.")
    for identifier in [nil, "com.brave.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "unknown"] {
      XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: identifier))
    }
    XCTAssertEqual(try send("chrome", "chrome-worker", 3, "The bank has stale context."), 409)
    XCTAssertEqual(try send("edge", "edge-restarted", 0, "The bank has new Edge context."), 204)
    XCTAssertEqual(try send("edge", "edge-worker", 2, "The bank has stale context."), 409)
    XCTAssertEqual(try send("chrome", "chrome-worker", 5, "The bank still has Chrome context."), 204)
    date = date.addingTimeInterval(1)
    XCTAssertEqual(try send("edge", "edge-restarted", 1, "The bank has refreshed Edge context."), 204)
    date = date.addingTimeInterval(1.5)
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"))
    XCTAssertEqual(bridge.sentence(for: "bank", browserBundleIdentifier: "com.microsoft.edgemac"), "The bank has refreshed Edge context.")
    date = date.addingTimeInterval(1)
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.microsoft.edgemac"))
    XCTAssertEqual(try send("edge", "edge-restarted", 2, "The bank has Edge context."), 204)
    XCTAssertEqual(try send("chrome", "chrome-worker", 6, "The bank has Chrome context."), 204)
    bridge.rotatePairingToken()
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.google.Chrome"))
    XCTAssertNil(bridge.sentence(for: "bank", browserBundleIdentifier: "com.microsoft.edgemac"))
    XCTAssertEqual(bridge.handle(pair), 401)
    token = bridge.pairingToken
    let newPair = BrowserBridgeRequest(method: "POST", headers: ["origin": origin, "x-vocab-token": token], body: pair.body)
    XCTAssertEqual(bridge.handle(newPair), 204)
    XCTAssertEqual(try send("edge", "edge-worker", 0, "The bank has reset Edge context."), 204,
      "Rotation clears retired workers and revisions for every browser")
    XCTAssertEqual(try send("chrome", "chrome-worker", 0, "The bank has reset Chrome context."), 204)
  }
  func testMissingUnsupportedBrowserIDsAndEmptySessionsFailSafely() throws {
    let suite = "BrowserBridgeIdentity.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let bridge = BrowserContextBridge(defaults: defaults)
    func send(_ payload: [String: Any]) throws -> Int {
      bridge.handle(BrowserBridgeRequest(method: "POST", headers: ["origin": origin,
        "x-vocab-token": bridge.pairingToken], body: try JSONSerialization.data(withJSONObject: payload)))
    }
    for action in ["pair", "context", "capture", "invalidate"] {
      XCTAssertEqual(try send(["action": action]), 422)
      XCTAssertEqual(try send(["action": action, "browserID": "unknown"]), 422)
    }
    XCTAssertEqual(try send(["action": "pair", "browserID": "chrome"]), 204)
    XCTAssertEqual(try send(["action": "invalidate", "browserID": "chrome", "session": "", "revision": 1]), 409)
  }
  func testSlowConnectionsAreCappedAndClosedByOverallDeadline() async throws {
    let suite = "BrowserBridgeSlowTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let port = UInt16.random(in: 49000...59000)
    let bridge = BrowserContextBridge(defaults: defaults, port: port, connectionDeadline: 0.4)
    bridge.start()
    defer { bridge.stop() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let clients = (0..<9).map { _ in NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    defer { clients.forEach { $0.cancel() } }
    let queue = DispatchQueue(label: "bridge-test-clients")
    clients.forEach { $0.start(queue: queue) }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(bridge.activeConnectionCount, 8)
    // A partial request arriving later must not reset the total connection deadline.
    clients[0].send(content: Data("POST /browser-context HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
    try await Task.sleep(nanoseconds: 450_000_000)
    XCTAssertEqual(bridge.activeConnectionCount, 0)
  }

  func testDefaultDiagnosticsNeverIncludeRawSelectionAndModeExpires() {
    let entry = ContextDebugLog.formatted("selected", word: "PRIVATE_WORD", context: "PRIVATE_CONTEXT", includeRaw: false)
    XCTAssertFalse(entry.contains("PRIVATE_WORD")); XCTAssertFalse(entry.contains("PRIVATE_CONTEXT"))
    XCTAssertTrue(entry.contains("长度"))
    XCTAssertTrue(ContextDebugLog.formatted("selected", word: "PRIVATE_WORD", context: nil, includeRaw: true).contains("PRIVATE_WORD"))
    ContextDebugLog.enableRawDiagnostics(for: 0)
    XCTAssertFalse(ContextDebugLog.isRawDiagnosticsEnabled)
    ContextDebugLog.disableRawDiagnostics()
  }
  func testSwiftUsesSharedPublicSentenceFixtures() throws {
    struct Fixture: Decodable { let text: String; let word: String; let sentence: String; let last: Bool? }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("browser-extension/tests/text-fixtures.json")))
    for fixture in fixtures {
      let range = (fixture.text as NSString).range(of: fixture.word, options: fixture.last == true ? .backwards : [])
      XCTAssertEqual(SelectionTextContract.sentence(fixture.text, selectedRange: range), fixture.sentence)
    }
  }
}
