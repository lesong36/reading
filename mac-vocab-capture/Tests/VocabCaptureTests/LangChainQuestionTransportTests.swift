import Foundation
import XCTest

@testable import VocabCapture

@MainActor
final class LangChainQuestionTransportTests: XCTestCase {
  private struct Fixture {
    let directory: URL
    let transport: LangChainQuestionTransport
    let pidFile: URL

    func close() async {
      await transport.shutdown()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func fixture(
    _ scenario: String = "normal", startupTimeout: TimeInterval = 2,
    requestTimeout: TimeInterval = 2
  ) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vocab-langchain-transport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fixture.py")
    let pidFile = directory.appendingPathComponent("pid")
    try Self.helper.write(to: script, atomically: true, encoding: .utf8)
    let transport = LangChainQuestionTransport(
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: ["-u", script.path, scenario, pidFile.path],
      environment: [
        "PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "fake-secret", "LANGSMITH_TRACING": "true",
        "PYTHONPATH": "/invalid-runtime", "FIXTURE_NON_SECRET": "preserved",
      ], startupTimeout: startupTimeout, requestTimeout: requestTimeout)
    return Fixture(directory: directory, transport: transport, pidFile: pidFile)
  }

  private func payload(_ question: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["question": question])
  }

  func testFragmentedUnicodeStreamingKeepsOrderAndFullCompletion() async throws {
    let fixture = try fixture()
    var partials: [String] = []
    let answer = try await fixture.transport.answer(payload: payload("unicode")) {
      partials.append($0)
    }
    XCTAssertEqual(partials, ["你", "你好🌍"])
    XCTAssertEqual(answer, "你好🌍")
    await fixture.close()
  }

  func testSearchProgressIsSeparateFromAnswerTextAndLateProgressIgnored() async throws {
    let fixture = try fixture()
    var stages: [ScreenshotQuestionSearchStage] = []
    var partials: [String] = []
    let answer = try await fixture.transport.answer(
      payload: payload("progress"), onProgress: { stages.append($0) },
      onPartial: { partials.append($0) })
    XCTAssertEqual(stages, [.query, .search, .answer])
    XCTAssertEqual(partials, ["verified answer"])
    XCTAssertEqual(answer, "verified answer")
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(stages, [.query, .search, .answer])
    await fixture.close()
  }

  func testSearchAuthenticationErrorHasDedicatedSanitizedMessage() async throws {
    let fixture = try fixture()
    do {
      _ = try await fixture.transport.answer(payload: payload("searchAuthentication")) { _ in }
      XCTFail("Search failure must not become an offline answer")
    } catch {
      guard case ScreenshotQuestionWebSearchError.authentication = error else {
        XCTFail("Unexpected error: \(error)")
        await fixture.close()
        return
      }
      XCTAssertFalse(error.localizedDescription.contains("untrusted-key"))
    }
    await fixture.close()
  }

  func testFailedMathReportsSanitizedClocksOnceWithoutFabricatingUsageOrAnswer() async throws {
    let fixture = try fixture()
    var observations: [ScreenshotQuestionUsage] = []
    var partials: [String] = []
    do {
      _ = try await fixture.transport.answer(payload: payload("failureClocks"),
        onUsage: { observations.append($0) }, onPartial: { partials.append($0) })
      XCTFail("Failure must not become an answer")
    } catch { XCTAssertEqual((error as? MathSolutionSubmissionError)?.issue, "submission_shape") }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(partials.isEmpty)
    XCTAssertEqual(observations.count, 1)
    let value = try XCTUnwrap(observations.first)
    XCTAssertNil(value.inputTokens); XCTAssertNil(value.outputTokens)
    XCTAssertEqual(value.failurePhase, "submission_validation")
    XCTAssertEqual(value.failureIssue, "submission_shape")
    XCTAssertEqual(value.engineTimings, ["engine_total": 3.5, "first_sdk_chunk": 1.2])
    await fixture.close()
  }

