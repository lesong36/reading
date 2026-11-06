import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class MathMethodBudgetTransportTests: XCTestCase {
  func testSelectionBudgetFrameProducesUsefulSanitizedErrorAndRuntimeRemainsUsable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("method-budget-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("helper.py")
    try """
      import json, sys
      print(json.dumps({"type":"ready","protocol":1,"langchain_version":"1.4.3"}), flush=True)
      for line in sys.stdin:
          request = json.loads(line)
          if request.get("op") != "answer":
              continue
          if request.get("question") == "budget":
              event = {"id":request["id"],"type":"error","code":"skillsBudget","message":"fake-key-never-print"}
          else:
              event = {"id":request["id"],"type":"done","text":"next response"}
          print(json.dumps(event), flush=True)
      """.write(to: script, atomically: true, encoding: .utf8)
    let transport = LangChainQuestionTransport(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path],
      environment: ["PATH": "/usr/bin:/bin"], startupTimeout: 2, requestTimeout: 2)
    do {
      let payload = try JSONSerialization.data(withJSONObject: ["question": "budget"])
      do {
        _ = try await transport.answer(payload: payload, onPartial: { _ in })
        XCTFail("Expected a typed method-selection budget error")
      } catch {
        guard case MathMethodMatchError.selectionBudgetExceeded = error else {
          XCTFail("Unexpected error: \(error)")
          await transport.shutdown()
          return
        }
        XCTAssertTrue(error.localizedDescription.contains("调用上限"))
        XCTAssertFalse(error.localizedDescription.contains("fake-key"))
      }
      let next = try JSONSerialization.data(withJSONObject: ["question": "continue"])
      let answer = try await transport.answer(payload: next, onPartial: { _ in })
      XCTAssertEqual(answer, "next response")
      await transport.shutdown()
    } catch {
      await transport.shutdown()
      throw error
    }
  }
}
