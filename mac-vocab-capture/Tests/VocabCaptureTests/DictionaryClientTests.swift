import Foundation
import XCTest

@testable import VocabCapture

@MainActor
final class DictionaryClientTests: XCTestCase {
  private let configuration = AIConfiguration(
    baseURL: "https://dictionary.test/v1", model: "test", apiKey: "")
  private let selection = SelectedText(word: "curious", context: "A curious reader.")
  private let dictionary =
    #"{"meaning":"好奇的","lemma":"curious","partOfSpeech":"adj.","pronunciation":"","note":""}"#

  override func tearDown() {
    DictionaryURLProtocol.handler = nil
    super.tearDown()
  }

  private func client(cacheLimit: Int = 100) -> DictionaryClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DictionaryURLProtocol.self]
    return DictionaryClient(session: URLSession(configuration: config), cacheLimit: cacheLimit)
  }

  private func event(_ fragment: String) -> Data {
    let body = ["choices": [["delta": ["content": fragment]]]]
    let data = try! JSONSerialization.data(withJSONObject: body)
    return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
  }

  private func envelope(_ content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
  }

  func testStreamingPublishesDecodedMeaningOnceBeforeRemainder() async throws {
    let preview = expectation(description: "meaning before remaining fields")
    let expectedMeaning = "引号\"与反斜线\\及😀"
    let partial = #"{"meaning":"引号\"与反斜线\\及\uD83D\uDE00""#
    let suffix = #", "lemma":"curious","partOfSpeech":"adj.","pronunciation":"","note":""}"#
    var values: [String] = []
    var activeTransport: DictionaryURLProtocol?
    let fragments = [String(partial.prefix(15)), String(partial.dropFirst(15)), suffix]
    DictionaryURLProtocol.handler = { request, transport in
      let body =
        try! JSONSerialization.jsonObject(
          with: request.httpBody ?? request.httpBodyStream!.readAll()) as! [String: Any]
      XCTAssertEqual(body["stream"] as? Bool, true)
      activeTransport = transport
      // Keep the remainder behind the preview callback, rather than a wall-clock delay.
      // Padding flushes URLSession's small-chunk buffering without completing the response.
      let padding = Data((": " + String(repeating: "x", count: 16_384) + "\n\n").utf8)
      transport.respond(
        mime: "text/event-stream",
        chunks: [self.event(fragments[0]), self.event(fragments[1]) + padding],
        finish: false)
    }
    let resultTask = Task {
      try await client().lookup(
        selection, configuration: configuration,
        onMeaning: {
          values.append($0)
          XCTAssertEqual(
            activeTransport?.deliveredChunkCount, 2,
            "Preview must arrive before lemma or final frame")
          preview.fulfill()
          activeTransport?.finish(chunks: [self.event(suffix), Data("data: [DONE]\n\n".utf8)])
        })
    }
    await fulfillment(of: [preview], timeout: 2)
    let result = try await resultTask.value
    XCTAssertEqual(result.meaning, expectedMeaning)
    XCTAssertEqual(values, [expectedMeaning])
  }

  func testSSEHandlesCRLFMultilineDataUnicodeByteSplitsAndEOF() async throws {
    let json = try JSONSerialization.data(
      withJSONObject: ["choices": [["delta": ["content": dictionary]]]], options: .prettyPrinted)
    let frame =
      ":keep-alive\r\n"
      + String(decoding: json, as: UTF8.self).components(separatedBy: "\n")
      .map { "data: " + $0 }.joined(separator: "\r\n")
    let raw = Array(frame.utf8)
    let chunks = stride(from: 0, to: raw.count, by: 3).map {
      Data(raw[$0..<min($0 + 3, raw.count)])
    }
    DictionaryURLProtocol.handler = { _, transport in
      transport.respond(mime: "text/event-stream", chunks: chunks)
    }
    let result = try await client().lookup(selection, configuration: configuration)
    XCTAssertEqual(result.meaning, "好奇的")
  }

  func testTruncatedFinishReasonRejectsEvenOtherwiseCompleteJSON() async throws {
    let truncated = try JSONSerialization.data(withJSONObject: [
      "choices": [["finish_reason": "length", "delta": [String: String]()]]
    ])
    DictionaryURLProtocol.handler = { _, transport in
      transport.respond(
        mime: "text/event-stream",
        chunks: [self.event(self.dictionary), Data("data: ".utf8) + truncated + Data("\n\n".utf8)])
    }
    do {
      _ = try await client().lookup(selection, configuration: configuration)
      XCTFail("Token-limited response must not become a completed result")
    } catch {}
  }

  func testMeaningScannerWaitsForCompleteEscapesAndIgnoresNestedOrQuotedKeys() {
    XCTAssertNil(DictionaryClient.completedMeaning(in: #"{"meaning":"unfinished\""#))
    XCTAssertNil(DictionaryClient.completedMeaning(in: #"{"meaning":"\uD83D""#))
    XCTAssertNil(
      DictionaryClient.completedMeaning(in: #"{"note":"meaning", "nested":{"meaning":"wrong"}}"#))
    XCTAssertEqual(
      DictionaryClient.completedMeaning(in: #"{"note":"meaning", "meaning":"right""#), "right")
  }

  func testNonstreamFallbackCachesCompletedResultsWithContextAndServiceIdentity() async throws {
    var requests = 0
    DictionaryURLProtocol.handler = { _, transport in
      requests += 1
      transport.respond(mime: "application/json", chunks: [self.envelope(self.dictionary)])
    }
    let client = client()
    let first = try await client.lookup(selection, configuration: configuration)
    let second = try await client.lookup(selection, configuration: configuration)
    XCTAssertEqual(first.meaning, second.meaning)
    XCTAssertEqual(requests, 1)
    _ = try await client.lookup(
      SelectedText(word: "curious", context: "Another curious reader."),
      configuration: configuration)
    var changed = configuration
    changed.model = "another"
    _ = try await client.lookup(selection, configuration: changed)
    changed = configuration
    changed.apiKey = "another credential"
    _ = try await client.lookup(selection, configuration: changed)
    changed = configuration
    changed.baseURL = "https://another.test/v1"
    _ = try await client.lookup(selection, configuration: changed)
    XCTAssertEqual(requests, 5)
  }

  func testCacheEvictsOldestCompletedResult() async throws {
    var requests = 0
    DictionaryURLProtocol.handler = { _, transport in
      requests += 1
      transport.respond(mime: "application/json", chunks: [self.envelope(self.dictionary)])
    }
    let client = client(cacheLimit: 1)
    _ = try await client.lookup(selection, configuration: configuration)
    _ = try await client.lookup(
      SelectedText(word: "reader", context: selection.context), configuration: configuration)
    _ = try await client.lookup(selection, configuration: configuration)
    XCTAssertEqual(requests, 3)
  }

  func testInvalidFinalResponseAndStreamErrorNeverEnterCache() async throws {
    let client = client()
    var requests = 0
    DictionaryURLProtocol.handler = { _, transport in
      requests += 1
      transport.respond(
        mime: "text/event-stream",
        chunks: [self.event(#"{"meaning":"early""#), Data("data: [DONE]\n\n".utf8)])
    }
    for _ in 0..<2 {
      do {
        _ = try await client.lookup(selection, configuration: configuration)
        XCTFail("Must reject incomplete dictionary")
      } catch {}
    }
    XCTAssertEqual(requests, 2)
    DictionaryURLProtocol.handler = { _, transport in
      transport.respond(
        mime: "text/event-stream",
        chunks: [Data(#"data: {"error":{"message":"failed"}}"#.utf8) + Data("\n\n".utf8)])
    }
    do {
      _ = try await client.lookup(selection, configuration: configuration)
      XCTFail("Must reject stream error")
    } catch {}
  }

  func testCancellationStopsNetworkAndDoesNotCache() async throws {
    let began = expectation(description: "network began")
    let stopped = expectation(description: "network stopped")
    var requests = 0
    DictionaryURLProtocol.handler = { _, transport in
      requests += 1
      if requests == 1 {
        transport.onStop = { stopped.fulfill() }
        transport.respond(mime: "text/event-stream", chunks: [self.event("{")], interval: 5)
        began.fulfill()
      } else {
        transport.respond(mime: "application/json", chunks: [self.envelope(self.dictionary)])
      }
    }
    let client = client()
    let task = Task { try await client.lookup(selection, configuration: configuration) }
    await fulfillment(of: [began], timeout: 2)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled lookup must fail")
    } catch {}
    await fulfillment(of: [stopped], timeout: 2)
    _ = try await client.lookup(selection, configuration: configuration)
    XCTAssertEqual(requests, 2)
  }

  func testHTTPFailureDoesNotPublishMeaning() async throws {
    DictionaryURLProtocol.handler = { _, transport in
      transport.respond(
        mime: "application/json", chunks: [self.envelope(self.dictionary)], status: 503)
    }
    do {
      _ = try await client().lookup(
        selection, configuration: configuration,
        onMeaning: { _ in XCTFail("Error must not publish preview") })
      XCTFail("HTTP failure must fail")
    } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
  }
}

private final class DictionaryURLProtocol: URLProtocol {
  static var handler: ((URLRequest, DictionaryURLProtocol) -> Void)?
  var onStop: (() -> Void)?
  var deliveredChunkCount = 0
  private var work: [DispatchWorkItem] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.handler?(request, self) }
  override func stopLoading() {
    for item in work { item.cancel() }
    onStop?()
    onStop = nil
  }

  func respond(
    mime: String, chunks: [Data], interval: Double = 0, status: Int = 200,
    finish: Bool = true
  ) {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!,
      cacheStoragePolicy: .notAllowed)
    for (index, chunk) in chunks.enumerated() {
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.deliveredChunkCount += 1
        self.client?.urlProtocol(self, didLoad: chunk)
        if finish, index == chunks.count - 1 { self.client?.urlProtocolDidFinishLoading(self) }
      }
      work.append(item)
      DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index + 1), execute: item)
    }
  }

  func finish(chunks: [Data]) {
    for chunk in chunks {
      deliveredChunkCount += 1
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}

extension InputStream {
  fileprivate func readAll() -> Data {
    open()
    defer { close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }
}