  func testDoneReportsUsageOnceBeforeReturningTheAnswer() async throws {
    let fixture = try fixture()
    var usages: [ScreenshotQuestionUsage] = []
    let answer = try await fixture.transport.answer(
      payload: payload("usage"), onUsage: { usages.append($0) }, onPartial: { _ in })
    XCTAssertEqual(answer, "usage")
    XCTAssertEqual(
      usages, [ScreenshotQuestionUsage(inputTokens: 12, outputTokens: 4, reasoningTokens: 0)])
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(usages.count, 1, "Duplicate completion must not report usage twice")
    await fixture.close()
  }

  func testMalformedUsageDoesNotFailAnOtherwiseValidAnswer() async throws {
    let fixture = try fixture()
    for question in [
      "usageBoolean", "usageFractional", "usageIntegralFloat", "usageNegative", "usageString",
      "usageMissing",
    ] {
      var usages: [ScreenshotQuestionUsage] = []
      let answer = try await fixture.transport.answer(
        payload: payload(question), onUsage: { usages.append($0) }, onPartial: { _ in })
      XCTAssertEqual(answer, question)
      XCTAssertTrue(usages.isEmpty)
    }
    await fixture.close()
  }

  func testOverlappingRequestsStaySeparateInOnePersistentProcess() async throws {
    let fixture = try fixture()
    try await fixture.transport.warmUp()
    let firstPID = try String(contentsOf: fixture.pidFile)
    let first = Task {
      try await fixture.transport.answer(payload: payload("first"), onPartial: { _ in })
    }
    let second = Task {
      try await fixture.transport.answer(payload: payload("second"), onPartial: { _ in })
    }
    let firstAnswer = try await first.value
    let secondAnswer = try await second.value
    XCTAssertEqual(firstAnswer, "first")
    XCTAssertEqual(secondAnswer, "second")
    XCTAssertEqual(try String(contentsOf: fixture.pidFile), firstPID)
    await fixture.close()
  }

  func testCancellationIsPromptAndLateFramesCannotLeakToAnotherRequest() async throws {
    let fixture = try fixture()
    let firstPartial = expectation(description: "first partial")
    var cancelledPartials: [String] = []
    var cancelledUsage: [ScreenshotQuestionUsage] = []
    let task = Task {
      try await fixture.transport.answer(
        payload: payload("slow"), onUsage: { cancelledUsage.append($0) }
      ) {
        cancelledPartials.append($0)
        if cancelledPartials.count == 1 { firstPartial.fulfill() }
      }
    }
    await fulfillment(of: [firstPartial], timeout: 2)
    let started = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    var nextUsage: [ScreenshotQuestionUsage] = []
    let answer = try await fixture.transport.answer(
      payload: payload("next"), onUsage: { nextUsage.append($0) }, onPartial: { _ in })
    XCTAssertEqual(answer, "next")
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(cancelledPartials, ["slow"])
    XCTAssertTrue(
      cancelledUsage.isEmpty, "Cancelled request's late completion must not report usage")
    XCTAssertEqual(nextUsage, [ScreenshotQuestionUsage(outputTokens: 8)])
    await fixture.close()
  }

  func testCrashFailsPendingThenNextRequestRestartsWithoutReplaying() async throws {
    let fixture = try fixture()
    do {
      _ = try await fixture.transport.answer(payload: payload("crash"), onPartial: { _ in })
      XCTFail("Expected disconnected child")
    } catch { XCTAssertTrue(error is LangChainTransportError) }
    let deadPID = try String(contentsOf: fixture.pidFile)
    let answer = try await fixture.transport.answer(
      payload: payload("restarted"), onPartial: { _ in })
    XCTAssertEqual(answer, "restarted")
    XCTAssertNotEqual(try String(contentsOf: fixture.pidFile), deadPID)
    await fixture.close()
  }

