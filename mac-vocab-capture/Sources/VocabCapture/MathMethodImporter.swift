import CryptoKit
import Foundation

struct MathMethodImportEntry: Sendable {
  let sourceID: String
  let title: String
  let category: String
  let instructions: String
  let legacyAliasIDs: [String]

  init(sourceID: String, title: String, category: String, instructions: String,
    legacyAliasIDs: [String] = []) {
    self.sourceID = sourceID
    self.title = title
    self.category = category
    self.instructions = instructions
    self.legacyAliasIDs = legacyAliasIDs
  }
}

struct MathMethodImportResult: Sendable {
  let imported: Int
  let skipped: Int
  let updated: Int
  let conflicts: Int

  init(imported: Int, skipped: Int, updated: Int = 0, conflicts: Int = 0) {
    self.imported = imported
    self.skipped = skipped
    self.updated = updated
    self.conflicts = conflicts
  }
}

enum MathMethodImportError: LocalizedError {
  case invalidFile(String)
  case emptyFolder
  var errorDescription: String? {
    switch self {
    case .invalidFile(let name):
      return "无法导入 \(name)：请使用非空 UTF-8 Markdown，每篇不超过 1 MB，整个目录不超过 10 MB。"
    case .emptyFolder: return "目录中没有可导入的 Markdown 方法。"
    }
  }
}

enum MathMethodImporter {
  /// Read-only, all-or-nothing preparation. The directory note provides categories, not a method.
  static func read(directory: URL) throws -> [MathMethodImportEntry] {
    let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    // Standard project skill catalogues share the existing version-preserving
    // import flow; ordinary Markdown folders remain supported.
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path) {
      return try MathSkillCatalogue(directory: directory).importEntries()
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == "md" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var documents: [(URL, String)] = []
    var total = 0
    for file in files {
      let info = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard info.isRegularFile == true, info.isSymbolicLink != true,
        let size = info.fileSize, size <= 1_000_000, total + size <= 10_000_000
      else { throw MathMethodImportError.invalidFile(file.lastPathComponent) }
      let bytes = try Data(contentsOf: file)
      total += bytes.count
      guard bytes.count <= 1_000_000, total <= 10_000_000,
        let text = String(data: bytes, encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw MathMethodImportError.invalidFile(file.lastPathComponent) }
      documents.append((file, text))
    }
    let index = documents.first { $0.0.deletingPathExtension().lastPathComponent == "目录" }?.1 ?? ""
    var categories: [String: String] = [:]
    var category = ""
    let links = try NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#)
    for line in index.components(separatedBy: .newlines) {
      if line.hasPrefix("# ") {
        category = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in links.matches(in: line, range: range) {
          if let name = Range(match.range(at: 1), in: line) {
            categories[String(line[name])] = category
          }
        }
      }
    }
    let entries = documents.filter { $0.0.deletingPathExtension().lastPathComponent != "目录" }.map {
      file, text in
      let name = file.deletingPathExtension().lastPathComponent
      let heading = text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }
      let title =
        heading.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? name
      let key = directory.path + "/" + file.lastPathComponent
      let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
      return MathMethodImportEntry(
        sourceID: "markdown-" + digest, title: title.isEmpty ? name : title,
        category: categories[name] ?? "导入方法", instructions: text)
    }
    guard !entries.isEmpty else { throw MathMethodImportError.emptyFolder }
    return entries
  }
}
