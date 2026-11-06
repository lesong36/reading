import AppKit
import Security
import LocalAuthentication
import XCTest
@testable import VocabCapture

/// Opt-in evidence using the configured model, image-only input and actual window.
@MainActor
final class MathDiagramSystemLiveTests: XCTestCase {
  func testConfiguredModelDrawsAcrossNativeFamiliesAndDistributionTables() async throws {
    guard let output = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_ARTIFACTS"] else { throw XCTSkip("Set MATH_SYSTEM_LIVE_ARTIFACTS for real-model drawing validation") }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let configurationStarted = ProcessInfo.processInfo.systemUptime
    let interactiveAuthorization = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_KEYCHAIN_INTERACTION"] == "1"
    let preferences = ScreenshotQuestionPreferences(defaults: defaults, readProfileAPIKey: { id in
      let authentication = LAContext()
      authentication.interactionNotAllowed = !interactiveAuthorization
      let account = id == "legacy" ? "screenshot-question-api-key" : "screenshot-question-profile-\(id)"
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.coty.vocab-capture", kSecAttrAccount: account,
        kSecReturnData: true, kSecUseAuthenticationContext: authentication]
      var result: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
        let data = result as? Data else { return "" }
      return String(decoding: data, as: UTF8.self)
    })
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration(baseURL: "", model: "", apiKey: "")
    let profileOverride = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_PROFILE"]
    if profileOverride == nil { fallback.apiKey = KeychainStore.readAPIKey() }
    let profile = try profileOverride.map { name in
      try XCTUnwrap(preferences.profiles.first { $0.name == name }, "Requested existing profile must exist")
    }
    var configuration: AIConfiguration
    if let profile {
      configuration = preferences.configuration(for: profile.id)
      guard !configuration.apiKey.isEmpty else {
        throw XCTSkip("Existing comparison profile credentials are unavailable to this test process; no provider request sent")
      }
    } else {
      configuration = preferences.configuration(fallingBackTo: fallback)
    }
    let configurationSeconds = ProcessInfo.processInfo.systemUptime - configurationStarted
    if let endpoint = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_BASE_URL"] {
      // Explicit isolated endpoint probe; never persists a model preference.
      configuration = AIConfiguration(baseURL: endpoint, model: configuration.model, apiKey: configuration.apiKey)
    }
    let selectedAPI = profile?.api ?? preferences.selectedAPI
    let directConnection = profile?.directConnection ?? preferences.selectedDirectConnection
    let client: ScreenshotQuestionClient
    if let executable = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_ENGINE_EXECUTABLE"] {
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        XCTFail("Configured live helper does not exist or is not executable")
        return
      }
      client = ScreenshotQuestionClient(langChain: .init(executableURL: URL(fileURLWithPath: executable)))
    } else {
      client = ScreenshotQuestionClient()
    }
    let prewarmStarted = Date()
    let prewarmRequested = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_WARM_ENGINE"] == "1"
    if prewarmRequested { await client.warmUp() }
    let prewarmSeconds: Double? = prewarmRequested ? Date().timeIntervalSince(prewarmStarted) : nil
    let automaticAll = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_AUTOMATIC_ALL"] == "1"
    let singlePass = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_SINGLE_PASS"] == "1"
    let programArithmetic = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_PROGRAM_ARITHMETIC"] == "1"
    let rendererTools = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_RENDERER_TOOLS"] == "1"
    let singleSubmission = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_SINGLE_SUBMISSION"] == "1"
    let automaticDistribution = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_AUTOMATIC_DISTRIBUTION"] == "1"
    let automaticRate = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_AUTOMATIC_RATE"] == "1"
    let store = MathQuestionStore(directory: destination.appendingPathComponent("isolated-library"))
    let reviewedSource = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_REVIEWED_SOURCE"]
    if let reviewedSource {
      let source = URL(fileURLWithPath: reviewedSource, isDirectory: true).resolvingSymlinksInPath()
      guard source.path.hasPrefix("/tmp/") || source.path.hasPrefix("/private/tmp/") else {
        XCTFail("Reviewed examples live acceptance requires an isolated temporary backup copy"); return
      }
      _ = try await store.restoreBackup(from: source)
    }
    if automaticAll || automaticDistribution || automaticRate { _ = try await store.importBundledMathSkills(MathSkillCatalogue.load()) }
    let matcher = MathMethodMatcher(client: client)
    let cases: [(String, String, MathDiagram.Kind, String, Double)] = [
      ("property-fee", "阳阳家的面积是115平方米，他家所在小区的物业收费标准是每个月每平方米2元。阳阳家一年的物业费是多少元？", .table, "列表法", 2760),
      ("purchase-offers", "班级读书角要买245本故事书，两家书店同样的故事书原价都是每本12元。\nA书店每满100元减15元；B书店买8本送1本。比较在哪里购买更优惠。", .table, "列表法", 2505),
      ("cloth", "服装厂原来每套衣服用布3.2米，改进后每套用2.8米。\n原来做791套的布，现在可做多少套？", .table, "列表法", 904),
      ("surplus-recipients", "给同学分绘图纸，每名同学发25张，剩下的还能发给2名同学，\n每名同学27张，正好发完。求同学人数和总张数。", .table, "列表法", 675),
      ("surplus-amount", "给同学分绘图纸，每名同学发20张，还剩60张；\n每名同学22张，正好发完。求同学人数和总张数。", .table, "列表法", 660),
      ("sum", "甲乙两班共有98名学生，甲班比乙班多6人。\n求两班各多少人？", .barComparison, "比较线段图", 52),
      ("ratio", "杏树和桃树共248棵，桃树是杏树的3倍。\n杏树、桃树各有多少棵？", .equalParts, "等份线段图", 62),
      ("difference-times", "一个数乘10，得到的数比原来的数大72。\n求原来的数。", .equalParts, "等份线段图", 8),
      ("missing-zero", "小兰计算乘法时在得数末尾少添一个0，得到的结果比正确结果少40005。求正确结果。", .equalParts, "等份线段图", 44450),
      ("state", "原来有100人，先离开30人，后来又来了20人。\n现在有多少人？", .state, "状态图", 90),
      ("area", "长方形长和宽之和是18厘米，长比宽多2厘米。\n求长方形面积。", .area, "面积图", 80),
      ("rate-return", "一次最多可玩45分钟。先顺流而下，每分钟30米，再逆流而上，每分钟20米。\n顺流行驶21分钟后返回，能否在规定时间内返回？", .table, "列表法", 31.5),
      ("price-rectangle", "买4支钢笔共花32元。\n每支钢笔多少元？", .area, "面积图", 8),
      ("work-rectangle", "每小时栽15棵树，4小时完成。\n改成3小时完成，每小时需要栽多少棵？", .area, "面积图", 20),
      ("stairs", "从1楼到14楼，每层楼间21级台阶。\n共需要走多少级台阶？", .interval, "点与间隔图", 273),
      ("planting", "河堤长136米，每隔2米栽一棵垂柳，头尾都栽。\n共需多少棵？", .interval, "点与间隔图", 69),
      ("meeting", "水路长392千米，两船同时相向而行。\n船速分别28千米/小时和21千米/小时，几小时相遇？", .partWhole, "整体分段图", 8),
      ("venn", "全班40人，25人喜欢足球，22人喜欢篮球，\n两种都喜欢的有12人，两种都不喜欢的有多少人？", .venn, "韦恩图", 5),
      ("balance", "甲有38本书，乙有22本书。\n甲给乙多少本，两人的书就一样多？", .balance, "平均移量图", 8),
      ("cycle", "珠子按红、蓝、绿的顺序重复排列，共14颗。\n有几个完整周期，最后不足一周期的是哪些颜色？", .cycle, "周期图", 4),
    ]
    let selectedIDs = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
    let activeCases = cases.filter { selectedIDs == nil || selectedIDs!.contains($0.0) }
    XCTAssertFalse(activeCases.isEmpty, "Case filter must select at least one known case")
    let photoDirectory = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_PHOTO_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let photoDirectory {
      for item in activeCases {
        let bytes = try Data(contentsOf: photoDirectory.appendingPathComponent(item.0 + ".png"))
        _ = try XCTUnwrap(NSImage(data: bytes), "Every frozen original must exist before any provider call")
      }
    }
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    var report: [[String: Any]] = []
    for (id, stem, expectedKind, methodName, gold) in activeCases {
      let started = Date()
      var selectionElapsed: TimeInterval?
      var selectionSucceeded = false
      var requestSeconds: Double?
      var providerFailure: String?
      var usage: ScreenshotQuestionUsage?
      var selectionFailure = ""
      let automatic = automaticAll || automaticDistribution && id.hasPrefix("surplus-") || automaticRate && id.hasPrefix("rate-")
      let image = NSImage(size: NSSize(width: 1150, height: 240))
      image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1150, height: 240).fill()
      NSAttributedString(string: stem, attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]).draw(in: NSRect(x: 35, y: 45, width: 1080, height: 150))
      image.unlockFocus()
      let photo: Data
      if let photoDirectory {
        photo = try Data(contentsOf: photoDirectory.appendingPathComponent(id + ".png"))
      } else if id == (ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_PHOTO_CASE"] ?? "rate-return"), let path = ProcessInfo.processInfo.environment["MATH_SYSTEM_LIVE_PHOTO"] {
        photo = try Data(contentsOf: URL(fileURLWithPath: path))
      } else {
        photo = try XCTUnwrap(try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))).representation(using: .png, properties: [:]))
      }
      try photo.write(to: destination.appendingPathComponent(id + "-question.png"))
      var calls = 0
      var firstResponseSeconds: TimeInterval?
      var received: [MathDiagram] = []
      var providedExamples: [MathReviewedExampleReference] = []
      var selectedViews: [MathDiagram.Kind] = []
      var select: MathMethodSelection?
      if automatic { select = { question, source, methods in
        let match: MathMethodMatch
        let selectionStarted = Date()
        do {
          match = try await matcher.select(question: question, context: source, methods: methods,
            configuration: configuration, api: selectedAPI, directConnection: directConnection)
        } catch {
          selectionElapsed = Date().timeIntervalSince(selectionStarted)
          if let failure = error as? MathMethodMatchError {
            switch failure {
            case .invalidOutput: selectionFailure = "invalid_output"
            case .catalogueTooLarge: selectionFailure = "catalogue_too_large"
            case .selectionBudgetExceeded: selectionFailure = "selection_budget"
            case .prerequisiteNotSatisfied: selectionFailure = "prerequisite_blocked"
            }
          } else { selectionFailure = "transport_or_protocol" }
          try error.localizedDescription.write(to: destination.appendingPathComponent(id + "-selection-error.txt"), atomically: true, encoding: .utf8)
          XCTFail("Automatic selection failed: \(error.localizedDescription)")
          throw error
        }
        selectionElapsed = Date().timeIntervalSince(selectionStarted)
        selectionSucceeded = true
        if id == "purchase-offers" {
          XCTAssertNotEqual(match.method?.title, "归一与归总", "A price-times-count intermediate step is not a unitary method")
        } else { XCTAssertNotNil(match.method, "Known positive fixtures must select a solution method") }
        if id.hasPrefix("rate-") || id.hasPrefix("surplus-") {
          XCTAssertEqual(match.method?.title, id.hasPrefix("rate-") ? "行程问题" : "盈亏问题")
        }
        selectedViews = ScreenshotQuestionPanel.diagramViews(question, method: match.method, visualMethods: match.visualMethods)
        // Program-owned distribution recipes have a concrete table default even
        // when routing correctly omits an unnecessary separate visual skill.
        if id.hasPrefix("surplus-") { XCTAssertFalse(selectedViews.isEmpty) }
        else if id != "purchase-offers" { XCTAssertFalse(match.visualMethods.isEmpty) }
        try ("\(match.method?.title ?? "none") + \(match.visualMethods.map(\.title).joined(separator: "、"))\n\(match.reason)")
          .write(to: destination.appendingPathComponent(id + "-selection.txt"), atomically: true, encoding: .utf8)
        return match
      } }
      let liveAnswer: ScreenshotQuestionMeasuredAnswer = { question, source, history, recordUsage, partial in
        calls += 1
        try question.write(to: destination.appendingPathComponent("\(id)-prompt-\(calls).txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(source.imageData, photo)
        providedExamples = source.mathReferences.map(\.reference)
        if reviewedSource != nil {
          XCTAssertEqual(source.mathReferences.count, 1, "Live acceptance must actually supply a reviewed original")
          XCTAssertEqual(providedExamples.first?.questionID, "A6DA1825-9CDE-4402-89AA-7210148E983C")
          XCTAssertEqual(providedExamples.first?.scope, "最终答案")
          XCTAssertNotEqual(source.mathReferences.first?.imageData, photo)
        }
        let requestStarted = Date()
        let response: String
        do {
          response = try await client.answer(question: question, context: source, history: history, configuration: configuration, api: selectedAPI, thinking: .off, directConnection: directConnection, onUsage: { usage = $0; recordUsage($0) }, onPartial: { text in
          if firstResponseSeconds == nil && !MathDiagramAnswer.displayText(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstResponseSeconds = Date().timeIntervalSince(started)
          }
          partial(text)
          })
        } catch {
          requestSeconds = Date().timeIntervalSince(requestStarted)
          providerFailure = error.localizedDescription
          var failure: [String:Any] = ["id": id, "calls": calls, "model": configuration.model,
            "thinking": "off", "singleSubmission": singleSubmission, "rendererTools": rendererTools,
            "requestSeconds": requestSeconds as Any, "error": error.localizedDescription]
          failure["engineTimings"] = usage?.engineTimings ?? [:]
          failure["failurePhase"] = usage?.failurePhase as Any? ?? NSNull()
          failure["submissionIssue"] = usage?.failureIssue as Any? ?? NSNull()
          if let diagnostic = usage?.submissionDiagnostic {
            failure["submissionDiagnostic"] = ["tool": diagnostic.tool, "path": diagnostic.path, "rule": diagnostic.rule]
          }
          try JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("\(id)-request-error-\(calls).json"))
          throw error
        }
        requestSeconds = Date().timeIntervalSince(requestStarted)
        try response.write(to: destination.appendingPathComponent("\(id)-response-\(calls).txt"), atomically: true, encoding: .utf8)
        return response
      }
      let panel = ScreenshotQuestionPanel(context: .init(text: "", selectedWord: nil, imageData: photo), answer: { _, _, _, _ in
        XCTFail("Live measurements must forward provider timing callbacks through the measured path")
        return ""
      }, measuredAnswer: liveAnswer, originalImageData: photo, saveQuestion: { try await store.save($0) },
        solutionModel: { configuration.model },
        mathStore: automatic ? store : nil, selectMethodAutomatically: select,
        singlePassAutomaticMethods: singlePass, programArithmetic: programArithmetic, singleSubmissionMath: singleSubmission, rendererToolsMath: rendererTools,
        canUseReviewedMathExamples: { reviewedSource != nil && MathReviewedExample.supportsAutomaticUse(configuration: configuration, api: selectedAPI) })
      panel.present()
      let all = views(try XCTUnwrap(panel.contentView))
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "参考原截图" }).state = .on
      let field = try XCTUnwrap(all.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("例如") == true })
      field.stringValue = automatic ? "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。" : "请用小学知识解题，不用方程；必须画出\(methodName)，解释图中关系并验算。"
      try XCTUnwrap(all.compactMap { $0 as? NSButton }.first { $0.title == "提问" }).performClick(nil)
      for _ in 0..<1800 {
        if !panel.isAnswering { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let answerSeconds = Date().timeIntervalSince(started)
      // The case clock includes generating the fixture image and building the
      // window. The app's monotonic timer starts at the user's actual ask action.
      let userAnswerSeconds = try XCTUnwrap(panel.performance?.elapsed)
      var attachments = 0
      for text in views(try XCTUnwrap(panel.contentView)).compactMap({ $0 as? NSTextView }) {
        text.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, _ in if value is NSTextAttachment { attachments += 1 } }
        XCTAssertFalse(text.string.contains("图解未生成"), "\(id): \(text.string)")
      }
      XCTAssertFalse(panel.isAnswering, id)
      XCTAssertEqual(panel.history.count, 1, id)
      if panel.isAnswering || panel.history.isEmpty {
        // A failed model is part of the comparison denominator. Preserve it
        // and continue to the next independent question, never retry this one.
        report.append(["id": id, "model": configuration.model, "calls": calls,
          "api": selectedAPI.resolved(for: configuration).rawValue,
          "requestSeconds": requestSeconds.map { $0 as Any } ?? NSNull(),
          "userAnswerSeconds": userAnswerSeconds, "configurationResolutionSeconds": configurationSeconds,
          "providerFailure": providerFailure ?? "No completed answer",
          "engineTimings": usage?.engineTimings ?? [:],
          "failurePhase": usage?.failurePhase as Any? ?? NSNull(),
          "submissionIssue": usage?.failureIssue as Any? ?? NSNull(),
          "qualityPassed": false, "speedTargetMet": false, "acceptancePassed": false])
        report[report.count - 1]["preparationSeconds"] = panel.singlePassPreparationDurations
        report[report.count - 1]["latencyBreakdown"] = panel.performance?.breakdown(localDurations: panel.singlePassPreparationDurations) ?? "未记录"
        report[report.count - 1]["enginePrewarmSeconds"] = prewarmSeconds.map { $0 as Any } ?? NSNull()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: destination.appendingPathComponent("report.json"))
        panel.close()
        continue
      }
      try XCTUnwrap(views(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.first { $0.title == "保存题目" }).performClick(nil)
      for _ in 0..<100 {
        if panel.savedQuestionID != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      let savedID = try XCTUnwrap(panel.savedQuestionID)
      let savedSolutions = try await store.solutions(questionID: savedID)
      let saved = try XCTUnwrap(savedSolutions.last)
      if automatic && id == "purchase-offers" {
        XCTAssertNotEqual(saved.method?.title, "归一与归总", "An intermediate unit-price product must not force the primary method")
        if rendererTools { XCTAssertNil(saved.method, "Discount comparison may use a table without adopting a named main method") }
      }
      if automatic && id == "ratio" {
        XCTAssertNotEqual(saved.method?.title, "鸡兔同笼", "A total and ratio of two tree counts are not the heads-and-legs premise")
      }
      received = saved.diagrams
      let originalPhoto = try await store.originalImage(questionID: savedID)
      XCTAssertEqual(originalPhoto, photo)
      XCTAssertEqual(saved.verificationStatus, "unverified")
      XCTAssertEqual(saved.reviewedExamples, providedExamples)
      if reviewedSource != nil {
        XCTAssertTrue(saved.method == nil || saved.method?.title == "差倍问题",
          "A correct general solution may leave the primary method empty; an unrelated method may not be forced")
        XCTAssertFalse(saved.diagrams.flatMap(\.facts).contains { $0.origin == .given && $0.value == 72 },
          "The reference question's difference must never become the current problem's given quantity")
      }
      let records = try await store.list()
      let record = try XCTUnwrap(records.first { $0.id == savedID })
      let pages = try await MathQuestionPDFExporter.export(records: [record], store: store,
        to: destination.appendingPathComponent(id + ".pdf"), options: .init(includeSolutions: true))
      XCTAssertGreaterThan(pages, 1)
      // This simple chained-rate case does not require a diagram. Keep the
      // drawing-family gates strict for all existing drawing fixtures.
      let simpleFee = id == "property-fee"
      let feeTextCorrect = saved.answer.contains("115×2=230") && saved.answer.contains("230×12=2760")
        && saved.answer.contains("2760÷12=230") && saved.answer.contains("230÷2=115")
      if !simpleFee { XCTAssertGreaterThan(attachments, 0, id) }
      // In automatic mode the user did not demand a rectangle. Comparing the
      // length and width is useful for a sum/difference rectangle problem; the
      // independently derived area is still required below. Explicit requests
      // retain their exact-kind gate.
      let acceptedKinds: [MathDiagram.Kind]
      if automatic && id == "area" { acceptedKinds = [.area, .barComparison] }
      else if automatic && id.hasPrefix("surplus-") { acceptedKinds = [.table, .barComparison] }
      else { acceptedKinds = [expectedKind] }
      if simpleFee {
        XCTAssertTrue(feeTextCorrect, "Property fee must show both products and reverse checks")
        XCTAssertNil(saved.method, "A simple chained product need not force an existing primary method")
      } else {
        XCTAssertTrue(received.contains { automatic && !selectedViews.isEmpty ? selectedViews.contains($0.kind) : acceptedKinds.contains($0.kind) }, "\(id): actual \(received.map(\.kind))")
        XCTAssertTrue(received.flatMap(\.facts).contains { $0.origin == .derived && $0.value.map { abs($0 - gold) < 0.000001 } == true }, "\(id): missing independently computed \(gold)")
      }
      if id == "purchase-offers" {
        XCTAssertEqual(calls, 1, "No automatic diagram repair round")
        XCTAssertTrue(received.contains { $0.kind == .table })
        for value in [2505.0, 2616.0, 111.0] {
          XCTAssertTrue(received.flatMap(\.facts).contains { $0.origin == .derived && $0.unit == "元" && $0.value == value }, "Offer table must derive payment and difference")
        }
      }
      if id == "rate-return" {
        for diagram in received {
          for fact in diagram.facts where [630.0, 31.5, 52.5, 7.5].contains(fact.value ?? .nan) {
            XCTAssertEqual(fact.origin, .derived, "\(id): every diagram must derive calculated quantities, never relabel them as original problem facts")
          }
        }
        XCTAssertTrue(received.flatMap(\.facts).contains { $0.origin == .derived && $0.value == 630 && ["米", "m"].contains($0.unit) }, "Same-distance comparison must show 630 metres with cancelled time units")
        XCTAssertTrue(received.contains { $0.kind == .table || $0.kind == .partWhole || $0.kind == .barComparison }, "Return deadline needs a comparison or time diagram")
        for value in [52.5, 7.5] {
          XCTAssertTrue(received.flatMap(\.facts).contains { $0.origin == .derived && $0.value == value && ["分钟", "分", "min"].contains($0.unit) }, "Return deadline must display total and excess time, missing \(value)")
        }
        if automatic { XCTAssertFalse(selectedViews.contains(.area), "Ordinary return deadline should not select a product rectangle") }
      }
      if id.hasPrefix("surplus-") {
        let count = id == "surplus-recipients" ? 25.0 : 30.0
        XCTAssertTrue(received.flatMap(\.facts).contains { $0.origin == .derived && $0.unit == "人" && $0.value == count }, "\(id): missing computed student count")
      }
      for (index, diagram) in received.enumerated() { try MathDiagramRenderer.renderPNG(diagram).write(to: destination.appendingPathComponent("\(id)-diagram-\(index).png")) }
      let view = try XCTUnwrap(panel.contentView), capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: capture)
      try XCTUnwrap(capture.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(id + "-panel.png"))
      if singlePass {
        XCTAssertNil(selectionElapsed, "No separate routing provider request")
        XCTAssertEqual(calls, 1, "Single-pass must not add automatic repair")
        XCTAssertLessThanOrEqual(userAnswerSeconds, 5, "Entire answer after the user's ask action must meet the 3–5 second requirement")
      }
      report.append(["id": id, "expectedKind": expectedKind.rawValue, "calls": calls, "attachments": attachments, "kinds": received.map { $0.kind.rawValue }, "gold": gold, "automatic": automatic, "singlePass": singlePass, "selectionSucceeded": selectionSucceeded, "selectionFailure": saved.selectionFailure ?? selectionFailure, "selectionSeconds": selectionElapsed.map { $0 as Any } ?? NSNull(), "enginePrewarmSeconds": prewarmSeconds.map { $0 as Any } ?? NSNull(), "firstResponseSeconds": firstResponseSeconds.map { $0 as Any } ?? NSNull(), "answerSeconds": answerSeconds, "totalSeconds": Date().timeIntervalSince(started), "partialFailure": saved.diagramFailure ?? ""])
      report[report.count - 1]["providedReviewedExamples"] = providedExamples.map {
        ["question_id": $0.questionID, "solution_id": $0.solutionID, "review_id": $0.reviewID, "scope": $0.scope]
      }
      report[report.count - 1]["requestSeconds"] = requestSeconds.map { $0 as Any } ?? NSNull()
      report[report.count - 1]["userAnswerSeconds"] = userAnswerSeconds
      report[report.count - 1]["singleSubmission"] = singleSubmission
      report[report.count - 1]["rendererTools"] = rendererTools
      report[report.count - 1]["model"] = configuration.model
      report[report.count - 1]["thinking"] = "off"
      report[report.count - 1]["configurationResolutionSeconds"] = configurationSeconds
      report[report.count - 1]["api"] = selectedAPI.resolved(for: configuration).rawValue
      report[report.count - 1]["primaryMethod"] = saved.method?.title as Any? ?? NSNull()
      report[report.count - 1]["visualMethods"] = saved.visualMethods.map(\.title)
      report[report.count - 1]["preparationSeconds"] = panel.singlePassPreparationDurations
      report[report.count - 1]["latencyBreakdown"] = panel.performance?.breakdown(localDurations: panel.singlePassPreparationDurations) ?? "未记录"
      report[report.count - 1]["firstVisibleResponseSeconds"] = singlePass && programArithmetic
        ? userAnswerSeconds : panel.performance?.firstTokenLatency.map { $0 as Any } ?? NSNull()
      report[report.count - 1]["engineTimings"] = usage?.engineTimings ?? [:]
      report[report.count - 1]["inputTokens"] = usage?.inputTokens.map { $0 as Any } ?? NSNull()
      report[report.count - 1]["outputTokens"] = usage?.outputTokens.map { $0 as Any } ?? NSNull()
      report[report.count - 1]["reasoningTokens"] = usage?.reasoningTokens.map { $0 as Any } ?? NSNull()
      var qualityChecks: [String: Bool] = [
        "one_request": calls == 1,
        "visible_diagram": attachments > 0,
        "expected_diagram_kind": received.contains { acceptedKinds.contains($0.kind) },
        "independently_computed_gold": received.flatMap(\.facts).contains {
          $0.origin == .derived && $0.value.map { abs($0 - gold) < 0.000001 } == true
        },
        "original_bytes_preserved": originalPhoto == photo,
        "answer_remains_unverified": saved.verificationStatus == "unverified",
        "no_diagram_failure": saved.diagramFailure == nil,
        "no_selection_failure": saved.selectionFailure == nil,
        "pdf_exported": pages > 1,
        "no_forced_unitary_method": id != "purchase-offers" || saved.method == nil
      ]
      if simpleFee {
        qualityChecks.removeValue(forKey: "visible_diagram")
        qualityChecks.removeValue(forKey: "expected_diagram_kind")
        qualityChecks.removeValue(forKey: "independently_computed_gold")
        qualityChecks["both_products_and_reverse_checks"] = feeTextCorrect && 115 * 2 * 12 == Int(gold)
        qualityChecks["no_forced_primary_method"] = saved.method == nil
        qualityChecks["diagram_or_explicit_omission_reason"] = !received.isEmpty || saved.answer.contains("画图对理解帮助不大")
      }
      if reviewedSource != nil {
        qualityChecks["reviewed_source_supplied_and_persisted"] = providedExamples.count == 1
          && providedExamples.first?.questionID == "A6DA1825-9CDE-4402-89AA-7210148E983C"
          && providedExamples.first?.reviewID == "C8CE3FBD-1CBD-4F81-A154-892D7B7C37A1"
          && saved.reviewedExamples == providedExamples
        qualityChecks["review_scope_not_promoted"] = providedExamples.first?.scope == "最终答案"
        qualityChecks["no_inapplicable_primary_method"] = saved.method == nil || saved.method?.title == "差倍问题"
        qualityChecks["no_old_difference_as_given"] = !received.flatMap(\.facts).contains {
          $0.origin == .given && $0.value == 72
        }
      }
      report[report.count - 1]["qualityChecks"] = qualityChecks
      XCTAssertTrue(qualityChecks.values.allSatisfy { $0 }, "\(id): quality gate failed: \(qualityChecks.filter { !$0.value }.keys.sorted())")
      report[report.count - 1]["qualityPassed"] = qualityChecks.values.allSatisfy { $0 }
      report[report.count - 1]["speedTargetMet"] = userAnswerSeconds <= 5
      report[report.count - 1]["acceptancePassed"] = qualityChecks.values.allSatisfy { $0 } && userAnswerSeconds <= 5
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("report.json"))
      print("Live system: \(id), calls \(calls), attachments \(attachments), kinds \(received.map(\.kind))")
      panel.close()
    }
    await store.close()
    await client.shutdown()
  }
}