  func testWrongVersionAndProtocolFailStartup() async throws {
    for scenario in [
      "old", "future", "prerelease", "wrongProtocol", "booleanProtocol", "malformed",
    ] {
      let fixture = try fixture(scenario)
      do {
        try await fixture.transport.warmUp()
        XCTFail("Expected rejected startup: \(scenario)")
      } catch {
        if scenario == "malformed" {
          XCTAssertTrue(error is ScreenshotQuestionError)
        } else {
          guard case LangChainTransportError.incompatibleRuntime = error else {
            XCTFail("Wrong startup error for \(scenario): \(error)")
            await fixture.close()
            continue
          }
        }
      }
      await fixture.close()
    }
  }

  func testStartupAndRequestDeadlinesDoNotHang() async throws {
    let startup = try fixture("silent", startupTimeout: 0.15)
    do {
      try await startup.transport.warmUp()
      XCTFail("Expected startup timeout")
    } catch {
      guard case LangChainTransportError.startupTimeout = error else {
        XCTFail("Wrong error: \(error)")
        await startup.close()
        return
      }
    }
    await startup.close()
    let request = try fixture(requestTimeout: 0.15)
    do {
      _ = try await request.transport.answer(payload: payload("hang"), onPartial: { _ in })
      XCTFail("Expected request timeout")
    } catch {
      guard case LangChainTransportError.requestTimeout = error else {
        XCTFail("Wrong error: \(error)")
        await request.close()
        return
      }
    }
    let answer = try await request.transport.answer(
      payload: payload("afterTimeout"), onPartial: { _ in })
    XCTAssertEqual(answer, "afterTimeout")
    await request.close()
  }

  func testStructuredErrorsNeverExposeHelperMessage() async throws {
    let fixture = try fixture()
    for (question, expected) in [
      ("server", ScreenshotQuestionError.server(401).localizedDescription),
      ("truncated", ScreenshotQuestionError.truncatedResponse.localizedDescription),
      ("empty", ScreenshotQuestionError.emptyResponse.localizedDescription),
      ("invalid", ScreenshotQuestionError.invalidResponse.localizedDescription),
      ("connection", LangChainTransportError.connection.localizedDescription),
      ("skillsPrerequisite", MathMethodMatchError.prerequisiteNotSatisfied.localizedDescription),
    ] {
      do {
        _ = try await fixture.transport.answer(payload: payload(question), onPartial: { _ in })
        XCTFail("Expected \(question) error")
      } catch { XCTAssertEqual(error.localizedDescription, expected) }
    }
    await fixture.close()
  }
  func testProviderRequestDiagnosticsNeverExposeUnknownFieldsOrProse() async throws {
    let fixture = try fixture()
    for scenario in ["valid", "unknown", "duplicate", "auth"] {
      do {
        _ = try await fixture.transport.answer(payload: payload("providerFields:" + scenario), onPartial: { _ in })
        XCTFail("Expected request rejection")
      } catch {
        if scenario == "valid" {
          XCTAssertEqual((error as? MathProviderRequestError)?.fields, ["$ref", "tools"])
          XCTAssertEqual((error as? MathProviderRequestError)?.status, 400)
        } else { XCTAssertTrue(error is ScreenshotQuestionError) }
        XCTAssertFalse(error.localizedDescription.contains("secret"))
        XCTAssertFalse(error.localizedDescription.contains("private@example"))
      }
    }
    await fixture.close()
  }

  func testMathSubmissionFailuresExposeOnlyAllowlistedLocalLabels() async throws {
    let fixture = try fixture()
    for issue in ["submission_shape", "untrusted-secret"] {
      do {
        _ = try await fixture.transport.answer(payload: payload("mathSubmission:" + issue), onPartial: { _ in })
        XCTFail("Expected structured failure")
      } catch {
        if issue == "submission_shape" {
          XCTAssertEqual((error as? MathSolutionSubmissionError)?.issue, issue)
        } else { XCTAssertTrue(error is ScreenshotQuestionError) }
        XCTAssertFalse(error.localizedDescription.contains("untrusted-secret"))
      }
    }
    await fixture.close()
  }

