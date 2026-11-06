import CSQLite
import Foundation
import XCTest
@testable import VocabCapture

final class MathSkillProjectSyncAuditTests: XCTestCase {
  private func artifact() throws -> MathSkillProjectArtifact {
    try MathSkillProjectArtifact(snapshot: .init(method: .init(id: "isolated-method", versionID: "isolated-version",
      title: "比较共同量", category: "整数", instructions: "先比较共同量。[[辅助方法|单位检查]]", createdAt: Date(timeIntervalSinceReferenceDate: 123)),
      profile: nil, versionOrdinal: 1, automaticEligible: false, candidateID: nil, lifecycle: []))
  }

  func testArtifactRoundTripAndStandardSchema() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-artifact-audit-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = try artifact()
    do { try value.write(to: root) } catch {
      let destination = root.appendingPathComponent(value.relativePath, isDirectory: true)
      let urls = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
      let actual = urls.compactMap { url -> String? in
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url.path
      }
      XCTFail("Artifact round trip failed: \(error); directory=\(destination.path); expected=\(value.files.keys.sorted()); actual=\(actual.sorted())")
      return
    }
    let destination = root.appendingPathComponent(value.relativePath)
    try value.verify(at: destination)
    XCTAssertEqual(try artifact().sha256, value.sha256)
    XCTAssertEqual(try MathSkillCatalogue(directory: destination).skills.count, 1)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [source.appendingPathComponent("scripts/validate-math-skills.py").path, destination.path]
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  func testUserIndexAndInterruptedChecksumArePreserved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-index-audit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data("original generated index".utf8)
    let updated = Data("updated generated index".utf8)
    try MathSkillProjectSyncFiles.writeIndex(original, project: root)
    try MathSkillProjectSyncFiles.writeIndex(updated, project: root)
    let index = root.appendingPathComponent("MathSkills/Local/index.json")
    let modified = Data("user modified index".utf8)
    try modified.write(to: index)
    XCTAssertThrowsError(try MathSkillProjectSyncFiles.writeIndex(original, project: root))
    XCTAssertEqual(try Data(contentsOf: index), modified)
    // Simulates a crash after index replacement and before checksum replacement.
    try original.write(to: index)
    XCTAssertThrowsError(try MathSkillProjectSyncFiles.writeIndex(updated, project: root))
    XCTAssertEqual(try Data(contentsOf: index), original)
  }

  func testArtifactRejectsUnexpectedFilesAndLinkedResources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-resource-audit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let value = try artifact(); try value.write(to: root)
    let destination = root.appendingPathComponent(value.relativePath)
    let extra = destination.appendingPathComponent("personal-note.md")
    try Data("preserve user data".utf8).write(to: extra)
    XCTAssertThrowsError(try value.write(to: root))
    XCTAssertEqual(try Data(contentsOf: extra), Data("preserve user data".utf8))
    try FileManager.default.removeItem(at: extra)
    let source = destination.appendingPathComponent(value.name + "/references/source.md")
    let outside = root.appendingPathComponent("outside.md")
    try Data("outside user resource".utf8).write(to: outside)
    try FileManager.default.removeItem(at: source)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
    XCTAssertThrowsError(try value.write(to: root))
    XCTAssertEqual(try Data(contentsOf: outside), Data("outside user resource".utf8))
  }

  func testReceiptRejectsInvalidVersionPathsAndApprovalStates() throws {
    let value = try artifact()
    let valid = MathSkillProjectSyncReceipt(schemaVersion: 1, methodID: value.snapshot.method.id,
      versionID: value.snapshot.method.versionID, projectDirectory: "/Users/isolated/project",
      relativePath: value.relativePath, artifactSHA256: value.sha256, status: "synced", error: "",
      createdAt: Date(timeIntervalSinceReferenceDate: 123))
    try valid.validate()
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String:Any]
    let mutations: [(String, Any)] = [("schemaVersion", 2), ("methodID", ""), ("versionID", "different-version"),
      ("projectDirectory", "relative/project"), ("projectDirectory", "/Users/isolated/../project"),
      ("relativePath", "MathSkills/Local/../../unsafe"), ("artifactSHA256", String(repeating: "F", count: 64)),
      ("status", "approved"), ("error", "failed but marked success"), ("relativePath", "")]
    for (key, mutation) in mutations {
      var object = json; object[key] = mutation
      let receipt = try JSONDecoder().decode(MathSkillProjectSyncReceipt.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertThrowsError(try receipt.validate(), "Invalid receipt field \(key)=\(mutation)")
    }
  }

  func testBackupRejectsCrossMethodForgedSyncReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-receipt-backup-audit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root.appendingPathComponent("library"))
    _ = try await store.saveMethod(title: "用户方法", category: "算术", instructions: "先统一单位，再比较共同量。")
    let snapshots = try await store.projectSkillSnapshots()
    let snapshot = try XCTUnwrap(snapshots.first)
    let value = try MathSkillProjectArtifact(snapshot: snapshot)
    let receipt = MathSkillProjectSyncReceipt(schemaVersion: 1, methodID: snapshot.method.id,
      versionID: snapshot.method.versionID, projectDirectory: "/Users/isolated/project",
      relativePath: value.relativePath, artifactSHA256: value.sha256, status: "synced", error: "", createdAt: Date())
    try await store.recordProjectSkillSync(receipt, snapshot: snapshot)
    let backup = root.appendingPathComponent("backup")
    try await store.backup(to: backup); await store.close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("questions.sqlite").path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle); defer { sqlite3_close(db) }
    _ = try MathQuestionArchive.validate(db)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String:Any]
    object["methodID"] = "unrelated-method"
    let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    XCTAssertEqual(sqlite3_exec(db, "UPDATE skill_lifecycle_events SET note='\(text)' WHERE decision='project_sync'", nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try MathQuestionArchive.validate(db), "Receipt may not bind a different method identity")
  }

  func testEveryBundledMethodCanBeArchivedAsStandardStandaloneSkill() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-bundled-archive-audit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalogue = try MathSkillCatalogue.load()
    XCTAssertGreaterThanOrEqual(catalogue.skills.count, 49)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for definition in catalogue.skills {
      let method = MathTeachingMethod(id: definition.sourceID, versionID: "isolated-" + definition.name,
        title: definition.title, category: definition.category, instructions: definition.instructions,
        createdAt: Date(timeIntervalSinceReferenceDate: 123))
      let value = try MathSkillProjectArtifact(snapshot: .init(method: method, profile: nil, versionOrdinal: 1,
        automaticEligible: true, candidateID: nil, lifecycle: []))
      try value.write(to: root)
      let destination = root.appendingPathComponent(value.relativePath)
      XCTAssertEqual(try MathSkillCatalogue(directory: destination).skills.count, 1)
      let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [source.appendingPathComponent("scripts/validate-math-skills.py").path, destination.path]
      let output = Pipe(); process.standardOutput = output; process.standardError = output
      try process.run(); process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, definition.name + ": " + String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
      let retained = try JSONDecoder().decode(MathTeachingMethod.self, from: Data(contentsOf: destination.appendingPathComponent(value.name + "/references/method.json")))
      XCTAssertEqual(retained, method)
    }
  }
}
