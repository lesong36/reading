import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class MathMethodMatcherTests: XCTestCase {
  func testScopedExtensionPermissionAndLaterDenialsControlEligibility() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "repeated-digit-blocks" })
    let candidate = MathTeachingMethod(id: skill.sourceID, versionID: "scoped-extension",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for request in ["四年级，允许本题拓展知识。", "四年级，可以使用本题所需的拓展方法。",
                    "四年级，不允许拓展。现在允许本题使用拓展知识。"] {
      XCTAssertEqual(MathMethodMatcher.eligibleMethods([candidate], question: request).count, 1, request)
    }
    for request in ["四年级，不用方程。", "四年级，不可以本题使用拓展知识。",
                    "四年级，不能使用本题所需的拓展方法。", "四年级，允许本题拓展知识；现在不允许本题拓展知识。"] {
      XCTAssertTrue(MathMethodMatcher.eligibleMethods([candidate], question: request).isEmpty, request)
    }
  }

  private let method = MathTeachingMethod(
    id: "known", versionID: "v1", title: "盈亏问题", category: "两个未知数", instructions: "先求总差，再求单差。",
    createdAt: Date())
  func testParserReturnsExactSnapshotAndAllowsNoMatch() throws {
    let selected = try MathMethodMatcher.parse(
      "{\"method_id\":\"known\",\"reason\":\"两种分配的总数相同。\"}", methods: [method])
    XCTAssertEqual(selected.method, method)
    let absent = try MathMethodMatcher.parse(
      "{\"method_id\":null,\"reason\":\"英语阅读，无适用方法。\"}", methods: [method])
    XCTAssertNil(absent.method)
  }
  func testParserRejectsInventedMethodsMalformedJSONAndEmptyReasons() {
    for output in [
      "{}", "{\"method_id\":\"invented\",\"reason\":\"理由\"}",
      "{\"method_id\":null,\"reason\":\" \"}", "{\"method_id\":3,\"reason\":\"理由\"}",
      "{\"method_id\":null,\"reason\":\"理由\",\"answer\":12}",
      "```json\n{\"method_id\":null,\"reason\":\"理由\"}\n```",
    ] {
      XCTAssertThrowsError(try MathMethodMatcher.parse(output, methods: [method]))
    }
  }

  func testParserSelectsPrimaryAndSpecificVisualMethodsAndRejectsInvalidCombinations() throws {
    let diagram = MathTeachingMethod(
      id: "diagram", versionID: "diagram-v1", title: "列表法",
      category: "数形结合", instructions: "一行一种假设，把差列出来。", createdAt: Date())
    let candidates = [method, diagram]
    let match = try MathMethodMatcher.parse(
      #"{"method_id":"known","visual_method_ids":["diagram"],"reason":"盈亏比较两次分配，列表展示差。"}"#,
      methods: candidates)
    XCTAssertEqual(match.method, method)
    XCTAssertEqual(match.visualMethods, [diagram])
    let visualOnly = try MathMethodMatcher.parse(
      #"{"method_id":null,"visual_method_ids":["diagram"],"reason":"仅需要列出关系。"}"#,
      methods: candidates)
    XCTAssertNil(visualOnly.method)
    XCTAssertEqual(visualOnly.visualMethods, [diagram])
    for ids in [
      #"["missing"]"#, #"["known"]"#, #"["diagram","diagram"]"#, #"["diagram","a","b"]"#, "null",
      "42",
    ] {
      XCTAssertThrowsError(
        try MathMethodMatcher.parse(
          "{\"method_id\":\"known\",\"visual_method_ids\":\(ids),\"reason\":\"检查\"}",
          methods: candidates))
    }
  }

  func testCombinedMethodsReachSolverAndSurviveSaveReopenAndLaterMethodEdits() async throws {
    let store = store()
    let primary = try await store.saveMethod(
      title: "盈亏问题", category: "两个未知数", instructions: "先求总差，再求单差。")
    let diagram = try await store.saveMethod(
      title: "列表法", category: "数形结合", instructions: "每行记录人数、每人张数、余差；不能以例题数字作为本题条件。")
    let bitmap = try XCTUnwrap(
      CGContext(
        data: nil, width: 20, height: 10, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(bitmap.makeImage())))
    var sent = ""
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "分发绘图纸", selectedWord: nil, imageData: image),
      answer: { question, _, _, _ in
        if sent.isEmpty { sent = question }
        return "盈亏问题与列表法的未核验回答"
      }, originalImageData: image,
      saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in
        .init(method: primary, visualMethods: [diagram], reason: "两种分配对应同一总量，列表比较余差。")
      })
    defer { panel.close() }
    panel.present()
    let (_, input, ask) = try controls(panel)
    input.stringValue = "不用方程，请解题并画出关系"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertTrue(sent.contains(primary.instructions))
    XCTAssertTrue(sent.contains(diagram.instructions))
    XCTAssertTrue(sent.contains("从图中推导算式"))
    XCTAssertTrue(sent.contains("不用方程，请解题并画出关系"))
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("数形结合：列表法")
      })
    let save = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" })
    save.performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let id = try XCTUnwrap(panel.savedQuestionID)
    _ = try await store.saveMethod(
      id: primary.id, title: "已修改的主解法", category: "", instructions: "新内容")
    _ = try await store.saveMethod(
      id: diagram.id, title: "已修改的图解", category: "", instructions: "新画法")
    await store.close()
    let reopened = try await store.solutions(questionID: id)
    XCTAssertEqual(reopened.first?.method, primary)
    XCTAssertEqual(reopened.first?.visualMethods, [diagram])
    XCTAssertEqual(reopened.first?.verificationStatus, "unverified")
    await store.close()
  }

  func testVisualSnapshotReadsLegacyAndVisualOnlyAnswers() throws {
    let legacy = try JSONEncoder().encode(method)
    let read = try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: legacy)
    XCTAssertEqual(read.method, method)
    XCTAssertTrue(read.visualMethods.isEmpty)
    let visualOnly = MathSolutionMethodSnapshot(method: nil, visualMethods: [method])
    let encoded = try XCTUnwrap(visualOnly.encoded())
    let decoded = try JSONDecoder().decode(
      MathSolutionMethodSnapshot.self, from: Data(encoded.utf8))
    XCTAssertNil(decoded.method)
    XCTAssertEqual(decoded.visualMethods, [method])
    let originalAnswer = MathQuestionSolution(
      question: "题目", answer: "回答", model: "test", method: method)
    var old = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(originalAnswer)) as? [String: Any])
    old.removeValue(forKey: "visualMethods")
    let oldAnswer = try JSONDecoder().decode(
      MathQuestionSolution.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertTrue(oldAnswer.visualMethods.isEmpty)
    XCTAssertEqual(oldAnswer.method, method)
  }
  private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
  private func settle(_ check: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await check() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Panel did not settle")
  }
  private func store() -> MathQuestionStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return MathQuestionStore(directory: directory)
  }
  private func controls(_ panel: ScreenshotQuestionPanel) throws -> (
    NSPopUpButton, NSTextField, NSButton
  ) {
    let all = views(panel.contentView!)
    return (
      try XCTUnwrap(
        all.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("AI 自动选择方法") }),
      try XCTUnwrap(
        all.compactMap { $0 as? NSTextField }.first {
          $0.placeholderString?.hasPrefix("例如") == true
        }),
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" })
    )
  }

  func testAutomaticMethodFlowsIntoSolverAndManualNoneBypassesMatching() async throws {
    let store = store()
    let saved = try await store.saveMethod(
      title: method.title, category: method.category, instructions: method.instructions)
    var calls = 0
    var solverQuestions: [String] = []
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "两种分配问题", selectedWord: nil, imageData: nil),
      answer: { question, _, _, _ in
        solverQuestions.append(question)
        return "未核验回答"
      },
      mathStore: store,
      selectMethodAutomatically: { question, context, entries in
        calls += 1
        XCTAssertTrue(question.contains("不要使用方程"))
        XCTAssertNil(context.imageData)
        XCTAssertEqual(entries, [saved])
        return .init(method: entries.first, reason: "两种分配符合总差与单差条件。")
      })
    defer { panel.close() }
    panel.present()
    let (picker, input, ask) = try controls(panel)
    try await settle { picker.numberOfItems == 3 }
    XCTAssertEqual(picker.indexOfSelectedItem, 0)
    input.stringValue = "不要使用方程，请解题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(solverQuestions[0].contains(saved.instructions))
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("自动选择：盈亏问题")
      })
    picker.selectItem(withTitle: "不指定解题方法")
    picker.sendAction(picker.action, to: picker.target)
    input.stringValue = "Explain this sentence"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(solverQuestions.last, "Explain this sentence")
    picker.selectItem(at: 2)
    picker.sendAction(picker.action, to: picker.target)
    let manualRequestIndex = solverQuestions.count
    input.stringValue = "解题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(solverQuestions[manualRequestIndex].contains(saved.instructions))
    await store.close()
  }

  func testFailedSelectionNeverReusesPreviousMethod() async throws {
    let store = store()
    let saved = try await store.saveMethod(
      title: method.title, category: method.category, instructions: method.instructions)
    var calls = 0
    var questions: [String] = []
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "数学题", selectedWord: nil, imageData: nil),
      answer: { question, _, _, _ in
        questions.append(question)
        return "回答"
      }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in
        calls += 1
        if calls == 1 { return .init(method: saved, reason: "适用") }
        throw MathMethodMatchError.invalidOutput
      })
    defer { panel.close() }
    panel.present()
    let (_, input, ask) = try controls(panel)
    input.stringValue = "解题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    input.stringValue = "换一种方法"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 2 }
    XCTAssertEqual(questions.last, "换一种方法")
    XCTAssertTrue(
      views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
        $0.stringValue.contains("自动选择失败")
      })
    await store.close()
  }

  func testAutomaticSelectionUsesCheckedOriginalAndPersistsVersionDespiteLaterEdits() async throws {
    let store = store()
    let saved = try await store.saveMethod(
      title: method.title, category: method.category, instructions: method.instructions)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let original = try XCTUnwrap(
      MathQuestionIndexer.originalPNG(try XCTUnwrap(context.makeImage())))
    let thumbnail = Data("thumbnail".utf8)
    var firstQuestion = ""
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "", selectedWord: nil, imageData: thumbnail),
      answer: { question, _, _, _ in
        if firstQuestion.isEmpty { firstQuestion = question }
        return "回答"
      }, originalImageData: original,
      saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, source, entries in
        XCTAssertEqual(source.imageData, original)
        _ = try await store.saveMethod(
          id: saved.id, title: "用户改名", category: "", instructions: "修改步骤")
        return .init(method: entries.first, reason: "满足条件")
      })
    defer { panel.close() }
    panel.present()
    let (_, input, ask) = try controls(panel)
    input.stringValue = "解题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    XCTAssertTrue(firstQuestion.contains(saved.instructions))
    let save = try XCTUnwrap(
      views(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" })
    save.performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let answers = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    XCTAssertEqual(answers.first?.method, saved)
    XCTAssertEqual(answers.first?.verificationStatus, "unverified")
    await store.close()
  }

  func testRejectedPrerequisitesContinueAnswerWithoutMethodAndSaveNotice() async throws {
    let store = store()
    let saved = try await store.saveMethod(title: method.title, category: method.category,
      instructions: method.instructions)
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let original = try XCTUnwrap(MathQuestionIndexer.originalPNG(try XCTUnwrap(bitmap.makeImage())))
    var requests: [String] = []
    var selections = 0
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "必要条件不成立的题目", selectedWord: nil, imageData: nil),
      answer: { question, _, _, _ in requests.append(question); return "仍待用户核验的回答" },
      originalImageData: original, saveQuestion: { try await store.save($0) }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in
        selections += 1
        if selections == 1 { return .init(method: saved, reason: "上一轮满足条件") }
        throw MathMethodMatchError.prerequisiteNotSatisfied
      })
    defer { panel.close() }
    panel.present()
    let (_, input, ask) = try controls(panel)
    input.stringValue = "解题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 1 }
    input.stringValue = "检查另一道题"
    ask.performClick(nil)
    try await settle { !panel.isAnswering && panel.history.count == 2 }
    XCTAssertEqual(requests.last, "检查另一道题")
    XCTAssertFalse(try XCTUnwrap(requests.last).contains(saved.instructions))
    XCTAssertTrue(views(panel.contentView!).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue == MathMethodMatchError.prerequisiteNotSatisfied.localizedDescription
    })
    let save = try XCTUnwrap(views(panel.contentView!).compactMap { $0 as? NSButton }
      .first { $0.title == "保存题目" })
    save.performClick(nil)
    try await settle { panel.savedQuestionID != nil }
    let answers = try await store.solutions(questionID: XCTUnwrap(panel.savedQuestionID))
    let blocked = try XCTUnwrap(answers.last)
    XCTAssertNil(blocked.method)
    XCTAssertTrue(blocked.visualMethods.isEmpty)
    XCTAssertEqual(blocked.selectionFailure, MathMethodMatchError.prerequisiteNotSatisfied.localizedDescription)
    XCTAssertEqual(blocked.verificationStatus, "unverified")
    XCTAssertEqual(blocked.answer, "仍待用户核验的回答")
    await store.close()
  }

  func testCaptureChangeDiscardsInFlightMatch() async throws {
    let store = store()
    let saved = try await store.saveMethod(
      title: method.title, category: method.category, instructions: method.instructions)
    var continuation: CheckedContinuation<MathMethodMatch, Never>?
    var solverCalled = false
    let panel = ScreenshotQuestionPanel(
      context: .init(text: "旧题", selectedWord: nil, imageData: nil),
      answer: { _, _, _, _ in
        solverCalled = true
        return "回答"
      }, mathStore: store,
      selectMethodAutomatically: { _, _, _ in await withCheckedContinuation { continuation = $0 } })
    defer { panel.close() }
    panel.present()
    let (_, input, ask) = try controls(panel)
    input.stringValue = "解题"
    ask.performClick(nil)
    try await settle { continuation != nil }
    panel.updateContext(.init(text: "新题", selectedWord: nil, imageData: nil))
    continuation?.resume(returning: .init(method: saved, reason: "旧题适用"))
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertFalse(solverCalled)
    XCTAssertTrue(panel.history.isEmpty)
    XCTAssertFalse(panel.isAnswering)
    await store.close()
  }
}

