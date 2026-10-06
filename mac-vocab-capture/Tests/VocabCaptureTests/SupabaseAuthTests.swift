import Foundation
import XCTest

@testable import VocabCapture

@MainActor
final class SupabaseAuthTests: XCTestCase {
  override func tearDown() {
    AuthURLProtocol.handler = nil
    super.tearDown()
  }

  private func storedSession(expired: Bool = true, token: String = "original") -> SupabaseSession {
    SupabaseSession(
      accessToken: "access-\(token)", refreshToken: "refresh-\(token)",
      user: SupabaseUser(id: "fixture-user"),
      expiresAt: Int(Date().timeIntervalSince1970) + (expired ? -120 : 3600))
  }

  private func client(_ store: AuthSessionStore) -> SupabaseVocabularySync {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AuthURLProtocol.self]
    return SupabaseVocabularySync(
      session: URLSession(configuration: configuration), readSession: { store.read() },
      saveSession: { store.save($0) })
  }

  private func serveReader(_ request: URLRequest, _ transport: AuthURLProtocol, token: String) {
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-\(token)")
    XCTAssertEqual(request.url?.path, "/rest/v1/rpc/sync_reader_vocabulary_v2")
    transport.respond(Data(#"{"userID":"fixture-user","vocabulary":[],"uploadedCount":0,"revision":0,"acknowledgedOperationIDs":[],"tombstones":[],"conflict":false,"conflictingWordKeys":[]}"#.utf8))
  }

  private func assertExpired(_ operation: () async throws -> Void) async {
    do {
      try await operation()
      XCTFail("Invalid refresh must require a new login")
    } catch SupabaseSyncError.sessionExpired {
    } catch { XCTFail("Expected sessionExpired, received \(error)") }
  }

  func testTerminalRefreshCodesAndLegacyMessageClearOnlySavedSession() async throws {
    let failures = [
      #"{"code":"refresh_token_not_found","msg":"token missing"}"#,
      #"{"error_code":"refresh_token_already_used","msg":"token reused"}"#,
      #"{"code":"session_not_found","msg":"session missing"}"#,
      #"{"msg":"Invalid Refresh Token: Refresh Token Not Found"}"#,
    ]
    for failure in failures {
      let store = AuthSessionStore(storedSession())
      let client = client(store)
      var requests = 0
      AuthURLProtocol.handler = { request, transport in
        requests += 1
        XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
        transport.respond(Data(failure.utf8), status: 400)
      }
      await assertExpired { _ = try await client.sync(local: []) }
      XCTAssertNil(store.read())
      let loggedIn = await client.isLoggedIn()
      XCTAssertFalse(loggedIn)
      do {
        _ = try await client.sync(local: [])
        XCTFail("The stale token must not be retried")
      } catch SupabaseSyncError.notLoggedIn {
      }
      XCTAssertEqual(requests, 1)
    }
  }

  func testExpiredSessionCanSignInAgainAndSynchronize() async throws {
    let store = AuthSessionStore(storedSession())
    let client = client(store)
    let fresh = storedSession(expired: false, token: "new-login")
    var readerRequests = 0
    AuthURLProtocol.handler = { request, transport in
      switch request.url?.query {
      case "grant_type=refresh_token":
        transport.respond(Data(#"{"code":"refresh_token_not_found"}"#.utf8), status: 401)
      case "grant_type=password":
        transport.respond(try! JSONEncoder().encode(fresh))
      default:
        readerRequests += 1
        self.serveReader(request, transport, token: "new-login")
      }
    }
    await assertExpired { _ = try await client.sync(local: []) }
    _ = try await client.signIn(email: "reader@example.test", password: "test-only")
    let result = try await client.sync(local: [])
    XCTAssertEqual(store.read()?.refreshToken, fresh.refreshToken)
    XCTAssertEqual(readerRequests, 1)
    XCTAssertTrue(result.vocabulary.isEmpty)
  }

  func testTransientAndUnrelatedRefreshErrorsKeepSession() async throws {
    let cases: [(Int, String)] = [
      (500, #"{"code":"refresh_token_not_found","msg":"server unavailable"}"#),
      (429, #"{"msg":"rate limited"}"#),
      (400, #"{"code":"request_timeout","msg":"request timeout"}"#),
      (401, #"{"code":"unexpected_failure","msg":"unexpected auth failure"}"#),
    ]
    for (status, body) in cases {
      let stored = storedSession()
      let store = AuthSessionStore(stored)
      let client = client(store)
      AuthURLProtocol.handler = { _, transport in
        transport.respond(Data(body.utf8), status: status)
      }
      do {
        _ = try await client.sync(local: [])
        XCTFail("Server failure must be reported")
      } catch SupabaseSyncError.http(let received) {
        XCTAssertEqual(received, status)
      }
      XCTAssertEqual(store.read()?.refreshToken, stored.refreshToken)
      let loggedIn = await client.isLoggedIn()
      XCTAssertTrue(loggedIn)
    }
  }

  func testNetworkFailureKeepsSessionAndRefreshCanRetry() async throws {
    let stored = storedSession()
    let store = AuthSessionStore(stored)
    let client = client(store)
    let fresh = storedSession(expired: false, token: "rotated")
    var refreshRequests = 0
    AuthURLProtocol.handler = { request, transport in
      if request.url?.query == "grant_type=refresh_token" {
        refreshRequests += 1
        if refreshRequests == 1 {
          transport.fail(URLError(.notConnectedToInternet))
        } else {
          transport.respond(try! JSONEncoder().encode(fresh))
        }
      } else {
        self.serveReader(request, transport, token: "rotated")
      }
    }
    do {
      _ = try await client.sync(local: [])
      XCTFail("Network failure must be reported")
    } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
    XCTAssertEqual(store.read()?.refreshToken, stored.refreshToken)
    _ = try await client.sync(local: [])
    XCTAssertEqual(refreshRequests, 2)
    XCTAssertEqual(store.read()?.refreshToken, fresh.refreshToken)
  }

  func testConcurrentSynchronizationsShareOneRefreshRequest() async throws {
    let store = AuthSessionStore(storedSession())
    let client = client(store)
    let fresh = storedSession(expired: false, token: "rotated")
    var refreshRequests = 0
    var readerRequests = 0
    AuthURLProtocol.handler = { request, transport in
      if request.url?.query == "grant_type=refresh_token" {
        refreshRequests += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          transport.respond(try! JSONEncoder().encode(fresh))
        }
      } else {
        readerRequests += 1
        self.serveReader(request, transport, token: "rotated")
      }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { _ = try await client.sync(local: []) }
      }
      try await group.waitForAll()
    }
    XCTAssertEqual(refreshRequests, 1)
    XCTAssertEqual(readerRequests, 8)
    XCTAssertEqual(store.read()?.refreshToken, fresh.refreshToken)
  }

  func testStaleRefreshSuccessOrFailureCannotOverwriteOrClearNewLogin() async throws {
    for invalidResponse in [false, true] {
      let store = AuthSessionStore(storedSession())
      let client = client(store)
      let fresh = storedSession(expired: false, token: "new-login")
      let refreshedOldSession = storedSession(expired: false, token: "stale-refresh")
      let began = expectation(description: "old refresh began")
      var waitingRefresh: AuthURLProtocol?
      AuthURLProtocol.handler = { request, transport in
        switch request.url?.query {
        case "grant_type=refresh_token":
          waitingRefresh = transport
          began.fulfill()
        case "grant_type=password":
          transport.respond(try! JSONEncoder().encode(fresh))
        default:
          self.serveReader(request, transport, token: "new-login")
        }
      }
      let pending = Task { try await client.sync(local: []) }
      await fulfillment(of: [began], timeout: 2)
      _ = try await client.signIn(email: "reader@example.test", password: "test-only")
      let waiting = try XCTUnwrap(waitingRefresh)
      if invalidResponse {
        waiting.respond(Data(#"{"code":"refresh_token_not_found"}"#.utf8), status: 400)
      } else {
        waiting.respond(try JSONEncoder().encode(refreshedOldSession))
      }
      _ = try await pending.value
      XCTAssertEqual(store.read()?.refreshToken, fresh.refreshToken)
    }
  }

  func testSignOutDuringRefreshDoesNotRestoreSession() async throws {
    let store = AuthSessionStore(storedSession())
    let client = client(store)
    let fresh = storedSession(expired: false, token: "rotated")
    let began = expectation(description: "refresh began")
    var waitingRefresh: AuthURLProtocol?
    AuthURLProtocol.handler = { request, transport in
      XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
      waitingRefresh = transport
      began.fulfill()
    }
    let pending = Task { try await client.sync(local: []) }
    await fulfillment(of: [began], timeout: 2)
    try await client.signOut()
    try XCTUnwrap(waitingRefresh).respond(JSONEncoder().encode(fresh))
    do {
      _ = try await pending.value
      XCTFail("Signing out must remain signed out")
    } catch SupabaseSyncError.notLoggedIn {
    }
    XCTAssertNil(store.read())
  }

  func testFreshSessionREST401RefreshesOnceAndTerminalRefreshRequiresLogin() async throws {
    let stored = storedSession(expired: false)
    let store = AuthSessionStore(stored)
    let client = client(store)
    var requests = 0
    AuthURLProtocol.handler = { request, transport in
      requests += 1
      if requests == 1 {
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/sync_reader_vocabulary_v2")
      } else {
        XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
      }
      transport.respond(Data(#"{"code":"session_not_found","msg":"denied"}"#.utf8), status: 401)
    }
    await assertExpired { _ = try await client.sync(local: []) }
    XCTAssertEqual(requests, 2)
    XCTAssertNil(store.read())
  }

  func testFreshSessionREST401RetriesRPCOnceAfterRefresh() async throws {
    let store = AuthSessionStore(storedSession(expired: false))
    let client = client(store)
    let fresh = storedSession(expired: false, token: "rotated")
    var requests = 0
    AuthURLProtocol.handler = { request, transport in
      requests += 1
      if requests == 1 { transport.respond(Data("{}".utf8), status: 401) }
      else if request.url?.query == "grant_type=refresh_token" { transport.respond(try! JSONEncoder().encode(fresh)) }
      else { self.serveReader(request, transport, token: "rotated") }
    }
    _ = try await client.sync(local: [])
    XCTAssertEqual(requests, 3)
    XCTAssertEqual(store.read()?.accessToken, fresh.accessToken)
  }

  func testRPC429And500KeepFreshSessionWithoutRefresh() async throws {
    for status in [429, 500] {
      let stored = storedSession(expired: false)
      let store = AuthSessionStore(stored)
      let client = client(store)
      var requests = 0
      AuthURLProtocol.handler = { _, transport in requests += 1; transport.respond(Data("{}".utf8),status: status) }
      do { _ = try await client.sync(local: []); XCTFail("Expected RPC failure") }
      catch SupabaseSyncError.http { }
      XCTAssertEqual(requests, 1)
      XCTAssertEqual(store.read()?.accessToken, stored.accessToken)
    }
  }

  func testMissingSessionDoesNotMakeNetworkRequests() async throws {
    let client = client(AuthSessionStore(nil))
    AuthURLProtocol.handler = { _, _ in XCTFail("No credentials must avoid a network request") }
    do {
      _ = try await client.sync(local: [])
      XCTFail("Missing credentials must require login")
    } catch SupabaseSyncError.notLoggedIn {
    }
  }

  func testSignOutDuringRPCDiscardsOldWriteAcknowledgement() async throws {
    let store = AuthSessionStore(storedSession(expired: false))
    let client = client(store)
    let began = expectation(description: "RPC began")
    var waitingRPC: AuthURLProtocol?
    AuthURLProtocol.handler = { _, transport in waitingRPC = transport; began.fulfill() }
    let pending = Task { try await client.sync(batch:VocabularySyncBatch(userID:"fixture-user",baseRevision:0,operations:[])) }
    await fulfillment(of:[began],timeout:2)
    try await client.signOut()
    try XCTUnwrap(waitingRPC).respond(Data(#"{"userID":"fixture-user","vocabulary":[],"uploadedCount":0,"revision":0,"acknowledgedOperationIDs":[],"tombstones":[],"conflict":false,"conflictingWordKeys":[]}"#.utf8))
    do { _ = try await pending.value; XCTFail("Stale account acknowledgement cannot commit locally") }
    catch SupabaseSyncError.accountChanged { }
    XCTAssertNil(store.read())
  }

  func testExpiresInFallbackPersistsAbsoluteExpiry() throws {
    let before = Int(Date().timeIntervalSince1970)
    let data = Data(
      #"{"access_token":"test","refresh_token":"test","user":{"id":"test"},"expires_in":3600}"#
        .utf8)
    let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
    let expiry = try XCTUnwrap(session.expiresAt)
    XCTAssertGreaterThanOrEqual(expiry, before + 3600)
    XCTAssertLessThanOrEqual(expiry, Int(Date().timeIntervalSince1970) + 3600)
    let persisted = try JSONDecoder().decode(
      SupabaseSession.self, from: JSONEncoder().encode(session))
    XCTAssertEqual(persisted.expiresAt, expiry)
  }
}

private final class AuthSessionStore: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: SupabaseSession?

  init(_ stored: SupabaseSession?) { self.stored = stored }

  func read() -> SupabaseSession? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func save(_ session: SupabaseSession?) {
    lock.lock()
    defer { lock.unlock() }
    stored = session
  }
}

private final class AuthURLProtocol: URLProtocol {
  static var handler: ((URLRequest, AuthURLProtocol) -> Void)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    DispatchQueue.main.async { Self.handler?(self.request, self) }
  }
  override func stopLoading() {}

  func respond(_ data: Data, status: Int = 200) {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}
