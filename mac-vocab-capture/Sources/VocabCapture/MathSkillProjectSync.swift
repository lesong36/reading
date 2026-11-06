import CryptoKit
import Foundation

/// Derived project files retain exact SQLite versions; their existence never grants approval.
struct MathProjectSkillSnapshot: Codable, Sendable, Equatable {
  let method: MathTeachingMethod
  let profile: MathSkillProfile?
  let versionOrdinal: Int
  let automaticEligible: Bool
  let candidateID: String?
  let lifecycle: [MathSkillLifecycleEventSnapshot]
  var candidateReview: MathProjectCandidateReviewSnapshot? = nil
}

struct MathProjectCandidateReviewSnapshot: Codable, Sendable, Equatable {
  let candidate: MathSkillCandidate
  let evidence: [MathSkillCandidateEvidence]
  let researchJSON: String
  let events: [MathSkillCandidateEvent]
}

struct MathSkillLifecycleEventSnapshot: Codable, Sendable, Equatable {
  let id: String
  let decision: String
  let note: String
  let createdAt: Date
}

struct MathSkillProjectSyncReceipt: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let methodID: String
  let versionID: String
  let projectDirectory: String
  let relativePath: String
  let artifactSHA256: String
  let status: String
  let error: String
  let createdAt: Date

  func validate() throws {
    guard schemaVersion == 1, !methodID.isEmpty, !versionID.isEmpty, methodID.utf8.count <= 256, versionID.utf8.count <= 256,
      projectDirectory.hasPrefix("/"), projectDirectory.utf8.count <= 4_000,
      URL(fileURLWithPath: projectDirectory).standardizedFileURL.path == projectDirectory,
      ["synced", "failed"].contains(status), error.utf8.count <= 16_000,
      artifactSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      status != "synced" || (!relativePath.isEmpty && error.isEmpty),
      relativePath.isEmpty || relativePath.range(of: "^MathSkills/Local/versions/[a-f0-9]{64}/[a-f0-9]{64}$", options: .regularExpression) != nil,
      relativePath.isEmpty || relativePath == "MathSkills/Local/versions/" + MathSkillProjectArtifact.digest(Data(versionID.utf8)) + "/" + artifactSHA256,
      createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw MathQuestionStoreError.database("项目技能同步记录的身份、路径或状态无效")
    }
  }
}

struct MathSkillProjectArtifact: Sendable {
  let snapshot: MathProjectSkillSnapshot
  let name: String
  let files: [String: Data]
  let sha256: String
  let relativePath: String

