import CryptoKit
import Foundation

/// Stored only by explicit native actions; background model output cannot write this event.
struct MathSkillCandidateEvent: Codable, Sendable, Equatable {
  let candidateID: String
  let revision: Int
  let decision: String
  let reason: String
  let relatedCandidateID: String?
  let proposal: MathSkillProposal
}

/// Complete immutable export data is collected on the store actor before filesystem writing.
struct MathSkillExport: Sendable {
  let candidate: MathSkillCandidate
  let method: MathTeachingMethod
  let profile: MathSkillProfile
  let evidence: [MathSkillCandidateEvidence]
  let researchJSON: String
  let events: [MathSkillCandidateEvent]

  var name: String { "math-learned-" + candidate.id.lowercased() }

  func write(to directory: URL) throws {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: directory.path) else { throw MathQuestionStoreError.backupDestinationExists }
    let parent = directory.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".math-skill-export-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    let skillDirectory = staging.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: skillDirectory, withIntermediateDirectories: false)
    let references = skillDirectory.appendingPathComponent("references", isDirectory: true)
    try fm.createDirectory(at: references, withIntermediateDirectories: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let evidenceData = try encoder.encode(evidence)
    let source = profile.sourceInstructions ?? candidate.proposal.instructions
    let description = String(("使用" + method.title + "解决" + profile.trigger + "。排除：" + profile.exclusions).prefix(1_024))
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let sourceID = "markdown-" + digest(Data(("native-candidate/" + candidate.id).utf8))
    // JSON strings are valid YAML quoted scalars and preserve punctuation/newlines safely.
    func quoted(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    let body = """
      # \(method.title)

      \(method.instructions)

      ## 核验与来源

      这份方法由用户针对当前版本核验批准。解决新题时仍须对照原题条件，答案与解题过程由用户验证。
      需要核对教学来源与误用反例时，读取 [references/evidence.json](references/evidence.json)。
      需要核对五项教研检查和人工批准记录时，读取 [references/research.json](references/research.json)。
      原始方法正文保存在 [references/source.md](references/source.md)，版本与校验值见 [references/provenance.json](references/provenance.json)。
      候选合并及拒绝决定见 [references/decisions.json](references/decisions.json)。
      """ + "\n"
    let text = """
      ---
      name: \(try quoted(name))
      description: \(try quoted(description))
      metadata:
        title: \(try quoted(method.title))
        category: \(try quoted(method.category))
        version: \(try quoted(String(candidate.revision)))
        schema_version: "1.0"
        source_file: "source.md"
        source_sha256: \(try quoted(digest(Data(source.utf8))))
        legacy_source_id: \(try quoted(sourceID))
        source_reference: "references/source.md"
        body_sha256: \(try quoted(digest(Data(body.utf8))))
      ---
      """ + "\n" + body
    let skillData = Data(text.utf8)
    try skillData.write(to: skillDirectory.appendingPathComponent("SKILL.md"))
    try evidenceData.write(to: references.appendingPathComponent("evidence.json"))
    try Data(researchJSON.utf8).write(to: references.appendingPathComponent("research.json"))
    try Data(source.utf8).write(to: references.appendingPathComponent("source.md"))
    try encoder.encode(events).write(to: references.appendingPathComponent("decisions.json"))
    let manifest: [String: Any] = ["schema_version": 1, "skills": [["name": name, "title": method.title,
      "category": method.category, "version": String(candidate.revision), "source_id": sourceID,
      "description": description, "sha256": digest(skillData), "path": name + "/SKILL.md"]]]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: staging.appendingPathComponent("index.json"))
    let provenance: [String: Any] = ["version": 1, "skill_name": name,
      "candidate_id": candidate.id, "candidate_revision": candidate.revision,
      "pattern_key": candidate.proposal.signature, "method_id": method.id,
      "method_version_id": method.versionID, "skill_sha256": digest(skillData),
      "source_sha256": digest(Data(source.utf8)), "evidence_sha256": digest(evidenceData),
      "research_sha256": digest(Data(researchJSON.utf8)),
      "evidence_ids": evidence.map(\.id), "question_ids": Array(Set(evidence.map(\.questionID))).sorted(),
      "review_ids": evidence.compactMap(\.reviewID), "reference_ids": evidence.compactMap(\.referenceID),
      "approval": "human", "exported_at": ISO8601DateFormatter().string(from: Date())]
    try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
      .write(to: references.appendingPathComponent("provenance.json"))
    // Rename the completed folder once. Existing exports are never overwritten.
    try fm.moveItem(at: staging, to: directory)
  }
}
