import CSQLite
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// This path never opens MathQuestionStore: an old database is copied before any migration.
enum MathQuestionPreMigrationBackup {
  static func create(directory: URL, to destination: URL) throws {
    try MathQuestionArchive.create(directory: directory, to: destination)
  }
}

/// Online SQLite backup captures WAL commits; every registered image is then hash-checked.
/// It deliberately copies only the database and assets, never recursive backup directories.
enum MathQuestionArchive {
  static let supportedVersion: Int64 = 6
  static let applicationID: Int64 = 0x4D41_5448

  static func create(directory: URL, to destination: URL) throws {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: destination.path) else {
      throw MathQuestionStoreError.backupDestinationExists
    }
    let sourceURL = directory.appendingPathComponent("questions.sqlite")
    try requireRegular(sourceURL)
    var sourceHandle: OpaquePointer?
    guard sqlite3_open_v2(sourceURL.path, &sourceHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let source = sourceHandle else {
      if let sourceHandle { sqlite3_close_v2(sourceHandle) }
      throw MathQuestionStoreError.incompatibleDatabase
    }
    defer { sqlite3_close_v2(source) }
    sqlite3_busy_timeout(source, 5000)
    _ = try validate(source)
    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(".math-archive-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    var completed = false
    defer { if !completed { try? manager.removeItem(at: staging) } }
    let snapshotURL = staging.appendingPathComponent("questions.sqlite")
    var targetHandle: OpaquePointer?
    guard sqlite3_open_v2(snapshotURL.path, &targetHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let target = targetHandle else {
      if let targetHandle { sqlite3_close_v2(targetHandle) }
      throw MathQuestionStoreError.database("无法创建题库快照")
    }
    var targetClosed = false
    defer { if !targetClosed { sqlite3_close_v2(target) } }
    guard let copier = sqlite3_backup_init(target, "main", source, "main") else { throw failure(target) }
    var result: Int32
    var busyRetries = 0
    repeat {
      result = sqlite3_backup_step(copier, 128)
      if result == SQLITE_BUSY || result == SQLITE_LOCKED {
        busyRetries += 1
        if busyRetries < 50 { sqlite3_sleep(20) }
      }
    } while result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyRetries < 50)
    let finish = sqlite3_backup_finish(copier)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw failure(target) }
    // Validate the snapshot itself, rather than assuming its version matches a prior read.
    _ = try validate(target)
    guard try rows(target, "PRAGMA journal_mode = DELETE") == [["delete"]] else {
      throw MathQuestionStoreError.database("无法将快照转换为独立数据库文件")
    }
    let assets = try rows(target, "SELECT id, filename, media_type, byte_count, width, height FROM image_assets")
    let assetDirectory = staging.appendingPathComponent("assets", isDirectory: true)
    try manager.createDirectory(at: assetDirectory, withIntermediateDirectories: false)
    for asset in assets {
      let bytes = try verifiedAsset(asset, directory: directory)
      try writeSynced(bytes, to: assetDirectory.appendingPathComponent(asset[1]))
    }
    // Close/checkpoint the new snapshot so the archive never depends on sidecar WAL files.
    guard sqlite3_close(target) == SQLITE_OK else { throw failure(target) }
    targetClosed = true
    try synchronize(snapshotURL)
    try syncDirectory(assetDirectory)
    try syncDirectory(staging)
    try manager.moveItem(at: staging, to: destination)
    try syncDirectory(parent)
    completed = true
  }