  init(snapshot: MathProjectSkillSnapshot) throws {
    self.snapshot = snapshot
    let method = snapshot.method
    let methodKey = Self.digest(Data(method.id.utf8))
    name = "math-local-" + String(methodKey.prefix(32))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    func quoted(_ text: String) throws -> String { String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
    let source = snapshot.profile?.sourceInstructions ?? method.instructions
    let trigger = snapshot.profile?.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = String(("使用" + method.title + "。适用条件：" + (trigger?.isEmpty == false ? trigger! : "根据原方法与题目条件判断") + "。审批与学段限制见版本档案。").prefix(1_024))
    let category = method.category.isEmpty ? "用户方法" : String(method.category.prefix(256))
    let title = String(method.title.prefix(256))
    let sourceID = "markdown-" + methodKey
    let body = "# \(method.title)\n\n" + Self.portableInstructions(method.instructions) + "\n\n" + """
      ## 版本与使用条件

      这是当前方法版本的项目快照。同步文件不代表人工批准；用于新题前须核对当前题库的审核状态、学段权限和原题条件。
      完整原方法见 [references/source.md](references/source.md)，完整数据库方法版本见 [references/method.json](references/method.json)。
      适用、排除、先修知识及结构化教学权限见 [references/profile.json](references/profile.json)。
      当时的审校记录见 [references/lifecycle.json](references/lifecycle.json)，身份与校验值见 [references/provenance.json](references/provenance.json)。
      当前可使用的快照由项目 MathSkills/Local/index.json 标识，旧快照保留历史，不证明目前仍获批准。
      """ + "\n" + (snapshot.candidateReview == nil ? "" : "\n候选方法的多题核验快照、五项教研和批准报告见 [references/candidate-review.json](references/candidate-review.json)。原照片仍保存在题库完整备份中，依据中的原图身份用于核对。\n")
    let text = """
      ---
      name: \(try quoted(name))
      description: \(try quoted(description))
      metadata:
        title: \(try quoted(title))
        category: \(try quoted(category))
        version: \(try quoted(String(snapshot.versionOrdinal)))
        schema_version: "1.0"
        source_file: \(try quoted("method-" + methodKey + ".md"))
        source_sha256: \(try quoted(Self.digest(Data(source.utf8))))
        legacy_source_id: \(try quoted(sourceID))
        source_reference: "references/source.md"
        body_sha256: \(try quoted(Self.digest(Data(body.utf8))))
      ---
      """ + "\n" + body
    let skill = Data(text.utf8)
    let manifest: [String: Any] = ["schema_version": 1, "skills": [["name": name, "title": title,
      "category": category, "version": String(snapshot.versionOrdinal), "source_id": sourceID,
      "description": description, "sha256": Self.digest(skill), "path": name + "/SKILL.md"]]]
    let provenance: [String: Any] = ["schema_version": 1, "method_id": method.id, "method_version_id": method.versionID,
      "version_ordinal": snapshot.versionOrdinal, "source_sha256": Self.digest(Data(source.utf8)),
      "skill_sha256": Self.digest(skill), "automatic_eligible_at_snapshot": snapshot.automaticEligible,
      "approval_status_at_snapshot": snapshot.profile?.status ?? "legacy_unreviewed",
      "candidate_id": snapshot.candidateID as Any? ?? NSNull(), "approval_authority": "sqlite_human_decisions",
      "created_at": method.createdAt.timeIntervalSinceReferenceDate]
    var contents = ["index.json": try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
      name + "/SKILL.md": skill,
      name + "/references/source.md": Data(source.utf8),
      name + "/references/method.json": try encoder.encode(method),
      name + "/references/profile.json": try encoder.encode(snapshot.profile),
      name + "/references/lifecycle.json": try encoder.encode(snapshot.lifecycle),
      name + "/references/provenance.json": try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])]
    if let review = snapshot.candidateReview {
      contents[name + "/references/candidate-review.json"] = try encoder.encode(review)
    }
    files = contents
    guard contents.values.reduce(0, { $0 + $1.count }) <= 4_000_000,
      contents.values.allSatisfy({ $0.count <= 1_000_000 }) else { throw MathQuestionStoreError.database("方法与版本依据超过项目技能容量，未截断或同步") }
    let fingerprints = contents.keys.sorted().map { $0 + ":" + Self.digest(contents[$0]!) }.joined(separator: "\n")
    sha256 = Self.digest(Data(fingerprints.utf8))
    relativePath = "MathSkills/Local/versions/" + Self.digest(Data(method.versionID.utf8)) + "/" + sha256
  }

  /// Links to other local methods become readable labels. The original is preserved byte-for-byte.
  private static func portableInstructions(_ text: String) -> String {
    var result = text
    for pattern in [#"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#, #"\[([^\]]+)\]\((?!https?://)[^)]+\)"#] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let labelIndex = pattern.hasPrefix(#"\[\["#) && match.range(at: 2).location != NSNotFound ? 2 : 1
        if let labelRange = Range(match.range(at: labelIndex), in: result) { result.replaceSubrange(range, with: String(result[labelRange])) }
      }
    }
    return result
  }

  func write(to project: URL) throws {
    try Task.checkCancellation()
    try MathSkillProjectSyncFiles.requireDirectory(project)
    let destination = project.appendingPathComponent(relativePath, isDirectory: true)
    try MathSkillProjectSyncFiles.ensureManagedRoot(project: project)
    try MathSkillProjectSyncFiles.ensureDirectory(destination.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: destination.path) {
      try verify(at: destination); return
    }
    let stage = destination.deletingLastPathComponent().appendingPathComponent(".skill-stage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: stage) }
    for path in files.keys.sorted() {
      try Task.checkCancellation()
      let file = stage.appendingPathComponent(path)
      try MathSkillProjectSyncFiles.ensureDirectory(file.deletingLastPathComponent())
      try MathQuestionArchive.writeSynced(files[path]!, to: file)
    }
    try MathQuestionArchive.syncDirectory(stage)
    // No existing user files are replaced; a racing writer must be verified before success.
    do { try FileManager.default.moveItem(at: stage, to: destination) }
    catch {
      if FileManager.default.fileExists(atPath: destination.path) { try verify(at: destination) }
      else { throw error }
    }
    try MathQuestionArchive.syncDirectory(destination.deletingLastPathComponent())
    try verify(at: destination)
  }

  func verify(at directory: URL) throws {
    try MathSkillProjectSyncFiles.requireDirectory(directory)
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    // macOS enumerates /var URLs as /private/var; compare the same canonical spelling.
    let prefix = directory.standardizedFileURL.path + "/"
    var paths = Set<String>()
    while let url = enumerator?.nextObject() as? URL {
      let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      guard info.isSymbolicLink != true else { throw MathQuestionStoreError.database("项目技能不能包含符号链接") }
      if info.isRegularFile == true {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw MathQuestionStoreError.database("项目技能文件不在版本目录中") }
        paths.insert(String(path.dropFirst(prefix.count)))
      }
    }
    guard paths == Set(files.keys) else { throw MathQuestionStoreError.database("项目技能目录存在用户修改或缺失文件，未覆盖") }
    for (path, data) in files {
      let file = directory.appendingPathComponent(path)
      try MathSkillProjectSyncFiles.requireFile(file)
      guard try Data(contentsOf: file) == data else { throw MathQuestionStoreError.database("项目技能校验不一致，保留原目录，请先处理用户修改") }
    }
  }

  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Only this marked, app-owned subtree can have its derived current index updated.
