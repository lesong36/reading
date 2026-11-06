import AppKit
import Foundation
import XCTest
@testable import VocabCapture

/// Uses the normal configured model and anonymous protocol, entirely isolated from user records.
@MainActor
final class MathSkillProfileResearchLiveTests: XCTestCase {
  func testActualModelExistingMethodResearchArchiveAndWindow() async throws {
    guard let output = ProcessInfo.processInfo.environment["MATH_PROFILE_LIVE_ARTIFACTS"] else {
      throw XCTSkip("Set MATH_PROFILE_LIVE_ARTIFACTS for actual existing-method teaching review")
    }
    let destination = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let engine = package.appendingPathComponent("question-engine")
    let transport: LangChainQuestionTransport
    if let path = ProcessInfo.processInfo.environment["MATH_PROFILE_LIVE_ENGINE"] {
      transport = .init(executableURL: URL(fileURLWithPath: path))
    } else {
      transport = .init(executableURL: engine.appendingPathComponent(".venv/bin/python"), arguments: [engine.appendingPathComponent("question_engine.py").path])
    }
    let client = ScreenshotQuestionClient(langChain: transport)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.coty.vocab-capture"))
    let preferences = ScreenshotQuestionPreferences(defaults: defaults)
    var fallback = defaults.data(forKey: "VocabCapture.aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) }
      ?? .init(baseURL: "", model: "", apiKey: "")
    fallback.apiKey = KeychainStore.readAPIKey()
    let model = MathTagModelConfiguration(configuration: preferences.configuration(fallingBackTo: fallback),
      api: preferences.selectedAPI, directConnection: preferences.selectedDirectConnection)
    let store = MathQuestionStore(directory: destination.appendingPathComponent("isolated-library"))
    _ = try await store.importBundledMathSkills(MathSkillCatalogue.load())
    let methods = try await store.methods()
    let coordinator = MathSkillProfileResearchCoordinator(store: store, configuration: { model }, analyze: { data, image, methods, model in
      XCTAssertTrue(image.isEmpty, "Project method review has no unrelated problem photo")
      return try await client.learnSkills(learning: data, imageData: image, methods: methods,
        configuration: model.configuration, api: model.api, directConnection: model.directConnection)
    })
    var report: [[String: Any]] = []
    for title in ["和差问题", "盈亏问题"] {
      let method = try XCTUnwrap(methods.first { $0.title == title })
      let before = try await store.automaticMethods()
      try await coordinator.review(method: method)
      let archives = try await store.profileResearchArchives(versionID: method.versionID)
      let archive = try XCTUnwrap(archives.last)
      XCTAssertEqual(archive.result.mode, "profile_review")
      XCTAssertEqual(archive.result.review.checks.count, 5)
      XCTAssertTrue(["awaiting_human", "review_required"].contains(archive.result.status))
      let after = try await store.automaticMethods()
      XCTAssertEqual(before, after, "AI evaluation cannot approve, revoke or rewrite a method")
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      try encoder.encode(archive).write(to: destination.appendingPathComponent(method.id + "-review.json"))
      let panel = MathSkillProfilePanel(store: store, method: method, research: { try await coordinator.review(method: $0) })
      panel.present()
      try await Task.sleep(nanoseconds: 250_000_000)
      let content = try XCTUnwrap(panel.panel.contentView)
      content.layoutSubtreeIfNeeded()
      func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
      let labels = views(content).compactMap { $0 as? NSTextView }.map(\.string).joined(separator: "\n")
      XCTAssertTrue(labels.contains("数学正确性"))
      XCTAssertTrue(labels.contains("尚未批准") || labels.contains("需补充"))
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(method.id + "-panel.png"))
      panel.panel.close()
      report.append(["method": title, "model_calls": archive.result.modelCalls, "status": archive.result.status,
        "checks": archive.result.review.checks.map { ["dimension": $0.dimension, "passed": $0.passed] }, "human_approved": false])
    }
    let backup = destination.appendingPathComponent("backup")
    try await store.backup(to: backup)
    await store.close()
    let restored = MathQuestionStore(directory: destination.appendingPathComponent("restored-library"))
    _ = try await restored.restoreBackup(from: backup)
    for method in methods.filter({ ["和差问题", "盈亏问题"].contains($0.title) }) {
      let archives = try await restored.profileResearchArchives(versionID: method.versionID)
      XCTAssertEqual(archives.count, 1)
    }
    await restored.close()
    await client.shutdown()
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("report.json"))
  }

  func testEnglishOCRRemainsIndependentOfChineseIndexing() async throws {
    let image = NSImage(size: NSSize(width: 1100, height: 190))
    image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1100, height: 190).fill()
    NSAttributedString(string: "Streaming is crucial for reading comprehension.", attributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
      .draw(in: NSRect(x: 30, y: 65, width: 1040, height: 65))
    image.unlockFocus()
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    let cg = try XCTUnwrap(bitmap.cgImage)
    let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let before = try await OCRClient.recognize(cg)
    _ = try await MathQuestionIndexer.recognize(bytes)
    let after = try await OCRClient.recognize(cg)
    XCTAssertEqual(before, after)
    XCTAssertTrue(after.contains("Streaming is crucial for reading comprehension."))
  }
}
