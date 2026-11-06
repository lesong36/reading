import CryptoKit
import Foundation

struct MathSkillDefinition: Sendable {
  let name: String
  let title: String
  let category: String
  let description: String
  let instructions: String
  let sourceID: String
  let legacyAliasIDs: [String]
  var version: String = ""
  var sha256: String = ""
}

/// The shipped catalogue is validated completely before any database mutation.
struct MathSkillCatalogue: Sendable {
  let skills: [MathSkillDefinition]

  private struct Manifest: Decodable {
    let schemaVersion: Int
    let skills: [Entry]
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case skills
    }
  }
  private struct Entry: Decodable {
    let name: String
    let title: String
    let category: String
    let version: String
    let sourceID: String
    let description: String
    let sha256: String
    let path: String
    let legacyAliasIDs: [String]?
    enum CodingKeys: String, CodingKey {
      case name, title, category, version, description, sha256, path
      case sourceID = "source_id"
      case legacyAliasIDs = "legacy_alias_ids"
    }
  }

  static func load() throws -> MathSkillCatalogue {
    var directory = Bundle.main.url(forResource: "MathSkills", withExtension: nil)
    #if SWIFT_PACKAGE
      if directory == nil {
        directory = Bundle.module.url(forResource: "MathSkills", withExtension: nil)
      }
    #endif
    guard let directory else { throw invalid("应用内数学技能目录缺失，请重新安装应用") }
    return try MathSkillCatalogue(directory: directory)
  }

  init(directory: URL) throws {
    let root = directory.standardizedFileURL
    let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true
    else { throw Self.invalid("技能目录不能包含符号链接") }
    let directory = root.resolvingSymlinksInPath()
    let manifestData = try Self.readFile(
      directory.appendingPathComponent("index.json"), limit: 1_000_000)
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.schemaVersion == 1, !manifest.skills.isEmpty, manifest.skills.count <= 500
    else {
      throw Self.invalid("不支持的技能目录版本或数量")
    }
    var names = Set<String>()
    var identities = Set<String>()
    var total = manifestData.count
    var definitions: [MathSkillDefinition] = []
    for entry in manifest.skills {
      let aliases = entry.legacyAliasIDs ?? []
      guard entry.name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
        entry.name.count <= 64, names.insert(entry.name).inserted,
        entry.path == entry.name + "/SKILL.md", !entry.sourceID.isEmpty,
        !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        entry.description.unicodeScalars.count <= 1_024,
        entry.version.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
        ([entry.sourceID] + aliases).allSatisfy({ !$0.isEmpty && identities.insert($0).inserted })
      else { throw Self.invalid("技能名称、路径或身份重复/无效：\(entry.name)") }
      let file = directory.appendingPathComponent(entry.path)
      let parent = try file.deletingLastPathComponent().resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ])
      guard parent.isDirectory == true, parent.isSymbolicLink != true,
        file.resolvingSymlinksInPath().path == file.path
      else {
        throw Self.invalid("技能文件不能包含符号链接：\(entry.name)")
      }
      let data = try Self.readFile(file, limit: 1_000_000)
      total += data.count
      guard total <= 10_000_000, Self.digest(data) == entry.sha256,
        let text = String(data: data, encoding: .utf8), text.hasPrefix("---\n"),
        let end = text.range(
          of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
      else { throw Self.invalid("技能校验失败：\(entry.name)") }
      let header = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
      let body = String(text[end.upperBound...])
      let metadata = try Self.parseHeader(header)
      guard metadata["name"] == entry.name, metadata["description"] == entry.description,
        metadata["metadata.title"] == entry.title, metadata["metadata.category"] == entry.category,
        metadata["metadata.version"] == entry.version, metadata["metadata.schema_version"] == "1.0",
        metadata["metadata.legacy_source_id"] == entry.sourceID,
        (metadata["metadata.body_sha256"] ?? metadata["metadata.source_sha256"])
          == Self.digest(Data(body.utf8)),
        let sourceFile = metadata["metadata.source_file"], !sourceFile.isEmpty,
        sourceFile == URL(fileURLWithPath: sourceFile).lastPathComponent,
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw Self.invalid("技能元数据与目录不一致：\(entry.name)") }
      if let reference = metadata["metadata.source_reference"] {
        guard reference == "references/source.md", metadata["metadata.body_sha256"] != nil else {
          throw Self.invalid("原始来源引用无效：\(entry.name)")
        }
        let original = file.deletingLastPathComponent().appendingPathComponent(reference)
        let referenceDirectory = try original.deletingLastPathComponent().resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard referenceDirectory.isDirectory == true, referenceDirectory.isSymbolicLink != true,
          original.resolvingSymlinksInPath().path == original.path
        else {
          throw Self.invalid("原始来源引用不能包含符号链接")
        }
        let originalData = try Self.readFile(original, limit: 1_000_000)
        total += originalData.count
        guard total <= 10_000_000, Self.digest(originalData) == metadata["metadata.source_sha256"]
        else {
          throw Self.invalid("原始来源引用校验失败：\(entry.name)")
        }
      } else if metadata["metadata.body_sha256"] != nil {
        throw Self.invalid("修订技能必须保留原始来源")
      }
      definitions.append(
        .init(
          name: entry.name, title: entry.title, category: entry.category,
          description: entry.description, instructions: body, sourceID: entry.sourceID,
          legacyAliasIDs: aliases, version: entry.version, sha256: entry.sha256))
    }
    skills = definitions
  }

  func importEntries(existingIDs: Set<String> = []) throws -> [MathMethodImportEntry] {
    try skills.map { skill in
      let existing = ([skill.sourceID] + skill.legacyAliasIDs).filter { existingIDs.contains($0) }
      guard existing.count <= 1 else { throw Self.invalid("同一技能存在多个旧身份：\(skill.name)") }
      return MathMethodImportEntry(
        sourceID: existing.first ?? skill.sourceID, title: skill.title,
        category: skill.category, instructions: skill.instructions,
        legacyAliasIDs: skill.legacyAliasIDs)
    }
  }

  func discoveryMetadata(for method: MathTeachingMethod) -> (name: String, description: String)? {
    guard
      let skill = skills.first(where: {
        ($0.sourceID == method.id || $0.legacyAliasIDs.contains(method.id))
          && $0.title == method.title && $0.category == method.category
          && $0.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            == method.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
      })
    else { return nil }
    return (skill.name, skill.description)
  }

  private static func parseHeader(_ header: String) throws -> [String: String] {
    let allowed = Set([
      "name", "description", "metadata.title", "metadata.category", "metadata.version",
      "metadata.schema_version", "metadata.source_file", "metadata.source_sha256",
      "metadata.legacy_source_id", "metadata.source_reference", "metadata.body_sha256",
    ])
    var result: [String: String] = [:]
    var inMetadata = false
    for line in header.components(separatedBy: "\n") {
      if line == "metadata:" {
        guard !inMetadata else { throw invalid("重复 metadata") }
        inMetadata = true
        continue
      }
      let nested = line.hasPrefix("  ")
      guard nested == inMetadata, let colon = line.firstIndex(of: ":") else {
        throw invalid("技能 frontmatter 格式错误")
      }
      let key = (nested ? "metadata." : "") + line[..<colon].trimmingCharacters(in: .whitespaces)
      let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard allowed.contains(key), result[key] == nil,
        let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
      else { throw invalid("技能 frontmatter 必须使用唯一的 JSON 引号字符串字段") }
      result[key] = value
    }
    return result
  }

  private static func readFile(_ file: URL, limit: Int) throws -> Data {
    let info = try file.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard info.isRegularFile == true, info.isSymbolicLink != true,
      let size = info.fileSize, size <= limit
    else { throw invalid("技能文件类型或大小无效") }
    let data = try Data(contentsOf: file)
    guard data.count <= limit else { throw invalid("技能文件过大") }
    return data
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func invalid(_ reason: String) -> MathQuestionStoreError {
    .database("数学技能目录无效：" + reason)
  }
}