enum MathSkillProjectSyncFiles {
  static let marker = Data("VocabCapture MathSkills Local v1\n".utf8)
  static func requireDirectory(_ url: URL) throws {
    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard info.isDirectory == true, info.isSymbolicLink != true,
      url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
      throw MathQuestionStoreError.database("请选择真实项目目录，技能同步路径不能包含符号链接")
    }
  }
  static func requireFile(_ url: URL) throws {
    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw MathQuestionStoreError.database("项目技能文件不是普通文件") }
  }
  static func ensureDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try requireDirectory(url); return }
    try ensureDirectory(url.deletingLastPathComponent())
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try requireDirectory(url)
  }
  static func ensureManagedRoot(project: URL) throws {
    let parent = project.appendingPathComponent("MathSkills", isDirectory: true)
    try ensureDirectory(parent)
    let root = parent.appendingPathComponent("Local", isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      try requireDirectory(root)
      let markerURL = root.appendingPathComponent(".vocab-capture-sync")
      try requireFile(markerURL)
      guard try Data(contentsOf: markerURL) == marker else { throw MathQuestionStoreError.database("项目已有自定义 Local 技能目录，未覆盖；请选择其他项目位置") }
    } else {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      try MathQuestionArchive.writeSynced(marker, to: root.appendingPathComponent(".vocab-capture-sync"))
      try MathQuestionArchive.syncDirectory(root)
    }
  }

  static func writeIndex(_ bytes: Data, project: URL) throws {
    try ensureManagedRoot(project: project)
    let root = project.appendingPathComponent("MathSkills/Local")
    let target = root.appendingPathComponent("index.json")
    let checksum = root.appendingPathComponent(".index.sha256")
    if FileManager.default.fileExists(atPath: target.path) {
      try requireFile(target); try requireFile(checksum)
      let expected = try String(contentsOf: checksum, encoding: .utf8)
      guard expected == MathSkillProjectArtifact.digest(try Data(contentsOf: target)) + "\n" else {
        throw MathQuestionStoreError.database("项目技能索引被修改，已保留；请备份自定义索引并移走后重新同步")
      }
    } else if FileManager.default.fileExists(atPath: checksum.path) {
      try requireFile(checksum)
    }
    // A crash between these two atomic writes fails closed on restart: the
    // index is preserved and the UI requests repair, never trusted silently.
    try MathQuestionArchive.writeSynced(bytes, to: target)
    try MathQuestionArchive.writeSynced(Data((MathSkillProjectArtifact.digest(bytes) + "\n").utf8), to: checksum)
    try MathQuestionArchive.syncDirectory(root)
  }
}

/// Explicit local project ownership. SQLite approval remains authoritative when files are missing.
@MainActor
final class MathSkillProjectSyncCoordinator {
  private let store: MathQuestionStore
  private let defaults: UserDefaults
  private let key = "VocabCapture.mathSkillsProjectDirectory"
  private(set) var status = "项目技能尚未同步"
  private var running: Task<Void, Never>?
  private var suspended = false
  private var dirty = false
  private let onChange: () -> Void

