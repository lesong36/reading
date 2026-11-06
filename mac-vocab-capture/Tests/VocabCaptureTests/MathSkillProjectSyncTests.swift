import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

@MainActor
final class MathSkillProjectSyncTests: XCTestCase {
  func testAllVersionsAreProjectSkillsAndRestartVerifiesFilesWithoutDuplicatingReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-skill-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let suite = "test-project-skills-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = try await store.saveMethod(title: "完整用户方法", category: "整数", instructions: "先找到共同量，再用整数四则比较。\n[[别的方法|共用量比较]]")
    let method = try await store.saveMethod(id: original.id, title: original.title, category: original.category,
      instructions: original.instructions + "\n检查单位。", teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    try await store.reviewCurrentSkillProfile(method: method, approved: true, note: "隔离测试人工批准，不涉及生产数据")
    let coordinator = MathSkillProjectSyncCoordinator(store: store, defaults: defaults)
    try coordinator.selectProject(project)
    await coordinator.synchronize()
    XCTAssertTrue(coordinator.status.hasPrefix("已核对并同步 2"), coordinator.status)
    let snapshots = try await store.projectSkillSnapshots()
    XCTAssertEqual(snapshots.count, 2)
    for snapshot in snapshots {
      let artifact = try MathSkillProjectArtifact(snapshot: snapshot)
      let path = project.appendingPathComponent(artifact.relativePath)
      try artifact.verify(at: path)
      let parsed = try MathSkillCatalogue(directory: path)
      XCTAssertEqual(parsed.skills.count, 1)
      XCTAssertTrue(parsed.skills[0].instructions.contains("共用量比较"))
      XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent(artifact.name + "/references/source.md")), Data((snapshot.profile?.sourceInstructions ?? snapshot.method.instructions).utf8))
    }
    let receipts = try await store.skillLifecycleEvents(versionID: method.versionID).filter { $0.decision == "project_sync" }
    XCTAssertEqual(receipts.count, 1)
    let second = MathSkillProjectSyncCoordinator(store: store, defaults: defaults)
    await second.synchronize()
    let again = try await store.skillLifecycleEvents(versionID: method.versionID).filter { $0.decision == "project_sync" }
    XCTAssertEqual(again.count, 1)
    let current = try XCTUnwrap(snapshots.first { $0.method.versionID == method.versionID })
    let artifact = try MathSkillProjectArtifact(snapshot: current)
    let file = project.appendingPathComponent(artifact.relativePath).appendingPathComponent(artifact.name + "/SKILL.md")
    try Data("user modification".utf8).write(to: file)
    await second.synchronize()
    XCTAssertTrue(second.status.contains("待修复"), second.status)
    XCTAssertEqual(try String(contentsOf: file), "user modification")
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup)
    await store.close()
    let restored = MathQuestionStore(directory: root.appendingPathComponent("restored"))
    _ = try await restored.restoreBackup(from: backup)
    let history = try await restored.skillLifecycleEvents(versionID: method.versionID)
    XCTAssertEqual(history.filter { $0.decision == "project_sync" }.count, 2)
    await restored.close()
  }

  func testRevocationChangesCurrentIndexButPreservesHistoricalSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-revoke-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    let method = try await store.saveMethod(title: "用户算术", category: "整数", instructions: "先检查单位，再按同量比较。",
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    try await store.reviewCurrentSkillProfile(method: method, approved: true, note: "隔离测试")
    let suite = "test-project-revoke-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let sync = MathSkillProjectSyncCoordinator(store: store, defaults: defaults)
    try sync.selectProject(root); await sync.synchronize()
    let beforeRevocation = try await store.projectSkillSnapshots()
    let old = try XCTUnwrap(beforeRevocation.first)
    let oldArtifact = try MathSkillProjectArtifact(snapshot: old)
    XCTAssertTrue(old.automaticEligible)
    try await store.revokeCurrentSkillMethod(method: method, note: "发现边界反例")
    await sync.synchronize()
    try oldArtifact.verify(at: root.appendingPathComponent(oldArtifact.relativePath))
    let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("MathSkills/Local/index.json"))) as! [String:Any]
    let entries = index["snapshots"] as! [[String:Any]]
    XCTAssertEqual(entries.first?["automatic_eligible"] as? Bool, false)
    XCTAssertNotEqual(entries.first?["artifact_sha256"] as? String, oldArtifact.sha256)
    await store.close()
  }

  func testUnsafeAndUnownedProjectPathsAreNotOverwritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-path-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("MathSkills/Local")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let user = local.appendingPathComponent("SKILL.md")
    try Data("owned by user".utf8).write(to: user)
    XCTAssertThrowsError(try MathSkillProjectSyncFiles.ensureManagedRoot(project: root))
    XCTAssertEqual(try String(contentsOf: user), "owned by user")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
    XCTAssertThrowsError(try MathSkillProjectSyncFiles.requireDirectory(link))
  }
}
