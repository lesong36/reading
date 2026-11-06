import AppKit
import XCTest
@testable import VocabCapture

final class MathSkillProfileTests: XCTestCase {
  func testOversizedOriginalProfileRevisionFailsWithoutTruncatingOrChangingCurrentVersion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let method = try await store.saveMethod(title: "完整来源", category: "四年级", instructions: String(repeating: "原", count: 32_001))
    let profile = MathSkillProfile(versionID: method.versionID, trigger: "数量相同", constraints: "算术", exclusions: "条件不足", prerequisites: "整数乘除", supportedDiagrams: [])
    do { _ = try await store.saveSkillProfileRevision(method: method, profile: profile); XCTFail("Cannot save a profile with an unrestorable original") } catch {}
    let current = try await store.methods()
    XCTAssertEqual(current, [method])
    let saved = try await store.skillProfile(versionID: method.versionID)
    XCTAssertNil(saved)
    await store.close()
  }
  func testBundledTeachingMaterialIsExactVersionBoundAndDoesNotCertifyUserEdits() throws {
    let catalogue = try MathSkillCatalogue.load()
    let research = try MathTeachingReviewCatalogue.load()
    XCTAssertEqual(research.profiles.count, catalogue.skills.count)
    XCTAssertGreaterThanOrEqual(research.cases.count, 103)
    for skill in catalogue.skills {
      let method = MathTeachingMethod(id: skill.sourceID, versionID: UUID().uuidString,
        title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
      let seed = try XCTUnwrap(research.seed(for: method))
      XCTAssertEqual(seed.status, "draft")
      XCTAssertEqual(seed.sourceInstructions, method.instructions)
      XCTAssertFalse(seed.trigger.isEmpty)
      XCTAssertFalse(seed.exclusions.isEmpty)
      XCTAssertTrue(research.evidenceText(for: method).contains(skill.sha256))
      let changed = MathTeachingMethod(id: method.id, versionID: UUID().uuidString,
        title: method.title, category: method.category, instructions: method.instructions + "用户修改", createdAt: Date())
      XCTAssertNil(research.seed(for: changed))
    }
  }

  func testProfileRevisionPreservesSourceAndOldApprovalAndRequiresFreshExplicitReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let original = try await store.saveMethod(title: "盈亏", category: "四年级", instructions: "原始步骤全文，不作删减。")
    let draft = MathSkillProfile(versionID: original.versionID, trigger: "两次分配数量相同", constraints: "用四则算术",
      exclusions: "人数改变不适用", prerequisites: "整数乘除", supportedDiagrams: ["table"])
    let first = try await store.saveSkillProfileRevision(method: original, profile: draft)
    XCTAssertNotEqual(first.versionID, original.versionID)
    var automatic = try await store.automaticMethods()
    XCTAssertFalse(automatic.contains { $0.id == first.id })
    try await store.reviewCurrentSkillProfile(method: first, approved: true, note: "核对两道正例与排除反例及四年级步骤")
    automatic = try await store.automaticMethods()
    XCTAssertTrue(automatic.contains(first))
    let storedProfile = try await store.skillProfile(versionID: first.versionID)
    var edit = try XCTUnwrap(storedProfile)
    edit.exclusions = "人数改变或纸张总数不同均不适用"
    do { try await store.saveSkillProfile(profile: edit); XCTFail("Cannot overwrite immutable reviewed material") } catch {}
    let second = try await store.saveSkillProfileRevision(method: first, profile: edit)
    XCTAssertEqual(second.instructions.components(separatedBy: "原始步骤全文").count, 2)
    let old = try await store.skillProfile(versionID: first.versionID)
    XCTAssertEqual(old?.status, "approved")
    XCTAssertEqual(old?.exclusions, draft.exclusions)
    XCTAssertEqual(old?.sourceInstructions, original.instructions)
    automatic = try await store.automaticMethods()
    XCTAssertFalse(automatic.contains { $0.id == second.id })
    do { try await store.reviewCurrentSkillProfile(method: first, approved: true, note: "旧窗口"); XCTFail("Stale UI cannot review current method") } catch {}
    try await store.reviewCurrentSkillProfile(method: second, approved: true, note: "重新核对新增边界")
    try await store.revokeCurrentSkillMethod(method: second, note: "真实反例有误，停止自动复用")
    automatic = try await store.automaticMethods()
    XCTAssertFalse(automatic.contains { $0.id == second.id })
    let history = try await store.skillLifecycleEvents(versionID: second.versionID)
    XCTAssertEqual(history.map(\.decision), ["draft", "approved", "revoked"])
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    await store.close()
    let restored = MathQuestionStore(directory: root.appendingPathComponent("restored"))
    _ = try await restored.restoreBackup(from: backup)
    let preserved = try await restored.skillProfile(versionID: first.versionID)
    XCTAssertEqual(preserved, old)
    let restoredHistory = try await restored.skillLifecycleEvents(versionID: second.versionID)
    XCTAssertEqual(restoredHistory, history)
    await restored.close()
  }
}