  static func validate(_ db: OpaquePointer) throws -> Int64 {
    let version = try scalar(db, "PRAGMA user_version")
    if version > supportedVersion { throw MathQuestionStoreError.newerDatabase(Int(version)) }
    guard (1...supportedVersion).contains(version),
      try scalar(db, "PRAGMA application_id") == applicationID,
      try rows(db, "PRAGMA quick_check") == [["ok"]],
      try rows(db, "PRAGMA foreign_key_check").isEmpty else {
      throw MathQuestionStoreError.incompatibleDatabase
    }
    var checks = [
      "SELECT id,filename,media_type,byte_count,width,height,created_at FROM image_assets LIMIT 0",
      "SELECT id,capture_id,asset_id,title,grade,created_at,updated_at,deleted_at FROM questions LIMIT 0",
      "SELECT question_id,text,status,updated_at FROM question_ocr LIMIT 0",
      "SELECT id,question_id,question,answer,model,created_at,source,verification_status FROM question_solutions LIMIT 0",
      "SELECT question_id,axis,tag_id,catalogue_version,label,origin,status FROM question_tags LIMIT 0",
    ]
    if version >= 2 {
      checks += [
        "SELECT method_snapshot FROM question_solutions LIMIT 0",
        "SELECT id,question_id,text,source,scope,image_asset_id,created_at FROM question_reference_answers LIMIT 0",
        "SELECT id,solution_id,status,scope,note,correction,reference_id,created_at FROM solution_reviews LIMIT 0",
        "SELECT id,current_version_id,archived_at FROM teaching_methods LIMIT 0",
        "SELECT id,method_id,title,category,instructions,created_at FROM teaching_method_versions LIMIT 0",
      ]
    }
    if version >= 3 {
      checks += ["SELECT classification_revision FROM questions LIMIT 0", "SELECT question_id,status,attempt_token,manual_revision,error,model,prompt_version,catalogue_version,evidence,updated_at FROM question_auto_tag_jobs LIMIT 0"]
    }
    if version >= 4 { checks += ["SELECT method_id,last_imported_version_id FROM teaching_method_imports LIMIT 0"] }
    if version >= 5 {
      checks += ["SELECT diagram_failure FROM question_solutions LIMIT 0", "SELECT solution_id,ordinal,schema_version,renderer_version,diagram_json,image_asset_id FROM solution_diagrams LIMIT 0"]
    }
    if version >= 6 { checks += MathQuestionStore.skillLearningSchemaChecks }
    for sql in checks { _ = try rows(db, sql) }
    if version >= 6 {
      do {
        for row in try rows(db,"SELECT version_id,profile_json,status FROM skill_profiles") {
          let profile=try JSONDecoder().decode(MathSkillProfile.self,from:Data(row[1].utf8))
          guard profile.versionID==row[0],profile.status==row[2],
            ["draft", "approved", "review_required", "revoked"].contains(profile.status),
            [profile.trigger,profile.constraints,profile.exclusions,profile.prerequisites].allSatisfy({ $0.utf8.count <= 12_000 }),
            (profile.sourceInstructions?.utf8.count ?? 0) <= 96_000,
            profile.supportedDiagrams.count <= 10, Set(profile.supportedDiagrams).count == profile.supportedDiagrams.count,
            profile.supportedDiagrams.allSatisfy({ MathDiagram.Kind(rawValue:$0) != nil })
          else { throw MathQuestionStoreError.incompatibleDatabase }
        }
        for event in try rows(db, "SELECT version_id,note FROM skill_lifecycle_events WHERE decision='ai_research'") {
          guard event[1].utf8.count <= 2_000_000 else { throw MathQuestionStoreError.incompatibleDatabase }
          let archive = try JSONDecoder().decode(MathSkillProfileResearchArchive.self, from: Data(event[1].utf8))
          try validateProfileResearchArchive(db, archive: archive, versionID: event[0])
        }
        for event in try rows(db, "SELECT version_id,note FROM skill_lifecycle_events WHERE decision='project_sync'") {
          guard event[1].utf8.count <= 32_000 else { throw MathQuestionStoreError.incompatibleDatabase }
          let receipt = try JSONDecoder().decode(MathSkillProjectSyncReceipt.self, from: Data(event[1].utf8))
          try receipt.validate()
          guard receipt.versionID == event[0], try rows(db, "SELECT method_id FROM teaching_method_versions WHERE id='\(event[0].replacingOccurrences(of: "'", with: "''"))'") == [[receipt.methodID]] else {
            throw MathQuestionStoreError.incompatibleDatabase
          }
        }
        for row in try rows(db,"SELECT signature,proposal_json FROM method_candidates") {
          let proposal=try JSONDecoder().decode(MathSkillProposal.self,from:Data(row[1].utf8))
          guard proposal.signature==row[0],proposal.signature.range(of:"^[a-z][a-z_-]{2,127}$",options:.regularExpression) != nil else { throw MathQuestionStoreError.incompatibleDatabase }
        }
        for row in try rows(db,"SELECT question_id,asset_id,snapshot_json FROM method_candidate_evidence") {
          let snapshot=try JSONDecoder().decode(MathSkillLearningSnapshot.self,from:Data(row[2].utf8))
          guard snapshot.questionID==row[0],snapshot.assetID==row[1] else { throw MathQuestionStoreError.incompatibleDatabase }
          try validateLearningSnapshot(db, snapshot: snapshot)
        }
        for job in try rows(db, "SELECT status,attempt_token,error FROM skill_learning_jobs") {
          guard ["pending", "running", "ready", "failed"].contains(job[0]),
            (job[0] == "running") == !job[1].isEmpty, job[1].count <= 128,
            job[2].utf8.count <= 16_000 else { throw MathQuestionStoreError.incompatibleDatabase }
        }
        for row in try rows(db,"SELECT question_id,snapshot_json FROM skill_learning_jobs") + rows(db,"SELECT question_id,snapshot_json FROM skill_learning_reports") {
          let snapshot=try JSONDecoder().decode(MathSkillLearningSnapshot.self,from:Data(row[1].utf8))
          guard snapshot.questionID==row[0] else { throw MathQuestionStoreError.incompatibleDatabase }
          try validateLearningSnapshot(db, snapshot: snapshot)
        }
        for row in try rows(db,"SELECT report_json,question_id,snapshot_json FROM skill_learning_reports") {
          guard row[0].utf8.count <= 512_000,
            let object = try JSONSerialization.jsonObject(with:Data(row[0].utf8)) as? [String:Any]
          else { throw MathQuestionStoreError.incompatibleDatabase }
          if let research = object["native_research"] as? [String:Any] {
            guard Set(research.keys) == ["candidate_id", "revision", "binding", "evidence_ids", "proposal"],
              let candidateID = research["candidate_id"] as? String,
              try rows(db, "SELECT id FROM method_candidates WHERE id='\(candidateID.replacingOccurrences(of: "'", with: "''"))'").count == 1,
              MathSkillResearchValidation.integer(research["revision"]).map({ $0 > 0 }) == true,
              let binding = research["binding"] as? String, binding.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
            else { throw MathQuestionStoreError.incompatibleDatabase }
            try MathSkillResearchValidation.validate(object)
            try validateResearchBinding(db, object: object, research: research)
          }
          if object["native_candidate_event"] != nil {
            guard Set(object.keys) == ["native_candidate_event"] else { throw MathQuestionStoreError.incompatibleDatabase }
            guard let event = try JSONDecoder().decode([String:MathSkillCandidateEvent].self,from:Data(row[0].utf8))["native_candidate_event"] else { throw MathQuestionStoreError.incompatibleDatabase }
            guard event.revision > 0, ["rejected", "merged", "merged_into", "previous_revision"].contains(event.decision),
              !event.reason.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, event.reason.utf8.count <= 12_000,
              event.proposal.signature.range(of:"^[a-z][a-z_-]{2,127}$",options:.regularExpression) != nil,
              try rows(db,"SELECT id FROM method_candidates WHERE id='\(event.candidateID.replacingOccurrences(of: "'", with: "''"))'").count == 1
            else { throw MathQuestionStoreError.incompatibleDatabase }
          } else if object["native_research"] == nil {
            var sources: [MathSkillLearningSnapshot] = []
            let primary = try JSONDecoder().decode(MathSkillLearningSnapshot.self, from: Data(row[2].utf8))
            if let frozen = object["native_learning_sources"] {
              sources = try JSONDecoder().decode([MathSkillLearningSnapshot].self,
                from: JSONSerialization.data(withJSONObject: frozen))
              guard (1...24).contains(sources.count), Set(sources.map(\.questionID)).count == sources.count,
                sources.first == primary, sources.first?.questionID == row[1] else { throw MathQuestionStoreError.incompatibleDatabase }
              for source in sources { try validateLearningSnapshot(db, snapshot: source) }
            } else if object["workflow_state"] != nil {
              // Historical checkpoints predate complete source freezing. Bind the original
              // current question and retain their read-only evidence; they never approve skills.
              sources = [primary]
              if let checkpoint = object["workflow_state"] as? [String: Any], let state = checkpoint["state"] as? [String: Any],
                let evidence = state["evidence"] as? [[String: Any]] {
                let questionIDs = Set(try rows(db, "SELECT id FROM questions").compactMap(\.first))
                guard evidence.allSatisfy({ ($0["question_id"] as? String).map(questionIDs.contains) == true }) else { throw MathQuestionStoreError.incompatibleDatabase }
              }
            }
            let methodIDs = Set(try rows(db, "SELECT id FROM teaching_methods").compactMap(\.first))
            try MathSkillLearningValidation.validate(object, sourceSnapshots: sources, allowedMethodIDs: methodIDs,
              requireCompleteSourceBinding: object["native_learning_sources"] != nil)
          }
        }
      } catch { throw MathQuestionStoreError.database("备份中的技能资料、候选或教研证据已损坏：\(error.localizedDescription)") }
    }
    if version >= 2 {
      for row in try rows(db, "SELECT method_snapshot FROM question_solutions WHERE method_snapshot IS NOT NULL") where !row[0].isEmpty {
        do {
          let snapshot = try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: Data(row[0].utf8))
          for method in snapshot.visualMethods + (snapshot.method.map { [$0] } ?? []) where method.teachingPermissions != nil {
            let identity = method.versionID.replacingOccurrences(of: "'", with: "''")
            guard let version = try rows(db, "SELECT method_id,title,category,instructions FROM teaching_method_versions WHERE id='\(identity)'").first,
              version == [method.id,method.title,method.category,method.instructions],
              let storedProfile = try rows(db, "SELECT profile_json FROM skill_profiles WHERE version_id='\(identity)'").first?.first,
              try JSONDecoder().decode(MathSkillProfile.self, from: Data(storedProfile.utf8)).teachingPermissions == method.teachingPermissions else {
              throw MathQuestionStoreError.incompatibleDatabase
            }
          }
        }
        catch { throw MathQuestionStoreError.database("备份中的方法版本记录已损坏") }
      }
    }
    if version >= 5 {
      for row in try rows(db, "SELECT schema_version,renderer_version,diagram_json FROM solution_diagrams") {
        guard Int(row[0]) == MathDiagram.schemaVersion, Int(row[1]).map({ (1...MathDiagramRenderer.rendererVersion).contains($0) }) == true else {
          throw MathQuestionStoreError.database("备份包含不支持的图解版本")
        }
        do {
          let diagram = try JSONDecoder().decode(MathDiagram.self, from: Data(row[2].utf8))
          try diagram.validate()
        } catch { throw MathQuestionStoreError.database("备份中的图解记录已损坏") }
      }
    }
    return version
  }

  private static func verifiedAsset(_ row: [String], directory: URL) throws -> Data {
    let hash = row[0], filename = row[1]
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
      filename == "\(hash).png" || filename == "\(hash).jpg",
      row[2] == (filename.hasSuffix(".png") ? "image/png" : "image/jpeg") else {
      throw MathQuestionStoreError.damagedImage
    }
    let url = directory.appendingPathComponent("assets").appendingPathComponent(filename)
    do { try requireRegular(url) } catch { throw MathQuestionStoreError.damagedImage }
    let bytes = try Data(contentsOf: url)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard digest == hash, Int(row[3]) == bytes.count,
      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      Int(row[4]) == image.width, Int(row[5]) == image.height else {
      throw MathQuestionStoreError.damagedImage
    }
    return bytes
  }

  private static func requireRegular(_ url: URL) throws {
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else {
      throw MathQuestionStoreError.incompatibleDatabase
    }
  }

  /// Answers, reference answers and review events are append-only. Validate their frozen
  /// identities without confusing a later OCR/grade/review update with damaged history.
  private static func validateLearningSnapshot(_ db: OpaquePointer, snapshot: MathSkillLearningSnapshot) throws {
    func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    guard snapshot.grade.map({ (1...6).contains($0) }) != false,
      try rows(db, "SELECT asset_id FROM questions WHERE id=\(quoted(snapshot.questionID))") == [[snapshot.assetID]],
      Set(snapshot.solutions.map(\.id)).count == snapshot.solutions.count,
      Set(snapshot.references.map(\.id)).count == snapshot.references.count,
      Set(snapshot.reviews.map(\.id)).count == snapshot.reviews.count else { throw MathQuestionStoreError.database("题目或原图身份不一致") }
    for solution in snapshot.solutions {
      guard let source = try rows(db, "SELECT question_id,question,answer,model,created_at,method_snapshot FROM question_solutions WHERE id=\(quoted(solution.id))").first,
        source.count == 6, source[0] == snapshot.questionID, source[1] == solution.question,
        source[2] == solution.answer, source[3] == solution.model,
        Double(source[4]).map({ abs($0 - solution.createdAt.timeIntervalSinceReferenceDate) < 0.000_01 }) == true,
        ["unverified", "confirmed", "rejected"].contains(solution.verificationStatus),
        solution.verificationStatus == (snapshot.reviews.last(where: { $0.solutionID == solution.id })?.status ?? "unverified")
      else { throw MathQuestionStoreError.database("冻结解答与原记录不一致") }
      let methods = source[5].isEmpty ? MathSolutionMethodSnapshot(method: nil, visualMethods: [])
        : try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: Data(source[5].utf8))
      guard solution.method == methods.method, solution.visualMethods == methods.visualMethods,
        solution.selectionFailure == methods.selectionFailure else {
        throw MathQuestionStoreError.database("冻结解答调用的方法版本与原记录不一致")
      }
    }
    for reference in snapshot.references {
      guard let source = try rows(db, "SELECT question_id,text,source,scope,image_asset_id,created_at FROM question_reference_answers WHERE id=\(quoted(reference.id))").first,
        source.count == 6, source[0] == snapshot.questionID, source[1] == reference.text,
        source[2] == reference.source, source[3] == reference.scope, source[4] == (reference.imageAssetID ?? ""),
        Double(source[5]).map({ abs($0 - reference.createdAt.timeIntervalSinceReferenceDate) < 0.000_01 }) == true
      else { throw MathQuestionStoreError.database("参考答案与原记录不一致") }
    }
    for review in snapshot.reviews {
      guard snapshot.solutions.contains(where: { $0.id == review.solutionID }),
        review.referenceID == nil || snapshot.references.contains(where: { $0.id == review.referenceID }),
        let source = try rows(db, "SELECT solution_id,status,scope,note,correction,reference_id,created_at FROM solution_reviews WHERE id=\(quoted(review.id))").first,
        source.count == 7, source[0] == review.solutionID, source[1] == review.status,
        source[2] == review.scope, source[3] == review.note, source[4] == review.correction,
        source[5] == (review.referenceID ?? ""),
        Double(source[6]).map({ abs($0 - review.createdAt.timeIntervalSinceReferenceDate) < 0.000_01 }) == true
      else { throw MathQuestionStoreError.database("核验记录与原记录不一致") }
    }
  }

