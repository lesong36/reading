import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class VocabularyProtocolTests: XCTestCase {
  private let fixtureUser = "protocol-test-" + UUID().uuidString
  private let fixtureEntry = VocabularyEntry(word: "alpha", dictionary: DictionaryResult(
    lemma: "alpha", meaning: "甲", partOfSpeech: "n.", pronunciation: "", note: ""), context: "Alpha.")

  override func tearDown() { ProtocolURL.handler = nil; super.tearDown() }

  func testEmptyCloudWriteResponseCannotAcknowledgeSynchronization() async throws {
    let stored = SupabaseSession(accessToken: "fixture", refreshToken: "fixture", user: SupabaseUser(id: fixtureUser), expiresAt: nil)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProtocolURL.self]
    let client = SupabaseVocabularySync(session: URLSession(configuration: configuration), readSession: { stored }, saveSession: { _ in })
    ProtocolURL.handler = { _, transport in transport.respond("[]") }
    do { _ = try await client.sync(local: []); XCTFail("An empty response is not a confirmed user row") }
    catch { }
  }

  func testDefinitionMetadataAndFutureFieldsSurviveNativeRoundTrip() throws {
    let original = Data(#"{"word":"bank","meaning":"河岸","cloudVersion":7,"updatedAt":"2026-10-06T10:00:00Z","definitionCheckedAt":"2026-10-06T10:00:00Z","definitionProvider":"fixture","futureMetadata":{"tags":["a"],"active":true}}"#.utf8)
    let entry = try JSONDecoder().decode(VocabularyEntry.self, from: original)
    let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    XCTAssertEqual(actual["cloudVersion"] as? Int, 7)
    XCTAssertEqual(actual["definitionProvider"] as? String, "fixture")
    XCTAssertNotNil(actual["futureMetadata"])
    XCTAssertEqual(actual["updatedAt"] as? String, "2026-10-06T10:00:00Z")
  }

  private func fixtureClient() -> SupabaseVocabularySync {
    let stored = SupabaseSession(accessToken: "fixture", refreshToken: "fixture", user: SupabaseUser(id: fixtureUser), expiresAt: nil)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProtocolURL.self]
    return SupabaseVocabularySync(session: URLSession(configuration: configuration), readSession: { stored }, saveSession: { _ in })
  }

  private func batch(baseRevision: Int64 = 0) -> VocabularySyncBatch {
    let entry = fixtureEntry
    return VocabularySyncBatch(userID:fixtureUser,baseRevision:baseRevision,operations:[VocabularyMutation(operationID:"fixture-op",kind:.upsert,wordKey:"alpha",entry:entry,baseVersion:nil)])
  }

  private func json(_ value: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
  }

  private func fixtureResponse(_ request: URLRequest, transport: ProtocolURL,
    acknowledgement: [[String: Any]] = [["operationID":"fixture-op","status":"applied","version":1]],
    afterPush: Bool = false) {
    switch request.url?.lastPathComponent {
    case "reader_delta_pull":
      transport.respond(json(["epoch":"fixture-epoch","nextCursor":0,"hasMore":false,"changes":[]]))
    case "reader_delta_get":
      let entry = batch().operations[0].entry!
      let payload: Any = afterPush ? try! JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) : NSNull()
      transport.respond(json(["entities":[["entityType":"vocabulary","entityID":"alpha","version":afterPush ? 1 : 0,"deleted":!afterPush,"payload":payload]]]))
    case "reader_delta_push":
      transport.respond(json(["epoch":"fixture-epoch","acknowledgements":acknowledgement]))
    default: XCTFail("Unexpected legacy endpoint"); transport.respond("{}")
    }
  }

  func testOnlyDeltaRPCMayCommitAndEveryOperationRequiresAcknowledgement() async throws {
    var pushed = false
    ProtocolURL.handler = { request, transport in
      XCTAssertEqual(request.httpMethod, "POST")
      if request.url?.lastPathComponent == "reader_delta_push" { pushed = true }
      self.fixtureResponse(request, transport: transport, afterPush: pushed)
    }
    let result = try await fixtureClient().sync(batch: batch())
    XCTAssertTrue(pushed)
    XCTAssertEqual(result.acknowledgedOperationIDs, ["fixture-op"])
    XCTAssertEqual(result.vocabulary.first?.cloudVersion, 1)
    XCTAssertEqual(result.deltaState?.epoch, "fixture-epoch")
  }

  func testMissingAndUnknownAcknowledgementsFail() async throws {
    for acks: [[String: Any]] in [[], [["operationID":"unknown", "status":"applied", "version":1]]] {
      ProtocolURL.handler = { request, transport in
        self.fixtureResponse(request, transport: transport, acknowledgement: acks)
      }
      do { _ = try await fixtureClient().sync(batch: batch()); XCTFail("Must reject unconfirmed operations") }
      catch SupabaseSyncError.invalidResponse { }
    }
  }

  func testEntryConflictDoesNotRetryOrAcknowledgePending() async throws {
    var pushes = 0
    ProtocolURL.handler = { request, transport in
      if request.url?.lastPathComponent == "reader_delta_push" { pushes += 1 }
      self.fixtureResponse(request, transport: transport,
        acknowledgement: [["operationID":"fixture-op","status":"conflict","version":2]])
    }
    let result = try await fixtureClient().sync(batch: batch())
    XCTAssertTrue(result.conflict)
    XCTAssertEqual(result.conflictingWordKeys, ["alpha"])
    XCTAssertTrue(result.acknowledgedOperationIDs.isEmpty)
    XCTAssertEqual(pushes, 1)
  }

  func testEquivalentLegacyEntryAcknowledgedWithoutWriting() async throws {
    ProtocolURL.handler = { request, transport in
      XCTAssertNotEqual(request.url?.lastPathComponent, "reader_delta_push")
      self.fixtureResponse(request, transport: transport, afterPush: true)
    }
    let result = try await fixtureClient().sync(batch: batch())
    XCTAssertFalse(result.conflict)
    XCTAssertEqual(result.acknowledgedOperationIDs, ["fixture-op"])
    XCTAssertEqual(result.uploadedCount, 0)
    XCTAssertTrue(result.deltaState?.legacyOperationIDs?.isEmpty == true)
  }

  func testPartialMigrationPreservesUnsentLegacyIdentity() async throws {
    var first = batch()
    first.legacyOperationIDs = ["fixture-op", "later-op"]
    var pushed = false
    ProtocolURL.handler = { request, transport in
      if request.url?.lastPathComponent == "reader_delta_push" { pushed = true }
      self.fixtureResponse(request, transport: transport, afterPush: pushed)
    }
    let result = try await fixtureClient().sync(batch: first)
    XCTAssertEqual(result.acknowledgedOperationIDs, ["fixture-op"])
    XCTAssertEqual(result.deltaState?.legacyOperationIDs, Set(["later-op"]))
    let encoded = try JSONEncoder().encode(XCTUnwrap(result.deltaState))
    let restored = try JSONDecoder().decode(VocabularyDeltaState.self, from: encoded)
    XCTAssertEqual(restored.legacyOperationIDs, Set(["later-op"]))
  }

  func testMissingRPCDoesNotFallBackToFullArrayWrite() async throws {
    var requests = 0
    ProtocolURL.handler = { _, transport in requests += 1; transport.respond("{\"code\":\"PGRST202\"}",status:404) }
    do { _ = try await fixtureClient().sync(batch:batch()); XCTFail("Missing migration must remain pending") }
    catch SupabaseSyncError.upgradeRequired { }
    XCTAssertEqual(requests,1)
  }

  func testLegacyArrayWriteIsExplicitlyBlocked() async throws {
    ProtocolURL.handler = { _, _ in XCTFail("Legacy write cannot reach the server") }
    do { _ = try await fixtureClient().sync(local:[batch().operations[0].entry!]); XCTFail("Full-array writes are unsafe") }
    catch SupabaseSyncError.upgradeRequired { }
  }

}

private final class ProtocolURL: URLProtocol {
  static var handler: ((URLRequest, ProtocolURL) -> Void)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { DispatchQueue.main.async { Self.handler?(self.request,self) } }
  override func stopLoading() {}
  func respond(_ value: String, status: Int = 200) {
    client?.urlProtocol(self,didReceive: HTTPURLResponse(url: request.url!,statusCode: status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:Data(value.utf8)); client?.urlProtocolDidFinishLoading(self)
  }
}
