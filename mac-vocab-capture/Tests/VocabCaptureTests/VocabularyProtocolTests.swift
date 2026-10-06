import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class VocabularyProtocolTests: XCTestCase {
  override func tearDown() { ProtocolURL.handler = nil; super.tearDown() }

  func testEmptyCloudWriteResponseCannotAcknowledgeSynchronization() async throws {
    let stored = SupabaseSession(accessToken: "fixture", refreshToken: "fixture", user: SupabaseUser(id: "fixture-user"), expiresAt: nil)
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
    let stored = SupabaseSession(accessToken: "fixture", refreshToken: "fixture", user: SupabaseUser(id: "fixture-user"), expiresAt: nil)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProtocolURL.self]
    return SupabaseVocabularySync(session: URLSession(configuration: configuration), readSession: { stored }, saveSession: { _ in })
  }

  private func snapshot(revision: Int = 0, ack: [String] = [], conflict: Bool = false, keys: [String] = [], user: String = "fixture-user") -> String {
    let payload: [String: Any] = ["userID":user,"vocabulary":[],"uploadedCount":0,"revision":revision,
      "acknowledgedOperationIDs":ack,"tombstones":[],"conflict":conflict,"conflictingWordKeys":keys]
    return String(data:try! JSONSerialization.data(withJSONObject: payload),encoding:.utf8)!
  }

  private func batch(baseRevision: Int64 = 0) -> VocabularySyncBatch {
    let entry = VocabularyEntry(word: "alpha",dictionary:DictionaryResult(lemma:"alpha",meaning:"甲",partOfSpeech:"n.",pronunciation:"",note:""),context:"Alpha.")
    return VocabularySyncBatch(userID:"fixture-user",baseRevision:baseRevision,operations:[VocabularyMutation(operationID:"fixture-op",kind:.upsert,wordKey:"alpha",entry:entry,baseVersion:nil)])
  }

  func testOnlyRPCMayCommitAndEveryOperationRequiresAcknowledgement() async throws {
    let client = fixtureClient()
    var requests = 0
    ProtocolURL.handler = { request, transport in
      requests += 1
      XCTAssertEqual(request.httpMethod,"POST")
      XCTAssertEqual(request.url?.path,"/rest/v1/rpc/sync_reader_vocabulary_v2")
      transport.respond(self.snapshot(revision:1,ack:["fixture-op"]))
    }
    let result = try await client.sync(batch:batch())
    XCTAssertEqual(result.acknowledgedOperationIDs,["fixture-op"])
    XCTAssertEqual(requests,1)
  }

  func testMissingAcknowledgementAndWrongAccountResponsesFail() async throws {
    for response in [snapshot(revision:1),snapshot(revision:1,ack:["fixture-op"],user:"another-user"),snapshot(revision:1,ack:["fixture-op","fixture-op"])] {
      ProtocolURL.handler = { _, transport in transport.respond(response) }
      do { _ = try await fixtureClient().sync(batch:batch()); XCTFail("Must reject unconfirmed operations") }
      catch SupabaseSyncError.invalidResponse { }
    }
  }

  func testGlobalConflictRetryDoesNotChangeEntryBaseVersion() async throws {
    let client = fixtureClient()
    var requests = 0
    ProtocolURL.handler = { request, transport in
      requests += 1
      let stream = request.httpBodyStream
      var bytes = Data()
      stream?.open()
      if let stream {
        var buffer = [UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; bytes.append(buffer,count:count) }
        stream.close()
      } else { bytes = request.httpBody ?? Data() }
      let body = try! JSONSerialization.jsonObject(with:bytes) as! [String:Any]
      XCTAssertEqual(body["p_expected_revision"] as? Int, requests == 1 ? 0 : 4)
      let operation = (body["p_operations"] as! [[String:Any]])[0]
      XCTAssertNil(operation["baseVersion"])
      transport.respond(requests == 1 ? self.snapshot(revision:4,conflict:true) : self.snapshot(revision:5,ack:["fixture-op"]))
    }
    let result = try await client.sync(batch:batch())
    XCTAssertEqual(result.revision,5)
    XCTAssertEqual(requests,2)
  }

  func testEntryConflictDoesNotRetryOrAcknowledgePending() async throws {
    var requests = 0
    ProtocolURL.handler = { _, transport in requests += 1; transport.respond(self.snapshot(revision:2,conflict:true,keys:["alpha"])) }
    do { _ = try await fixtureClient().sync(batch:batch()); XCTFail("Entry conflict must remain pending") }
    catch SupabaseSyncError.conflict(let words) { XCTAssertEqual(words,["alpha"]) }
    XCTAssertEqual(requests,1)
  }

  func testGlobalConflictHasBoundedRetries() async throws {
    var requests = 0
    ProtocolURL.handler = { _, transport in requests += 1; transport.respond(self.snapshot(revision:requests,conflict:true)) }
    do { _ = try await fixtureClient().sync(batch:batch()); XCTFail("Concurrent writers must not retry forever") }
    catch SupabaseSyncError.conflict { }
    XCTAssertEqual(requests,3)
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