  init(store: MathQuestionStore, defaults: UserDefaults, onChange: @escaping () -> Void = {}) {
    self.store = store; self.defaults = defaults; self.onChange = onChange
  }
  var projectDirectory: URL? {
    guard let path = defaults.string(forKey: key), path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
  /// Only a real packaged application discovers its build project automatically;
  /// unit tests never write into the shared source tree.
  func discoverDevelopmentProject() {
    guard projectDirectory == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path),
      FileManager.default.fileExists(atPath: project.appendingPathComponent("Sources/VocabCapture/Resources/MathSkills/index.json").path) else { return }
    defaults.set(project.path, forKey: key)
  }
  func selectProject(_ url: URL) throws {
    try MathSkillProjectSyncFiles.requireDirectory(url)
    guard running == nil, !suspended else { throw MathQuestionStoreError.database("正在同步或恢复题库，请稍后选择项目") }
    defaults.set(url.standardizedFileURL.path, forKey: key)
  }
  func synchronize() async {
    guard !suspended else { return }
    if let running { dirty = true; await running.value; return }
    let work = Task { [weak self] in
      guard let self else { return }
      repeat {
        self.dirty = false
        do { try await self.performSync() }
        catch is CancellationError { self.status = "项目技能同步已暂停，重开后会重新核对" }
        catch { self.status = "项目技能同步待修复：" + error.localizedDescription }
      } while self.dirty && !self.suspended && !Task.isCancelled
      self.onChange()
    }
    running = work
    await work.value
    running = nil
  }
  func suspendForLibraryRestore() async {
    suspended = true; running?.cancel(); await running?.value; running = nil
  }
  func resumeAfterLibraryRestore() async { suspended = false; await synchronize() }
  func stop() { suspended = true; running?.cancel() }

  private func performSync() async throws {
    guard let project = projectDirectory else {
      status = "尚未设置技能项目位置；请在方法候选与教研中选择项目目录"
      return
    }
    try MathSkillProjectSyncFiles.requireDirectory(project)
    let snapshots = try await store.projectSkillSnapshots()
    var artifacts: [MathSkillProjectArtifact] = []
    for snapshot in snapshots {
      try Task.checkCancellation()
      let artifact = try MathSkillProjectArtifact(snapshot: snapshot)
      do {
        try await Task.detached { try artifact.write(to: project) }.value
        try Task.checkCancellation()
        try await store.recordProjectSkillSync(.init(schemaVersion: 1, methodID: snapshot.method.id,
          versionID: snapshot.method.versionID, projectDirectory: project.path, relativePath: artifact.relativePath,
          artifactSHA256: artifact.sha256, status: "synced", error: "", createdAt: Date()), snapshot: snapshot)
        artifacts.append(artifact)
      } catch {
        if !(error is CancellationError) {
          try await store.recordProjectSkillSync(.init(schemaVersion: 1, methodID: snapshot.method.id,
            versionID: snapshot.method.versionID, projectDirectory: project.path, relativePath: artifact.relativePath,
            artifactSHA256: artifact.sha256, status: "failed", error: String(error.localizedDescription.prefix(4_000)), createdAt: Date()), snapshot: snapshot)
        }
        throw error
      }
    }
    guard try await store.projectSkillSnapshots() == snapshots else {
      throw MathQuestionStoreError.database("同步期间方法版本或审校状态改变，请重试")
    }
    let items: [[String: Any]] = artifacts.map { artifact in
      ["method_id": artifact.snapshot.method.id, "version_id": artifact.snapshot.method.versionID,
       "name": artifact.name, "path": artifact.relativePath + "/" + artifact.name + "/SKILL.md",
       "artifact_sha256": artifact.sha256, "automatic_eligible": artifact.snapshot.automaticEligible]
    }
    let bytes = try JSONSerialization.data(withJSONObject: ["schema_version": 1,
      "authority": "sqlite_current_versions_and_human_decisions", "snapshots": items], options: [.prettyPrinted, .sortedKeys])
    try Task.checkCancellation()
    try await Task.detached {
      try MathSkillProjectSyncFiles.writeIndex(bytes, project: project)
    }.value
    status = "已核对并同步 \(snapshots.count) 个方法版本至 \(project.path)/MathSkills/Local；历史版本保留"
  }
}