  func testTeachingOutputFailuresReportOnlyKnownStagesAndIssues() async throws {
    let fixture = try fixture()
    for (question, expected) in [
      ("learningCoverage", "已有方法覆盖检查未完成：模型未按要求提炼可复用的题目结构。没有自动批准方法，可重试教研检查。"),
      ("learningDraft", "新方法草拟未完成：模型引用了未提供的原题或原题数量不足。没有自动批准方法，可重试教研检查。"),
      ("learningReview", "候选五项审校未完成：模型未完整检查五项教研要求。没有自动批准方法，可重试教研检查。"),
      ("learningProfile", "已有方法五项审校未完成：模型报告遗漏或多出了必要项目。没有自动批准方法，可重试教研检查。"),
      ("learningUnsafe", "模型教研报告不符合要求，没有自动批准方法，请重试教研检查"),
    ] {
      do {
        _ = try await fixture.transport.answer(payload: payload(question), onPartial: { _ in })
        XCTFail("Expected teaching failure")
      } catch {
        XCTAssertEqual(error.localizedDescription, MathQuestionStoreError.database(expected).localizedDescription)
        XCTAssertFalse(error.localizedDescription.contains("untrusted-secret"))
      }
    }
    await fixture.close()
  }

  func testMissingOrInvalidHTTPStatusDoesNotBecome500() async throws {
    let fixture = try fixture()
    for question in ["serverMissing", "serverBoolean", "serverFractional", "serverOutOfRange"] {
      do {
        _ = try await fixture.transport.answer(payload: payload(question), onPartial: { _ in })
        XCTFail("Expected rejected HTTP status")
      } catch {
        XCTAssertEqual(
          error.localizedDescription, ScreenshotQuestionError.invalidResponse.localizedDescription)
      }
    }
    await fixture.close()
  }

  func testOversizedOutputFrameFailsWithoutUnboundedBuffering() async throws {
    let fixture = try fixture()
    do {
      _ = try await fixture.transport.answer(payload: payload("oversize"), onPartial: { _ in })
      XCTFail("Expected rejected large frame")
    } catch { XCTAssertTrue(error is ScreenshotQuestionError || error is LangChainTransportError) }
    await fixture.close()
  }

  func testInheritedProviderCredentialsAndTelemetryAreStripped() async throws {
    let fixture = try fixture()
    let answer = try await fixture.transport.answer(
      payload: payload("environment"), onPartial: { _ in })
    XCTAssertEqual(answer, "preserved")
    await fixture.close()
  }

  func testCancellingOneStartupWaiterKeepsOtherWaitersAlive() async throws {
    let fixture = try fixture("delayed")
    let first = Task { try await fixture.transport.warmUp() }
    let second = Task { try await fixture.transport.warmUp() }
    try await Task.sleep(nanoseconds: 40_000_000)
    first.cancel()
    do {
      try await first.value
      XCTFail("Expected cancelled warmup")
    } catch { XCTAssertTrue(error is CancellationError) }
    try await second.value
    let answer = try await fixture.transport.answer(payload: payload("ready"), onPartial: { _ in })
    XCTAssertEqual(answer, "ready")
    await fixture.close()
  }

  func testIdleStdoutEOFTerminatesChildEvenIfItKeepsRunning() async throws {
    let fixture = try fixture("idleEOF")
    try await fixture.transport.warmUp()
    let pid = try XCTUnwrap(Int32(try String(contentsOf: fixture.pidFile)))
    for _ in 0..<50 {
      if kill(pid, 0) != 0 { break }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "An idle child that closes stdout must not be orphaned")
    await fixture.close()
  }

  func testAggregateAnswerBoundRejectsManyIndividuallyValidFrames() async throws {
    let fixture = try fixture()
    do {
      _ = try await fixture.transport.answer(payload: payload("aggregate"), onPartial: { _ in })
      XCTFail("Expected aggregate size rejection")
    } catch { XCTAssertTrue(error is ScreenshotQuestionError) }
    let answer = try await fixture.transport.answer(
      payload: payload("healthy"), onPartial: { _ in })
    XCTAssertEqual(answer, "healthy")
    await fixture.close()
  }