@MainActor
final class MathSkillProfileUITests: XCTestCase {
  func testExistingMethodProfileEntryAndRealWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first)
    _ = try await store.importMethods([.init(sourceID: skill.sourceID, title: skill.title, category: skill.category, instructions: skill.instructions)])
    let methods = try await store.methods()
    let method = try XCTUnwrap(methods.first)
    let editor = MathMethodSettings(store: store)
    XCTAssertTrue(buttons(editor.panel.contentView).contains { $0.title == "教研档案…" })
    let profile = MathSkillProfilePanel(store: store, method: method)
    profile.present()
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(Set(buttons(profile.panel.contentView).filter { !($0 is NSPopUpButton) }.map(\.title)), ["保存新版本草稿", "人工确认并启用", "需重新审校", "撤销自动使用", "自动五项教研"])
    if let path = ProcessInfo.processInfo.environment["MATH_SKILL_PROFILE_SNAPSHOT"] {
      profile.panel.setContentSize(NSSize(width: 800, height: 830))
      profile.panel.bringToFront()
      try await Task.sleep(nanoseconds: 200_000_000)
      let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-l", String(profile.panel.windowNumber), path]
      try capture.run(); capture.waitUntilExit()
      XCTAssertEqual(capture.terminationStatus, 0)
    }
    let actions = buttons(profile.panel.contentView)
    let save = try XCTUnwrap(actions.first { $0.title == "保存新版本草稿" })
    let approve = try XCTUnwrap(actions.first { $0.title == "人工确认并启用" })
    approve.performClick(nil)
    let initial = try await store.automaticMethods()
    XCTAssertTrue(initial.contains(method), "Viewing pending source material does not revoke existing user methods")
    save.performClick(nil)
    var revised: MathTeachingMethod?
    for _ in 0..<100 {
      revised = try await store.methods().first
      if revised?.versionID != method.versionID, save.isEnabled { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let current = try XCTUnwrap(revised)
    XCTAssertNotEqual(current.versionID, method.versionID)
    let pending = try await store.automaticMethods()
    XCTAssertFalse(pending.contains { $0.id == method.id })
    let fields = descendants(profile.panel.contentView).compactMap { $0 as? NSTextField }
    let reason = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "方法人工审校依据" })
    reason.stringValue = "核对题内数量、正反例以及四年级适用范围"
    approve.performClick(nil)
    var approved: MathSkillProfile?
    for _ in 0..<100 {
      approved = try await store.skillProfile(versionID: current.versionID)
      if approved?.status == "approved" { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(approved?.status, "approved", "Explicit UI review certifies only the saved current version")
    await profile.prepareForLibraryRestore()
    await editor.prepareForLibraryRestore()
    await store.close()
  }
  private func buttons(_ view: NSView?) -> [NSButton] {
    guard let view else { return [] }
    return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
  }
  private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { descendants($0) }
  }
}