  private static func validateProfileResearchArchive(_ db: OpaquePointer,
    archive: MathSkillProfileResearchArchive, versionID: String) throws {
    func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    let attempt = archive.attempt, method = attempt.method
    guard archive.version == 1, !archive.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      archive.model.utf8.count <= 1_000, method.versionID == versionID, attempt.profile.versionID == versionID,
      attempt.profile.status == "draft", attempt.evidence.count <= 24, attempt.questionSnapshots.count <= 12,
      Set(attempt.evidence.map(\.questionID)).count == attempt.evidence.count,
      Set(attempt.questionSnapshots.map(\.questionID)).count == attempt.questionSnapshots.count,
      let stored = try rows(db, "SELECT method_id,title,category,instructions,created_at FROM teaching_method_versions WHERE id=\(quoted(versionID))").first,
      stored.count == 5, stored[0] == method.id, stored[1] == method.title, stored[2] == method.category, method.instructions == stored[3],
      Double(stored[4]).map({ abs($0 - method.createdAt.timeIntervalSinceReferenceDate) < 0.000_01 }) == true
    else { throw MathQuestionStoreError.database("教研报告与方法版本不一致") }
    if method.teachingPermissions != nil || attempt.profile.teachingPermissions != nil {
      guard method.teachingPermissions == attempt.profile.teachingPermissions,
        let json = try rows(db, "SELECT profile_json FROM skill_profiles WHERE version_id=\(quoted(versionID))").first?.first,
        try JSONDecoder().decode(MathSkillProfile.self, from: Data(json.utf8)).teachingPermissions == method.teachingPermissions else {
        throw MathQuestionStoreError.database("教研权限与不可变方法版本不一致")
      }
    }
    // A seeded profile may have been researched before the first local profile was
    // saved. Historical binding is to the immutable method body, never a later profile.
    if let original = attempt.profile.sourceInstructions, original != method.instructions {
      // Edited profile content is carried in the immutable method body itself.
      let p = attempt.profile
      let permissionText = p.teachingPermissions.map { "结构化教学权限：\n\($0.summary)\n\n" } ?? ""
      let rendered = permissionText + "教研适用条件：\n\(p.trigger)\n\n学段与限制：\n\(p.constraints)\n\n排除条件：\n\(p.exclusions)\n\n先修知识：\n\(p.prerequisites)\n\n可用图解：\n\(p.supportedDiagrams.joined(separator: "、"))\n\n原方法全文：\n\(original)"
      guard rendered == stored[3] else { throw MathQuestionStoreError.database("教研档案正文与不可变的方法版本不一致") }
    }
    for source in attempt.sourceReferences {
      guard !source.locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.locator.utf8.count <= 1_000,
        source.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw MathQuestionStoreError.database("教研资料引用无效") }
    }
    for entry in attempt.evidence {
      guard !entry.questionID.isEmpty, entry.questionID.count <= 128,
        [entry.text, entry.answer, entry.referenceAnswer].allSatisfy({ $0.count <= 6_000 }),
        entry.userConstraint.count <= 2_000, entry.grade.map({ (1...6).contains($0) }) != false,
        ["positive", "excluded"].contains(entry.role), ["unverified", "confirmed"].contains(entry.verification),
        !entry.provenance.isEmpty else { throw MathQuestionStoreError.database("教研例题字段无效") }
      if entry.questionID.hasPrefix("teaching-case:") {
        guard entry.verification == "unverified", entry.answer.isEmpty, entry.referenceAnswer.isEmpty else { throw MathQuestionStoreError.database("待审资料不得冒充人工核验") }
      } else {
        guard attempt.questionSnapshots.contains(where: { $0.questionID == entry.questionID }) else { throw MathQuestionStoreError.database("缺少教研题目的完整快照") }
      }
    }
    for snapshot in attempt.questionSnapshots {
      try validateLearningSnapshot(db, snapshot: snapshot)
      guard let entry = attempt.evidence.first(where: { $0.questionID == snapshot.questionID }),
        let solution = snapshot.solutions.last(where: { $0.method?.versionID == versionID || $0.visualMethods.contains(where: { $0.versionID == versionID }) }) else { throw MathQuestionStoreError.database("教研快照没有调用对应方法版本") }
      let latest = snapshot.reviews.last { $0.solutionID == solution.id }
      let confirmed = solution.verificationStatus == "confirmed" && latest?.status == "confirmed"
      let processConfirmed = confirmed && latest?.scope == "答案及解题过程"
      let reference = snapshot.references.first { $0.id == latest?.referenceID }
      guard entry.text == String(snapshot.ocrText.prefix(6_000)), entry.answer == String(solution.answer.prefix(6_000)),
        entry.referenceAnswer == String((reference?.text ?? "").prefix(6_000)), entry.grade == snapshot.grade,
        entry.userConstraint == String(solution.question.prefix(2_000)), entry.role == "positive",
        (entry.verification == (processConfirmed ? "confirmed" : "unverified")
          // Earlier advisory archives used answer-only confirmations. Retain this historic
          // metadata; it never constitutes the human approval required for publication.
          || (entry.verification == "confirmed" && confirmed)) else { throw MathQuestionStoreError.database("教研例题与冻结快照不一致") }
    }
    try archive.result.validate(attempt: attempt)
  }

  /// Rebuild the exact historical attempt from immutable evidence, not current mutable rows.
  private static func validateResearchBinding(_ db: OpaquePointer, object: [String:Any], research: [String:Any]) throws {
    guard let ids = research["evidence_ids"] as? [String], (3...24).contains(ids.count), Set(ids).count == ids.count,
      let candidateID = research["candidate_id"] as? String,
      let revision = MathSkillResearchValidation.integer(research["revision"]),
      let proposal = research["proposal"] as? [String:Any]
    else { throw MathQuestionStoreError.incompatibleDatabase }
    let draft = try JSONDecoder().decode(MathSkillProposal.self, from: JSONSerialization.data(withJSONObject: proposal))
    var evidence: [MathSkillCandidateEvidence] = []
    for id in ids {
      var pointer: OpaquePointer?
      guard sqlite3_prepare_v2(db, "SELECT id,candidate_id,revision,question_id,asset_id,content_digest,solution_id,review_id,reference_id,boundary,origin,note,snapshot_json,created_at FROM method_candidate_evidence WHERE id=?", -1, &pointer, nil) == SQLITE_OK,
        let statement = pointer else { throw failure(db) }
      defer { sqlite3_finalize(statement) }
      _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw MathQuestionStoreError.incompatibleDatabase }
      let entry = try MathQuestionStore.readSkillCandidateEvidence(statement)
      guard entry.candidateID == candidateID, entry.candidateRevision == revision, entry.origin == "user",
        ["applies", "excluded"].contains(entry.boundary), entry.reviewID != nil,
        let review = entry.snapshot.reviews.last(where: { $0.solutionID == entry.solutionID }),
        review.id == entry.reviewID, review.status == "confirmed", review.scope == "答案及解题过程"
      else { throw MathQuestionStoreError.incompatibleDatabase }
      evidence.append(entry)
    }
    guard evidence.map(\.questionID) == evidence.map(\.questionID).sorted() else { throw MathQuestionStoreError.incompatibleDatabase }
    let attempt = MathSkillResearchAttempt(candidateID: candidateID, revision: revision, proposal: draft, evidence: evidence)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(attempt)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard research["binding"] as? String == digest else { throw MathQuestionStoreError.incompatibleDatabase }
    let expected = attempt.learningObject
    try MathSkillResearchValidation.validate(object, evidence: expected["evidence"], proposal: (expected["candidate"] as? [String:Any])?["proposal"])
  }

  private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else { throw failure(db) }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      result.append((0..<sqlite3_column_count(statement)).map { index in
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
      })
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw failure(db) }
    return result
  }

  private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
    Int64(try rows(db, sql).first?.first ?? "") ?? 0
  }

  private static func failure(_ db: OpaquePointer) -> MathQuestionStoreError {
    .database(String(cString: sqlite3_errmsg(db)))
  }

  static func writeSynced(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try synchronize(url)
  }

  private static func synchronize(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw MathQuestionStoreError.database("无法打开快照目录") }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw MathQuestionStoreError.database("无法同步快照目录") }
  }
}