  func testCrashWithQueuedLargeWriteDoesNotSignalTerminateTheApplication() async throws {
    let fixture = try fixture("crashOnRead")
    try await fixture.transport.warmUp()
    // Larger than the OS pipe buffer: the child exits while a write is pending.
    do {
      _ = try await fixture.transport.answer(
        payload: payload(String(repeating: "x", count: 2_000_000)), onPartial: { _ in })
      XCTFail("Expected pipe failure")
    } catch { XCTAssertTrue(error is LangChainTransportError) }
    await fixture.close()
  }

  func testShutdownFailsPendingAndTerminatesHelper() async throws {
    let fixture = try fixture()
    try await fixture.transport.warmUp()
    let pid = try XCTUnwrap(Int32(try String(contentsOf: fixture.pidFile)))
    let task = Task {
      try await fixture.transport.answer(payload: payload("hang"), onPartial: { _ in })
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    await fixture.transport.shutdown()
    do {
      _ = try await task.value
      XCTFail("Expected disconnected request")
    } catch { XCTAssertTrue(error is LangChainTransportError) }
    for _ in 0..<40 {
      if kill(pid, 0) != 0 { break }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "Shutdown must not orphan its helper")
    await fixture.close()
  }

  func testMissingExecutableReportsUnavailableWithoutLeakingWaiter() async throws {
    let transport = LangChainQuestionTransport(
      executableURL: URL(fileURLWithPath: "/does-not-exist/VocabCaptureQuestionEngine"))
    for _ in 0..<2 {
      do {
        try await transport.warmUp()
        XCTFail("Expected missing engine")
      } catch {
        guard case LangChainTransportError.unavailable = error else {
          XCTFail("Wrong missing-engine error: \(error)")
          return
        }
      }
    }
    await transport.shutdown()
  }

  private static let helper = #"""
    import json, os, signal, sys, threading, time
    scenario, pid_file = sys.argv[1:]
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))
    lock = threading.Lock()
    def emit(frame, split=False):
        data = (json.dumps(frame, ensure_ascii=False) + "\n").encode()
        with lock:
            if split:
                for byte in data:
                    os.write(1, bytes([byte]))
            else:
                os.write(1, data)
    if scenario == "silent":
        time.sleep(60)
    if scenario == "delayed":
        time.sleep(0.2)
    if scenario == "malformed":
        os.write(1, b"not JSON\n")
    else:
        versions = {"old": "1.3.9", "future": "2.0.0", "prerelease": "1.4.3rc1"}
        protocol = True if scenario == "booleanProtocol" else (2 if scenario == "wrongProtocol" else 1)
        emit({"type": "ready", "protocol": protocol,
              "langchain_version": versions.get(scenario, "1.4.3")})
    if scenario == "idleEOF":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(0.05)
        os.close(1)
        time.sleep(60)
    if scenario == "crashOnRead":
        os.read(0, 1)
        os._exit(9)
    def answer(frame):
        id, question = frame["id"], frame["question"]
        if question == "progress":
            for stage in ["query", "search", "answer"]:
                emit({"type": "progress", "id": id, "stage": stage})
            emit({"type": "delta", "id": id, "text": "verified answer"})
            emit({"type": "done", "id": id, "text": "verified answer"})
            emit({"type": "progress", "id": id, "stage": "search"})
            return
        if question == "searchAuthentication":
            emit({"type": "error", "id": id, "code": "searchAuthentication",
                  "message": "untrusted-key"})
            return
        if question.startswith("providerFields:"):
            diagnostic_case = question.split(":", 1)[1]
            fields = {"valid": ["tools", "$ref"], "unknown": ["tools", "secret"],
                      "duplicate": ["tools", "tools"], "auth": ["tools"]}[diagnostic_case]
            emit({"type": "error", "id": id, "code": "server", "status": 401 if diagnostic_case == "auth" else 400,
                  "request_fields": fields, "message": "secret private@example"})
            return
        if question == "failureClocks":
            event = {"type": "error", "id": id, "code": "mathSubmission", "submission_issue": "submission_shape",
                     "failure_phase": "submission_validation", "timings": {"engine_total": 3.5, "first_sdk_chunk": 1.2,
                     "tool_binding": True, "stream_total": -1, "untrusted-secret": 3}, "message": "untrusted-secret"}
            emit(event)
            emit(event)
            emit({"id": id, "type": "done", "text": "must not become answer"})
            return
        if question.startswith("mathSubmission:"):
            emit({"type": "error", "id": id, "code": "mathSubmission",
                  "submission_issue": question.split(":", 1)[1], "message": "untrusted-secret"})
            return
        if question == "crash":
            os._exit(7)
        if question == "hang":
            time.sleep(60)
            return
        if question == "oversize":
            with lock:
                os.write(1, b"x" * 1100000)
            return
        if question == "aggregate":
            for _ in range(3):
                emit({"type": "delta", "id": id, "text": "x" * 400000})
                time.sleep(0.03)
            emit({"type": "done", "id": id, "text": "too big"})
            return
        if question in ["serverMissing", "serverBoolean", "serverFractional", "serverOutOfRange"]:
            event = {"type": "error", "id": id, "code": "server"}
            if question != "serverMissing":
                event["status"] = {"serverBoolean": True, "serverFractional": 500.5, "serverOutOfRange": 600}[question]
            emit(event)
            return
        if question.startswith("learning"):
            stage, issue = {"learningCoverage": ("coverage", "pattern_key"),
                            "learningDraft": ("draft", "evidence_references"),
                            "learningReview": ("review", "review_dimensions"),
                            "learningProfile": ("profile_review", "fields"),
                            "learningUnsafe": ("untrusted-secret", "untrusted-secret")}[question]
            emit({"type": "error", "id": id, "code": "learningOutput",
                  "learning_stage": stage, "learning_issue": issue, "message": "untrusted-secret"})
            return
        if question in ["server", "truncated", "empty", "invalid", "connection", "skillsPrerequisite"]:
            emit({"type": "error", "id": id, "code": question, "status": 401,
                  "message": "This untrusted string must never be shown"})
            return
        if question == "environment":
            banned = ["OPENAI_API_KEY", "LANGSMITH_TRACING", "PYTHONPATH"]
            text = "unsafe" if any(x in os.environ for x in banned) else os.environ["FIXTURE_NON_SECRET"]
            emit({"type": "done", "id": id, "text": text})
            return
        if question == "unicode":
            emit({"type": "delta", "id": id, "text": "你"}, split=True)
            emit({"type": "delta", "id": id, "text": "好🌍"}, split=True)
            emit({"type": "done", "id": id, "text": "  你好🌍  "}, split=True)
            return
        if question.startswith("usage"):
            usage = {"usage": {"input_tokens": 12, "output_tokens": 4, "reasoning_tokens": 0},
                     "usageBoolean": {"output_tokens": True},
                     "usageFractional": {"output_tokens": 4.5},
                     "usageIntegralFloat": {"output_tokens": 4.0},
                     "usageNegative": {"output_tokens": -1},
                     "usageString": {"output_tokens": "4"}, "usageMissing": None}[question]
            event = {"type": "done", "id": id, "text": question}
            if usage is not None:
                event["usage"] = usage
            emit(event)
            if question == "usage":
                emit(event)
            return
        emit({"type": "delta", "id": id, "text": question})
        time.sleep(0.4 if question == "slow" else 0.04)
        if question == "slow":
            emit({"type": "delta", "id": id, "text": "late"})
        event = {"type": "done", "id": id, "text": question}
        if question in ["slow", "next"]:
            event["usage"] = {"output_tokens": 999 if question == "slow" else 8}
        emit(event)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get("op") == "answer":
            threading.Thread(target=answer, args=(frame,), daemon=True).start()
    """#
}
