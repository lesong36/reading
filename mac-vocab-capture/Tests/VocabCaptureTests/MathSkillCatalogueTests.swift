import CryptoKit
import Foundation
import XCTest

@testable import VocabCapture

final class MathSkillCatalogueTests: XCTestCase {
  private let body = "# 和差问题\n\n先画线段图，再用和与差求两数。\n"
  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func fixture(aliases: [String] = []) throws -> URL {
    let root = try temporaryDirectory()
    let folder = root.appendingPathComponent("sum-difference")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let header = """
      ---
      name: "sum-difference"
      description: "当已知两数的和与差时使用，先画线段图。"
      metadata:
        title: "和差问题"
        category: "应用题"
        version: "1"
        schema_version: "1.0"
        source_file: "和差问题.md"
        source_sha256: "\(digest(Data(body.utf8)))"
        legacy_source_id: "markdown-sum"
      ---

      """
    let data = Data((header + body).utf8)
    try data.write(to: folder.appendingPathComponent("SKILL.md"))
    let entry: [String: Any] = [
      "name": "sum-difference", "title": "和差问题", "category": "应用题",
      "version": "1", "source_id": "markdown-sum", "description": "当已知两数的和与差时使用，先画线段图。",
      "sha256": digest(data), "path": "sum-difference/SKILL.md", "legacy_alias_ids": aliases,
    ]
    try JSONSerialization.data(withJSONObject: ["schema_version": 1, "skills": [entry]])
      .write(to: root.appendingPathComponent("index.json"))
    return root
  }
  private func changeManifest(_ root: URL, mutation: (inout [String: Any]) -> Void) throws {
    let url = root.appendingPathComponent("index.json")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    mutation(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }
  private func changeEntry(_ root: URL, mutation: (inout [String: Any]) -> Void) throws {
    try changeManifest(root) { object in
      var entries = object["skills"] as! [[String: Any]]
      mutation(&entries[0])
      object["skills"] = entries
    }
  }

  func testExactBodyMetadataAndAliasResolution() throws {
    let catalogue = try MathSkillCatalogue(directory: fixture(aliases: ["old-user-method"]))
    XCTAssertEqual(catalogue.skills.first?.instructions, body)
    XCTAssertEqual(try catalogue.importEntries().first?.sourceID, "markdown-sum")
    XCTAssertEqual(
      try catalogue.importEntries(existingIDs: ["old-user-method"]).first?.sourceID,
      "old-user-method")
    XCTAssertThrowsError(
      try catalogue.importEntries(existingIDs: ["old-user-method", "markdown-sum"]))
    let method = MathTeachingMethod(
      id: "old-user-method", versionID: "v1", title: "和差问题",
      category: "应用题", instructions: body, createdAt: Date())
    XCTAssertEqual(catalogue.discoveryMetadata(for: method)?.name, "sum-difference")
    let edited = MathTeachingMethod(
      id: method.id, versionID: "v2", title: method.title,
      category: method.category, instructions: "用户编辑内容", createdAt: Date())
    XCTAssertNil(catalogue.discoveryMetadata(for: edited))
  }

  func testRejectsTamperedFileHashAndMetadata() throws {
    let root = try fixture()
    let file = root.appendingPathComponent("sum-difference/SKILL.md")
    var bytes = try Data(contentsOf: file)
    bytes.append(Data("篡改".utf8))
    try bytes.write(to: file)
    XCTAssertThrowsError(try MathSkillCatalogue(directory: root))
    try changeEntry(root) { $0["sha256"] = digest(bytes) }
    XCTAssertThrowsError(
      try MathSkillCatalogue(directory: root), "Source body hash still prevents tampering")
  }

  func testRejectsTraversalDuplicateIdentityUnsupportedSchemaAndSymlink() throws {
    let traversal = try fixture()
    try changeEntry(traversal) { $0["path"] = "../SKILL.md" }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: traversal))
    let duplicate = try fixture(aliases: ["markdown-sum"])
    XCTAssertThrowsError(try MathSkillCatalogue(directory: duplicate))
    let duplicateNames = try fixture()
    try changeManifest(duplicateNames) { object in
      let entries = object["skills"] as! [[String: Any]]
      object["skills"] = entries + entries
    }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: duplicateNames))
    let schema = try fixture()
    try changeManifest(schema) { $0["schema_version"] = 2 }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: schema))
    let symlink = try fixture()
    let file = symlink.appendingPathComponent("sum-difference/SKILL.md")
    let copy = symlink.appendingPathComponent("external.md")
    try FileManager.default.moveItem(at: file, to: copy)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: copy)
    XCTAssertThrowsError(try MathSkillCatalogue(directory: symlink))
  }

  @MainActor
  func testAppPreparationLoadsCleanStoreAndPreservesEditedAndArchivedAliases() async throws {
    let root = try fixture(aliases: ["old-user-method"])
    let directory = try temporaryDirectory()
    let store = MathQuestionStore(directory: directory)
    let initial = try await store.methods()
    XCTAssertTrue(initial.isEmpty)
    let app = makeIsolatedAppDelegate(mathQuestionStore: store)
    let first = try await app.prepareBundledMathSkills(directory: root)
    XCTAssertEqual(first.imported, 1)
    let again = try await app.prepareBundledMathSkills(directory: root)
    XCTAssertEqual(again.skipped, 1)
    let originals = try await store.methods()
    let original = try XCTUnwrap(originals.first)
    let edited = try await store.saveMethod(
      id: original.id, title: original.title,
      category: original.category, instructions: "本地编辑")
    let update = try await app.prepareBundledMathSkills(directory: root)
    XCTAssertEqual(update.conflicts, 1)
    let current = try await store.methods()
    XCTAssertEqual(current, [edited])
    try await store.archiveMethod(id: original.id)
    let archived = try await app.prepareBundledMathSkills(directory: root)
    XCTAssertEqual(archived.skipped, 1)
    let active = try await store.methods()
    XCTAssertTrue(active.isEmpty)
    await store.close()

    let aliasStore = MathQuestionStore(directory: try temporaryDirectory())
    _ = try await aliasStore.saveMethod(
      id: nil, title: "其他用户方法", category: "", instructions: "用户内容")
    _ = try await aliasStore.importMethods([
      .init(
        sourceID: "old-user-method", title: "用户名称",
        category: "", instructions: "用户步骤")
    ])
    let aliasResult = try await aliasStore.importMethods(
      try MathSkillCatalogue(directory: root).importEntries())
    XCTAssertEqual(aliasResult.updated, 1)
    let aliasMethods = try await aliasStore.methods()
    XCTAssertEqual(aliasMethods.count, 2)
    XCTAssertFalse(aliasMethods.contains { $0.id == "markdown-sum" })
    try await aliasStore.archiveMethod(id: "old-user-method")
    let aliasArchived = try await aliasStore.importBundledMathSkills(
      MathSkillCatalogue(directory: root))
    XCTAssertEqual(aliasArchived.skipped, 1)
    await aliasStore.close()
  }

  func testCorrectedSkillRequiresUntamperedOriginalReference() throws {
    let root = try fixture()
    let file = root.appendingPathComponent("sum-difference/SKILL.md")
    let original = Data(body.utf8)
    let corrected = body + "修订后的提示。\n"
    let old = try String(contentsOf: file, encoding: .utf8)
    let headerEnd = try XCTUnwrap(old.range(of: "\n---\n"))
    var header = String(old[..<headerEnd.lowerBound])
    header += "\n  body_sha256: \"\(digest(Data(corrected.utf8)))\""
    header += "\n  source_reference: \"references/source.md\""
    let content = Data((header + "\n---\n" + corrected).utf8)
    try content.write(to: file)
    let reference = file.deletingLastPathComponent().appendingPathComponent("references/source.md")
    try FileManager.default.createDirectory(
      at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
    try original.write(to: reference)
    try changeEntry(root) { $0["sha256"] = digest(content) }
    let catalogue = try MathSkillCatalogue(directory: root)
    XCTAssertEqual(catalogue.skills.first?.instructions, corrected)
    try Data("来源被修改".utf8).write(to: reference)
    XCTAssertThrowsError(try MathSkillCatalogue(directory: root))
  }

  @MainActor
  func testInvalidCatalogueNeverPartiallyImports() async throws {
    let root = try fixture()
    try changeManifest(root) { object in
      var entries = object["skills"] as! [[String: Any]]
      var invalid = entries[0]
      invalid["name"] = "invalid-second"
      invalid["source_id"] = "markdown-invalid"
      invalid["path"] = "../SKILL.md"
      entries.append(invalid)
      object["skills"] = entries
    }
    let store = MathQuestionStore(directory: try temporaryDirectory())
    let existing = try await store.saveMethod(title: "用户方法", category: "", instructions: "保留")
    let app = makeIsolatedAppDelegate(mathQuestionStore: store)
    do {
      _ = try await app.prepareBundledMathSkills(directory: root)
      XCTFail("Expected rejection")
    } catch {}
    let after = try await store.methods()
    XCTAssertEqual(after, [existing])
    await store.close()
  }

  func testLegacyManualAliasRemainsUserOwnedWithoutDuplicate() async throws {
    let store = MathQuestionStore(directory: try temporaryDirectory())
    let original = try await store.saveMethod(title: "个人方法", category: "", instructions: "自定义步骤")
    let root = try fixture(aliases: [original.id])
    let result = try await store.importBundledMathSkills(MathSkillCatalogue(directory: root))
    XCTAssertEqual(result.conflicts, 1)
    let methods = try await store.methods()
    XCTAssertEqual(methods, [original])
    try await store.archiveMethod(id: original.id)
    let archived = try await store.importBundledMathSkills(MathSkillCatalogue(directory: root))
    XCTAssertEqual(archived.skipped, 1)
    let active = try await store.methods()
    XCTAssertTrue(active.isEmpty)
    await store.close()
  }

  func testRejectsUnknownFrontmatterOversizedDescriptionAndInvalidVersion() throws {
    let unknown = try fixture()
    let file = unknown.appendingPathComponent("sum-difference/SKILL.md")
    let extra = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
      of: "metadata:", with: "unexpected: \"not part of spec\"\nmetadata:")
    let bytes = Data(extra.utf8)
    try bytes.write(to: file)
    try changeEntry(unknown) { $0["sha256"] = digest(bytes) }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: unknown))
    let description = try fixture()
    let oversized = String(repeating: "a", count: 1025)
    let descriptionFile = description.appendingPathComponent("sum-difference/SKILL.md")
    let descriptionBytes = Data(
      try String(contentsOf: descriptionFile, encoding: .utf8)
        .replacingOccurrences(of: "当已知两数的和与差时使用，先画线段图。", with: oversized).utf8)
    try descriptionBytes.write(to: descriptionFile)
    try changeEntry(description) {
      $0["description"] = oversized
      $0["sha256"] = digest(descriptionBytes)
    }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: description))
    let version = try fixture()
    let versionFile = version.appendingPathComponent("sum-difference/SKILL.md")
    let versionBytes = Data(
      try String(contentsOf: versionFile, encoding: .utf8)
        .replacingOccurrences(of: "version: \"1\"", with: "version: \"0\"").utf8)
    try versionBytes.write(to: versionFile)
    try changeEntry(version) {
      $0["version"] = "0"
      $0["sha256"] = digest(versionBytes)
    }
    XCTAssertThrowsError(try MathSkillCatalogue(directory: version))
  }

  func testShippedCatalogueIsAvailableWithoutExternalFolder() throws {
    let catalogue = try MathSkillCatalogue.load()
    XCTAssertGreaterThanOrEqual(catalogue.skills.count, 48)
    XCTAssertTrue(
      catalogue.skills.allSatisfy { !$0.instructions.isEmpty && !$0.description.isEmpty })
  }
}