@MainActor
final class MathMethodLiveTests: XCTestCase {
  func testConfiguredModelDrawsStairIntervalsInActualQuestionPanel() async throws {
    guard let folder = ProcessInfo.processInfo.environment["MATH_STAIRS_LIVE_ARTIFACTS"] else {
      throw XCTSkip("Set artifact directory for real-model staircase panel verification")
    }
    let destination = URL(fileURLWithPath: folder)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let configuration = preferences.configuration(fallingBackTo: fallback)
    let client = ScreenshotQuestionClient()
    let matcher = MathMethodMatcher(client: client)
    // The original photo is authoritative even when OCR contains only the question number.
    let source = NSImage(size: NSSize(width: 1100, height: 220))
    source.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1100, height: 220).fill()
    NSAttributedString(string: "62. 从1楼走到14楼，每相邻两层楼之间有21级台阶。\n一共需要走多少级台阶？", attributes: [
      .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black
    ]).draw(in: NSRect(x: 35, y: 40, width: 1030, height: 145))
    source.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(source.tiffRepresentation)))
    let photo = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try photo.write(to: destination.appendingPathComponent("staircase-question.png"))
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "62", selectedWord: nil, imageData: photo),
      answer: { question, context, history, partial in
        calls += 1
        let result = try await client.answer(question: question, context: context, history: history,
          configuration: configuration, api: preferences.selectedAPI, thinking: .off,
          directConnection: preferences.selectedDirectConnection, onPartial: partial)
        try result.write(to: destination.appendingPathComponent("response-\(calls).txt"), atomically: true, encoding: .utf8)
        return result
      }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { question, context, methods in
        let match = try await matcher.select(question: question, context: context, methods: methods,
          configuration: configuration, api: preferences.selectedAPI,
          directConnection: preferences.selectedDirectConnection)
        try ("\(match.method?.title ?? "none") + \(match.visualMethods.map(\.title).joined(separator: "、"))\n\(match.reason)")
          .write(to: destination.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(match.visualMethods.contains { $0.title == "点与间隔图" })
        return match
      })
    defer { panel.close() }
    panel.present()
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<1800 {
      if !panel.isAnswering && !panel.history.isEmpty { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(panel.history.count, 1)
    XCTAssertTrue(panel.history.first?.answer.contains("273") == true)
    let transcripts = views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextView }
    var attached = false
    for text in transcripts {
      text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in
        attached = attached || value is NSTextAttachment
      }
      XCTAssertFalse(text.string.contains("图解未生成"), text.string)
    }
    XCTAssertTrue(attached, "A real-model answer must render an actual image attachment in the question panel")
    // Export the model-produced diagram independently of the transcript's scroll position.
    for call in 1...max(1, calls) {
      let url = destination.appendingPathComponent("response-\(call).txt")
      if let raw = try? String(contentsOf: url), let diagram = MathDiagramAnswer.parse(raw).diagrams.first {
        XCTAssertEqual(diagram.kind, .interval)
        try MathDiagramRenderer.renderPNG(diagram).write(to: destination.appendingPathComponent("staircase-diagram.png"))
      }
    }
    let view = try XCTUnwrap(panel.contentView)
    let capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: capture)
    try XCTUnwrap(capture.representation(using: .png, properties: [:]))
      .write(to: destination.appendingPathComponent("staircase-panel.png"))
    print("Live staircase: \(calls) model answer calls; actual panel attachment: \(attached)")
    await client.shutdown()
    await store.close()
  }

  func testConfiguredModelDrawsDifferenceRatioInActualQuestionPanel() async throws {
    guard let folder = ProcessInfo.processInfo.environment["MATH_DIFFERENCE_RATIO_LIVE_ARTIFACTS"] else {
      throw XCTSkip("Set artifact directory for real-model difference-ratio panel verification")
    }
    let destination = URL(fileURLWithPath: folder)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let configuration = preferences.configuration(fallingBackTo: fallback)
    let client = ScreenshotQuestionClient()
    let matcher = MathMethodMatcher(client: client)
    // The original photo is authoritative even when OCR contains only the question number.
    let source = NSImage(size: NSSize(width: 1100, height: 220))
    source.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1100, height: 220).fill()
    NSAttributedString(string: "43. 一个数乘10，得到的数比原来的数大72。\n求原来的数。", attributes: [
      .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black
    ]).draw(in: NSRect(x: 35, y: 40, width: 1030, height: 145))
    source.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(source.tiffRepresentation)))
    let generatedPhoto = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let photo: Data
    if let originalPath = ProcessInfo.processInfo.environment["MATH_DIFFERENCE_RATIO_ORIGINAL_IMAGE"] {
      photo = try Data(contentsOf: URL(fileURLWithPath: originalPath))
    } else { photo = generatedPhoto }
    try photo.write(to: destination.appendingPathComponent("difference-ratio-question.png"))
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "43", selectedWord: nil, imageData: photo),
      answer: { question, context, history, partial in
        calls += 1
        let result = try await client.answer(question: question, context: context, history: history,
          configuration: configuration, api: preferences.selectedAPI, thinking: .off,
          directConnection: preferences.selectedDirectConnection, onPartial: partial)
        try result.write(to: destination.appendingPathComponent("response-\(calls).txt"), atomically: true, encoding: .utf8)
        return result
      }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { question, context, methods in
        let match = try await matcher.select(question: question, context: context, methods: methods,
          configuration: configuration, api: preferences.selectedAPI,
          directConnection: preferences.selectedDirectConnection)
        try ("\(match.method?.title ?? "none") + \(match.visualMethods.map(\.title).joined(separator: "、"))\n\(match.reason)")
          .write(to: destination.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(match.visualMethods.isEmpty)
        return match
      })
    defer { panel.close() }
    panel.present()
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<1800 {
      if !panel.isAnswering && !panel.history.isEmpty { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(panel.history.count, 1)
    XCTAssertTrue(panel.history.first?.answer.contains("8") == true)
    let transcripts = views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextView }
    var attached = false
    for text in transcripts {
      text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in
        attached = attached || value is NSTextAttachment
      }
      XCTAssertFalse(text.string.contains("图解未生成"), text.string)
    }
    XCTAssertTrue(attached, "A real-model answer must render an actual image attachment in the question panel")
    // Export the model-produced diagram independently of the transcript's scroll position.
    for call in 1...max(1, calls) {
      let url = destination.appendingPathComponent("response-\(call).txt")
      if let raw = try? String(contentsOf: url), let diagram = MathDiagramAnswer.parse(raw).diagrams.first {
        XCTAssertEqual(diagram.kind, .equalParts)
        XCTAssertTrue(diagram.parts.contains(1) && diagram.parts.contains(10))
        XCTAssertTrue([8.0, 80, 72].allSatisfy { expected in diagram.facts.contains { $0.value == expected } })
        try MathDiagramRenderer.renderPNG(diagram).write(to: destination.appendingPathComponent("difference-ratio-diagram.png"))
      }
    }
    let view = try XCTUnwrap(panel.contentView)
    let capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: capture)
    try XCTUnwrap(capture.representation(using: .png, properties: [:]))
      .write(to: destination.appendingPathComponent("difference-ratio-panel.png"))
    print("Live difference-ratio: \(calls) model answer calls; actual panel attachment: \(attached)")
    await client.shutdown()
    await store.close()
  }

  func testConfiguredModelDrawsSeparateAgeAndNumberDiagramsInActualPanel() async throws {
    guard let folder = ProcessInfo.processInfo.environment["MATH_MULTI_RATIO_LIVE_ARTIFACTS"] else {
      throw XCTSkip("Set artifact directory for real-model multi-ratio panel verification")
    }
    let destination = URL(fileURLWithPath: folder)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let configuration = preferences.configuration(fallingBackTo: fallback)
    let client = ScreenshotQuestionClient()
    let matcher = MathMethodMatcher(client: client)
    // The original photo is authoritative even when OCR contains only the question number.
    let source = NSImage(size: NSSize(width: 1100, height: 300))
    source.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1100, height: 300).fill()
    NSAttributedString(string: "44. 今年爸爸年龄是小明的3倍，去年爸爸比小明大30岁。小明今年多少岁？\n61. 一个数乘10，得到的数比原来的数大810。原来的数是多少？", attributes: [
      .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black
    ]).draw(in: NSRect(x: 35, y: 40, width: 1030, height: 245))
    source.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(source.tiffRepresentation)))
    let generatedPhoto = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let photo: Data
    if let originalPath = ProcessInfo.processInfo.environment["MATH_MULTI_RATIO_ORIGINAL_IMAGE"] {
      photo = try Data(contentsOf: URL(fileURLWithPath: originalPath))
    } else { photo = generatedPhoto }
    try photo.write(to: destination.appendingPathComponent("multi-ratio-question.png"))
    var calls = 0
    let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo),
      answer: { question, context, history, partial in
        calls += 1
        let result = try await client.answer(question: question, context: context, history: history,
          configuration: configuration, api: preferences.selectedAPI, thinking: .off,
          directConnection: preferences.selectedDirectConnection, onPartial: partial)
        try result.write(to: destination.appendingPathComponent("response-\(calls).txt"), atomically: true, encoding: .utf8)
        return result
      }, originalImageData: photo, mathStore: store,
      selectMethodAutomatically: { question, context, methods in
        let match: MathMethodMatch
        do {
          match = try await matcher.select(question: question, context: context, methods: methods,
            configuration: configuration, api: preferences.selectedAPI,
            directConnection: preferences.selectedDirectConnection)
        } catch {
          try String(describing: error).write(to: destination.appendingPathComponent("selection-error.txt"), atomically: true, encoding: .utf8)
          throw error
        }
        try ("\(match.method?.title ?? "none") + \(match.visualMethods.map(\.title).joined(separator: "、"))\n\(match.reason)")
          .write(to: destination.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(match.visualMethods.isEmpty)
        return match
      })
    defer { panel.close() }
    panel.present()
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let all = views(try XCTUnwrap(panel.contentView))
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
    let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
    field.stringValue = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
    for _ in 0..<1800 {
      if !panel.isAnswering && !panel.history.isEmpty { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertFalse(panel.isAnswering)
    XCTAssertEqual(panel.history.count, 1)
    XCTAssertTrue(panel.history.first?.answer.contains("15") == true)
    let transcripts = views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextView }
    var attached = false
    var attachmentCount = 0
    for text in transcripts {
      text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in
        attached = attached || value is NSTextAttachment
        if value is NSTextAttachment { attachmentCount += 1 }
      }
      XCTAssertFalse(text.string.contains("图解未生成"), text.string)
    }
    XCTAssertTrue(attached, "A real-model answer must render an actual image attachment in the question panel")
    XCTAssertEqual(attachmentCount, 2, "Both questions must have actual rendered image attachments")
    XCTAssertTrue(panel.history.first?.answer.contains("90") == true)
    // Export the model-produced diagrams independently of the transcript's scroll position.
    let responseURL = destination.appendingPathComponent("response-\(calls).txt")
    let raw = try String(contentsOf: responseURL)
    let parsed = MathDiagramAnswer.parse(raw)
    XCTAssertEqual(parsed.diagrams.count, 2, parsed.failure ?? raw)
    for (index, diagram) in parsed.diagrams.enumerated() {
      XCTAssertEqual(diagram.kind, .equalParts)
      let isAge = diagram.parts.contains(3)
      XCTAssertTrue(isAge || diagram.parts.contains(10))
      XCTAssertTrue((isAge ? [15.0, 45, 30] : [90.0, 900, 810]).allSatisfy { expected in diagram.facts.contains { $0.value == expected } })
      try MathDiagramRenderer.renderPNG(diagram).write(to: destination.appendingPathComponent("multi-diagram-\(index).png"))
    }
    let view = try XCTUnwrap(panel.contentView)
    let capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: capture)
    try XCTUnwrap(capture.representation(using: .png, properties: [:]))
      .write(to: destination.appendingPathComponent("multi-ratio-panel.png"))
    print("Live multi-ratio: \(calls) model answer calls; actual panel attachment: \(attached)")
    await client.shutdown()
    await store.close()
  }


  func testConfiguredModelCombinesProblemAndDiagramMethods() async throws {
    guard let folder = ProcessInfo.processInfo.environment["MATH_METHOD_COMBINED_LIVE_FOLDER"]
    else {
      throw XCTSkip("Set method folder for real combined-method matching")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MathQuestionStore(directory: directory)
    _ = try await store.importMethods(
      MathMethodImporter.read(directory: URL(fileURLWithPath: folder)))
    let methods = try await store.methods()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback =
      defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let configuration = preferences.configuration(fallingBackTo: fallback)
    let client = ScreenshotQuestionClient()
    let matcher = MathMethodMatcher(client: client)
    let examples = [
      ("两个人共有72本书，甲比乙多18本。甲、乙各有多少本？", "和差问题", ["线段图"]),
      ("老师给美术小组分绘图纸。每人25张，还余50张；每人27张，正好分完。多少名同学？共多少张纸？", "盈亏问题", ["列表法", "面积图", "线段图", "份数线段图"]),
      ("Streaming is crucial for responsive applications.", "none", []),
    ]
    for (text, expected, allowedVisual) in examples {
      let context = ScreenshotQuestionContext(text: text, selectedWord: nil, imageData: nil)
      let question = expected == "none" ? "解释这段英文" : "用小学四年级的知识解题，不使用方程。"
      let selected = try await matcher.select(
        question: question, context: context, methods: methods,
        configuration: configuration, api: preferences.selectedAPI,
        directConnection: preferences.selectedDirectConnection)
      print(
        "Combined matching: \(selected.method?.title ?? "none") + \(selected.visualMethods.map(\.title).joined(separator: "、"))"
      )
      XCTAssertEqual(selected.method?.title ?? "none", expected)
      if expected == "none" {
        XCTAssertTrue(selected.visualMethods.isEmpty)
      } else {
        XCTAssertFalse(selected.visualMethods.isEmpty)
        XCTAssertTrue(selected.visualMethods.contains { allowedVisual.contains($0.title) })
      }
      if expected != "none" {
        let answer = try await client.answer(
          question: ScreenshotQuestionPanel.question(
            question, using: selected.method, visualMethods: selected.visualMethods),
          context: context, history: [], configuration: configuration, api: preferences.selectedAPI,
          thinking: .off, directConnection: preferences.selectedDirectConnection,
          onPartial: { _ in })
        XCTAssertTrue(answer.contains(expected))
        if let folder = ProcessInfo.processInfo.environment["MATH_LIVE_DIAGRAM_ARTIFACTS"] {
          let directory = URL(fileURLWithPath: folder)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try answer.write(to: directory.appendingPathComponent("\(expected)-response.txt"), atomically: true, encoding: .utf8)
        }
        var diagram = MathDiagramAnswer.parse(answer)
        if diagram.failure != nil || diagram.diagrams.isEmpty {
          let prompt = MathDiagramAnswer.repairPrompt(question: question,
            views: ScreenshotQuestionPanel.diagramViews(question, method: selected.method, visualMethods: selected.visualMethods), failure: diagram.failure)
          let repaired = try await client.answer(question: prompt, context: context, history: [], configuration: configuration,
            api: preferences.selectedAPI, thinking: .off, directConnection: preferences.selectedDirectConnection, onPartial: { _ in })
          if let folder = ProcessInfo.processInfo.environment["MATH_LIVE_DIAGRAM_ARTIFACTS"] {
            try repaired.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(expected)-repair.txt"), atomically: true, encoding: .utf8)
          }
          diagram = MathDiagramAnswer.parse(repaired)
          print("Live diagram: one bounded repair attempted")
        }
        XCTAssertNil(diagram.failure)
        XCTAssertFalse(diagram.diagrams.isEmpty, "A real selected visual method must produce diagram data")
        if expected == "和差问题" {
          XCTAssertTrue(answer.contains("45"))
          XCTAssertTrue(answer.contains("27"))
        }
        if let folder = ProcessInfo.processInfo.environment["MATH_LIVE_DIAGRAM_ARTIFACTS"] {
          let directory = URL(fileURLWithPath: folder)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          for (index, entry) in diagram.diagrams.enumerated() {
            try MathDiagramRenderer.renderPNG(entry).write(to: directory.appendingPathComponent("\(expected)-\(index).png"))
          }
        }
        print("Combined solver: primary/diagram names and expected results present")
      }
    }
    await client.shutdown()
    await store.close()
  }

  func testConfiguredModelChoosesFromImportedMethods() async throws {
    guard let folder = ProcessInfo.processInfo.environment["MATH_METHOD_LIVE_FOLDER"],
      let samples = ProcessInfo.processInfo.environment["MATH_METHOD_LIVE_SAMPLES"]
    else { throw XCTSkip("Set method folder and public sample paths for real AI matching") }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let store = MathQuestionStore(directory: path)
    let entries = try MathMethodImporter.read(directory: URL(fileURLWithPath: folder))
    let imported = try await store.importMethods(entries)
    XCTAssertEqual(imported.imported, entries.count)
    let methods = try await store.methods()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback =
      defaults.data(forKey: "VocabCapture.aiConfiguration")
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let client = ScreenshotQuestionClient()
    let matcher = MathMethodMatcher(client: client)
    for sample in samples.split(separator: ":") {
      let fields = sample.split(separator: "|", maxSplits: 1).map(String.init)
      let image = try Data(contentsOf: URL(fileURLWithPath: fields[0]))
      let question = fields[1] == "none" ? "解释这段英文" : "请用小学四年级的算术方法解题，不要使用方程。"
      let selected = try await matcher.select(
        question: question,
        context: .init(text: "", selectedWord: nil, imageData: image), methods: methods,
        configuration: preferences.configuration(fallingBackTo: fallback),
        api: preferences.selectedAPI,
        directConnection: preferences.selectedDirectConnection)
      print(
        "Method sample: \(selected.method?.title ?? "none") · 数形结合：\(selected.visualMethods.map(\.title).joined(separator: "、")) · \(selected.reason)"
      )
      XCTAssertTrue(
        fields[1].split(separator: ",").map(String.init).contains(selected.method?.title ?? "none"))
      if fields[1] == "none" { XCTAssertTrue(selected.visualMethods.isEmpty) }
    }
    await client.shutdown()
    await store.close()
  }
}
