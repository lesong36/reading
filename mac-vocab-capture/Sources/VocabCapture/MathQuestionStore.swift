import CSQLite
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum MathQuestionStoreError: LocalizedError {
  case invalidImage, invalidCapture, notFound, conflictingCapture, damagedImage
  case incompatibleDatabase
  case newerDatabase(Int)
  case backupDestinationExists
  case database(String)

  var errorDescription: String? {
    switch self {
    case .invalidImage: return "原图不是完整可读取的 PNG 或 JPEG，未保存题目。"
    case .invalidCapture: return "截图标识为空，未保存题目。"
    case .notFound: return "找不到这道题目。"
    case .conflictingCapture: return "同一截图标识对应不同原图，未覆盖已保存题目。"
    case .damagedImage: return "题目原图缺失或校验不一致，请从备份恢复。"
    case .incompatibleDatabase: return "题库数据库损坏或格式不兼容，未重建或覆盖。"
    case .newerDatabase(let version): return "题库版本 \(version) 高于当前应用支持的版本，请升级应用。"
    case .backupDestinationExists: return "请选择尚不存在的备份目录，避免覆盖已有文件。"
    case .database(let message): return "本机题库操作失败：\(message)"
    }
  }
}

extension MathQuestionStore {
  static let skillLearningSchemaChecks = [
    "SELECT version_id,profile_json,status FROM skill_profiles LIMIT 0",
    "SELECT id,version_id,decision,note,created_at FROM skill_lifecycle_events LIMIT 0",
    "SELECT id,signature,proposal_json,revision,status,published_version_id,created_at,updated_at FROM method_candidates LIMIT 0",
    "SELECT id,candidate_id,revision,question_id,asset_id,content_digest,solution_id,review_id,reference_id,boundary,origin,note,snapshot_json,created_at FROM method_candidate_evidence LIMIT 0",
    "SELECT question_id,status,attempt_token,snapshot_json,error,updated_at FROM skill_learning_jobs LIMIT 0",
    "SELECT id,question_id,attempt_token,model,report_json,snapshot_json,created_at FROM skill_learning_reports LIMIT 0"
  ]

  private static let skillLearningSchema = """
    CREATE TABLE skill_profiles (
      version_id TEXT PRIMARY KEY REFERENCES teaching_method_versions(id), profile_json TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('draft','approved','review_required','revoked'))
    );
    CREATE TABLE skill_lifecycle_events (
      id TEXT PRIMARY KEY, version_id TEXT NOT NULL REFERENCES teaching_method_versions(id),
      decision TEXT NOT NULL, note TEXT NOT NULL, created_at REAL NOT NULL
    );
    CREATE TABLE method_candidates (
      id TEXT PRIMARY KEY, signature TEXT NOT NULL UNIQUE, proposal_json TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision > 0),
      status TEXT NOT NULL CHECK(status IN ('observing','draft','published','rejected','review_required')),
      published_version_id TEXT REFERENCES teaching_method_versions(id), created_at REAL NOT NULL, updated_at REAL NOT NULL
    );
    CREATE TABLE method_candidate_evidence (
      id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL REFERENCES method_candidates(id), revision INTEGER NOT NULL,
      question_id TEXT NOT NULL REFERENCES questions(id), asset_id TEXT NOT NULL REFERENCES image_assets(id),
      content_digest TEXT NOT NULL, solution_id TEXT REFERENCES question_solutions(id),
      review_id TEXT REFERENCES solution_reviews(id), reference_id TEXT REFERENCES question_reference_answers(id),
      boundary TEXT NOT NULL CHECK(boundary IN ('observed','applies','excluded')),
      origin TEXT NOT NULL CHECK(origin IN ('ai','user')), note TEXT NOT NULL, snapshot_json TEXT NOT NULL, created_at REAL NOT NULL
    );
    CREATE INDEX candidate_evidence ON method_candidate_evidence(candidate_id, revision, question_id);
    CREATE TABLE skill_learning_jobs (
      question_id TEXT PRIMARY KEY REFERENCES questions(id),
      status TEXT NOT NULL CHECK(status IN ('pending','running','ready','failed')),
      attempt_token TEXT, snapshot_json TEXT NOT NULL, error TEXT NOT NULL, updated_at REAL NOT NULL
    );
    CREATE TABLE skill_learning_reports (
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES questions(id), attempt_token TEXT NOT NULL UNIQUE,
      model TEXT NOT NULL, report_json TEXT NOT NULL, snapshot_json TEXT NOT NULL, created_at REAL NOT NULL
    );
    """

  private static func skillJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private static func skillDecode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
  }

  func learningSnapshot(questionID: String) throws -> MathSkillLearningSnapshot {
    let db = try database()
    guard let asset = try query(db, "SELECT asset_id FROM questions WHERE id=? AND deleted_at IS NULL", [.text(questionID)], map: { Self.text($0,0) }).first else { throw MathQuestionStoreError.notFound }
    let answers = try solutions(questionID: questionID)
    let question = try record(questionID, db: db)
    return MathSkillLearningSnapshot(grade: question.grade, questionID: questionID, assetID: asset,
      ocrText: question.ocrText, solutions: answers,
      references: try referenceAnswers(questionID: questionID), reviews: try answers.flatMap { try reviews(solutionID: $0.id) })
  }

  func enqueueSkillLearning(questionID: String) throws {
    let snapshot = try Self.skillJSON(learningSnapshot(questionID: questionID))
    try execute(try database(), """
      INSERT INTO skill_learning_jobs(question_id,status,snapshot_json,error,updated_at) VALUES (?,'pending',?,'',?)
      ON CONFLICT(question_id) DO UPDATE SET status='pending',attempt_token=NULL,snapshot_json=excluded.snapshot_json,error='',updated_at=excluded.updated_at
      WHERE skill_learning_jobs.snapshot_json != excluded.snapshot_json OR skill_learning_jobs.status='failed'
      """, [.text(questionID),.text(snapshot),.real(Date().timeIntervalSinceReferenceDate)])
  }

  func pendingSkillLearningJobs() throws -> [MathSkillLearningJob] {
    try query(try database(), "SELECT j.question_id,j.status,j.error,j.updated_at FROM skill_learning_jobs j JOIN questions q ON q.id=j.question_id WHERE j.status='pending' AND q.deleted_at IS NULL ORDER BY j.updated_at,j.question_id", map: {
      .init(questionID: Self.text($0,0),status: Self.text($0,1),error: Self.text($0,2),updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,3)))
    })
  }

  func claimSkillLearning(questionID: String) throws -> MathSkillLearningAttempt? {
    let db = try database()
    return try transaction(db) {
      guard try query(db,"SELECT status FROM skill_learning_jobs WHERE question_id=?",[.text(questionID)],map:{Self.text($0,0)}).first == "pending" else { return nil }
      let snapshot = try learningSnapshot(questionID: questionID)
      let token = UUID().uuidString
      try execute(db,"UPDATE skill_learning_jobs SET status='running',attempt_token=?,snapshot_json=?,updated_at=? WHERE question_id=?",[.text(token),.text(Self.skillJSON(snapshot)),.real(Date().timeIntervalSinceReferenceDate),.text(questionID)])
      return .init(questionID: questionID,token: token,snapshot: snapshot)
    }
  }

  func recoverSkillLearning() throws {
    try execute(try database(), "UPDATE skill_learning_jobs SET status='pending',attempt_token=NULL WHERE status='running'")
  }

  func failSkillLearning(attempt: MathSkillLearningAttempt, error: String) throws {
    try execute(try database(),"UPDATE skill_learning_jobs SET status='failed',error=?,attempt_token=NULL,updated_at=? WHERE question_id=? AND attempt_token=? AND status='running'",[.text(String(error.prefix(1000))),.real(Date().timeIntervalSinceReferenceDate),.text(attempt.questionID),.text(attempt.token)])
  }

  func releaseSkillLearning(attempt: MathSkillLearningAttempt) throws {
    try execute(try database(),"UPDATE skill_learning_jobs SET status='pending',attempt_token=NULL WHERE question_id=? AND attempt_token=? AND status='running'",[.text(attempt.questionID),.text(attempt.token)])
  }

  func finishSkillLearning(attempt: MathSkillLearningAttempt, proposal: MathSkillProposal?, report: String, model: String, patternKey: String? = nil, evidenceSnapshots: [MathSkillLearningSnapshot] = []) throws {
    guard report.utf8.count <= 512_000,
      let object = try? JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any],
      object["native_research"] == nil, object["native_candidate_event"] == nil, object["human_decision"] == nil,
      !["approved", "rejected", "revision_required"].contains(object["status"] as? String ?? "")
    else { throw MathQuestionStoreError.database("后台教研报告不能生成或代替人工决定") }
    let db = try database()
    try transaction(db) {
      guard try query(db,"SELECT attempt_token FROM skill_learning_jobs WHERE question_id=? AND status='running'",[.text(attempt.questionID)],map:{Self.text($0,0)}).first == attempt.token else { return }
      let source = try Self.skillJSON(attempt.snapshot)
      let sources = [attempt.snapshot] + evidenceSnapshots.filter { $0.questionID != attempt.questionID }
      guard sources.count <= 24, Set(sources.map(\.questionID)).count == sources.count else {
        throw MathQuestionStoreError.database("重复依据的题号无效")
      }
      var unchanged = true
      for snapshot in sources {
        guard let current = try? learningSnapshot(questionID: snapshot.questionID),
          current == snapshot else { unchanged = false; break }
      }
      guard unchanged else {
        try execute(db,"UPDATE skill_learning_jobs SET status='pending',attempt_token=NULL WHERE question_id=?",[.text(attempt.questionID)]); return
      }
      try MathSkillLearningValidation.validate(object, sourceSnapshots: sources,
        allowedMethodIDs: Set(try automaticMethods().map(\.id)))
      if object["workflow_state"] != nil {
        let result = try MathSkillLearningResult.parse(report, questionIDs: Set(sources.map(\.questionID)))
        guard result.proposal == proposal, result.patternKey == (proposal?.signature ?? patternKey) else {
          throw MathQuestionStoreError.database("候选方法与冻结教研报告不一致")
        }
      }
      var durable = object
      if object["workflow_state"] != nil {
        durable["native_learning_sources"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sources))
      }
      let durableData = try JSONSerialization.data(withJSONObject: durable, options: .sortedKeys)
      guard durableData.count <= 512_000 else { throw MathQuestionStoreError.database("冻结的后台教研报告超过保存上限") }
      let durableReport = String(decoding: durableData, as: UTF8.self)
      let now = Date().timeIntervalSinceReferenceDate
      try execute(db,"INSERT INTO skill_learning_reports VALUES (?,?,?,?,?,?,?)",[.text(UUID().uuidString),.text(attempt.questionID),.text(attempt.token),.text(model),.text(durableReport),.text(source),.real(now)])
      if let signature = proposal?.signature ?? patternKey {
        guard signature.range(of: "^[a-z][a-z_-]{2,127}$", options: .regularExpression) != nil else { throw MathQuestionStoreError.database("模式标识必须为抽象数量关系") }
        var candidate = try listSkillCandidates().first { $0.proposal.signature == signature }
        if candidate == nil {
          let draft = proposal ?? MathSkillProposal(signature: signature,title: "观察中的新模式",category: "待积累",instructions: "",trigger: "",constraints: "",exclusions: "",prerequisites: "",supportedDiagrams: [])
          let id = UUID().uuidString
          try execute(db,"INSERT INTO method_candidates VALUES (?,?,?,1,?,NULL,?,?)",[.text(id),.text(signature),.text(Self.skillJSON(draft)),.text(proposal == nil ? "observing" : "draft"),.real(now),.real(now)])
          candidate = try listSkillCandidates().first { $0.id == id }
        } else if let proposal, candidate?.status == "observing", let id = candidate?.id {
          try execute(db,"UPDATE method_candidates SET proposal_json=?,status='draft',updated_at=? WHERE id=?",[.text(Self.skillJSON(proposal)),.real(now),.text(id)])
          candidate = try listSkillCandidates().first { $0.id == id }
        }
        if let candidate, !["published","rejected"].contains(candidate.status) {
          let previous = try candidateEvidence(id: candidate.id)
          let matched = (object["pattern_evidence_ids"] as? [String]).map(Set.init)
          for snapshot in sources where matched?.contains(snapshot.questionID) != false {
            let duplicate = previous.contains { $0.origin == "ai" && $0.candidateRevision == candidate.revision && $0.questionID == snapshot.questionID }
            if !duplicate { try insertSkillEvidence(candidate: candidate, snapshot: snapshot, boundary: "observed", origin: "ai", note: "自动观察；尚未人工确认", db: db) }
          }
        }
      }
      try execute(db,"UPDATE skill_learning_jobs SET status='ready',error='',attempt_token=NULL,updated_at=? WHERE question_id=?",[.real(now),.text(attempt.questionID)])
    }
  }

  func skillLearningReports(questionID: String) throws -> [MathSkillLearningReport] {
    try query(try database(),"SELECT id,question_id,attempt_token,model,report_json,snapshot_json,created_at FROM skill_learning_reports WHERE question_id=? ORDER BY created_at",[.text(questionID)],map:{
      .init(id: Self.text($0,0),questionID: Self.text($0,1),token: Self.text($0,2),model: Self.text($0,3),report: Self.text($0,4),snapshot: try Self.skillDecode(MathSkillLearningSnapshot.self,Self.text($0,5)),createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,6)))
    })
  }

  func listSkillCandidates() throws -> [MathSkillCandidate] {
    try query(try database(),"SELECT id,proposal_json,revision,status,published_version_id,created_at,updated_at FROM method_candidates ORDER BY updated_at DESC,id",map:{
      .init(id: Self.text($0,0),proposal: try Self.skillDecode(MathSkillProposal.self,Self.text($0,1)),revision: Int(sqlite3_column_int64($0,2)),status: Self.text($0,3),publishedVersionID: Self.optionalText($0,4),createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,5)),updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,6)))
    })
  }

  func editSkillCandidate(id: String, proposal: MathSkillProposal) throws {
    guard let candidate = try listSkillCandidates().first(where: {$0.id == id}), candidate.status != "published", proposal.signature == candidate.proposal.signature else { throw MathQuestionStoreError.database("已发布版本不可覆盖，或模式标识不一致") }
    guard !proposal.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
      proposal.title.count <= 256, proposal.category.count <= 256,
      proposal.instructions.utf8.count <= 48_000,
      (proposal.teachingPermissions?.isValid ?? true),
      proposal.supportedDiagrams.count <= 10,
      proposal.supportedDiagrams.allSatisfy({ MathDiagram.Kind(rawValue: $0) != nil })
    else { throw MathQuestionStoreError.database("候选名称、步骤或图形模板无效") }
    let db = try database()
    try transaction(db) {
      try recordCandidateEvent(candidate: candidate, decision: "previous_revision",
        reason: "修改草稿前保留原版本；不代表人工核验或批准", model: "native", db: db)
      try execute(db,"UPDATE method_candidates SET proposal_json=?,revision=revision+1,status='draft',updated_at=? WHERE id=?",[.text(Self.skillJSON(proposal)),.real(Date().timeIntervalSinceReferenceDate),.text(id)])
    }
  }

  func rejectSkillCandidate(id: String, note: String) throws {
    guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.count <= 4_000 else {
      throw MathQuestionStoreError.database("请说明拒绝原因（最多 4000 字）")
    }
    let db = try database()
    try transaction(db) {
      guard let candidate = try listSkillCandidates().first(where: { $0.id == id }),
        !["published", "rejected"].contains(candidate.status) else {
        throw MathQuestionStoreError.database("已发布或已拒绝的候选不能覆盖；请保留历史记录")
      }
      try recordCandidateEvent(candidate: candidate, decision: "rejected", reason: note, db: db)
      try execute(db, "UPDATE method_candidates SET status='rejected',updated_at=? WHERE id=?",
        [.real(Date().timeIntervalSinceReferenceDate), .text(id)])
    }
  }

  /// Merging changes the target revision. Existing human judgements remain history,
  /// while all source cases become observations requiring a fresh boundary judgement.
  func mergeSkillCandidates(sourceID: String, targetID: String, note: String) throws {
    guard sourceID != targetID, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      note.count <= 4_000 else { throw MathQuestionStoreError.database("请选择不同候选并说明合并原因") }
    let db = try database()
    try transaction(db) {
      let candidates = try listSkillCandidates()
      guard let source = candidates.first(where: { $0.id == sourceID }),
        let target = candidates.first(where: { $0.id == targetID }),
        ["observing", "draft", "review_required"].contains(source.status),
        ["observing", "draft", "review_required"].contains(target.status) else {
        throw MathQuestionStoreError.database("仅可合并未发布、未拒绝的候选；已发布版本须保留")
      }
      let sources = try candidateEvidence(id: targetID) + candidateEvidence(id: sourceID)
      let nextStatus = target.proposal.instructions.isEmpty ? "observing" : "draft"
      try execute(db, "UPDATE method_candidates SET revision=revision+1,status=?,updated_at=? WHERE id=?",
        [.text(nextStatus), .real(Date().timeIntervalSinceReferenceDate), .text(targetID)])
      let updated = MathSkillCandidate(id: target.id, proposal: target.proposal, revision: target.revision + 1,
        status: nextStatus, publishedVersionID: nil, createdAt: target.createdAt, updatedAt: Date())
      var seen = Set<String>()
      for entry in sources.reversed() where seen.insert(entry.questionID).inserted {
        try insertSkillEvidence(candidate: updated, snapshot: entry.snapshot, boundary: "observed", origin: "ai",
          note: "合并后待重新确认；原记录 " + entry.id, db: db)
      }
      try recordCandidateEvent(candidate: updated, decision: "merged", reason: note, sourceID: sourceID, db: db)
      try recordCandidateEvent(candidate: source, decision: "merged_into", reason: note, sourceID: targetID, db: db)
      try execute(db, "UPDATE method_candidates SET status='rejected',updated_at=? WHERE id=?",
        [.real(Date().timeIntervalSinceReferenceDate), .text(sourceID)])
    }
  }

  private func recordCandidateEvent(candidate: MathSkillCandidate, decision: String, reason: String,
    sourceID: String? = nil, model: String = "user", db: OpaquePointer) throws {
    guard let evidence = try candidateEvidence(id: candidate.id).last else {
      throw MathQuestionStoreError.database("候选缺少来源依据，不能记录审核决定")
    }
    let event = MathSkillCandidateEvent(candidateID: candidate.id, revision: candidate.revision,
      decision: decision, reason: reason, relatedCandidateID: sourceID, proposal: candidate.proposal)
    let object = ["native_candidate_event": event]
    try execute(db, "INSERT INTO skill_learning_reports VALUES (?,?,?,?,?,?,?)",
      [.text(UUID().uuidString), .text(evidence.questionID), .text(UUID().uuidString), .text(model),
        .text(Self.skillJSON(object)), .text(Self.skillJSON(evidence.snapshot)), .real(Date().timeIntervalSinceReferenceDate)])
  }

  func candidateEvents(id: String) throws -> [MathSkillCandidateEvent] {
    let rows = try query(try database(), "SELECT report_json FROM skill_learning_reports ORDER BY created_at,id",
      map: { Self.text($0, 0) })
    return rows.compactMap { row in
      guard let object = try? Self.skillDecode([String: MathSkillCandidateEvent].self, row),
        let event = object["native_candidate_event"], event.candidateID == id else { return nil }
      return event
    }
  }

  /// Export is a snapshot of the published version, never whichever method happens
  /// to be current after later edits. Revoked profiles are not reusable exports.
  func candidateSkillExport(id: String) throws -> MathSkillExport {
    let db = try database()
    guard let candidate = try listSkillCandidates().first(where: { $0.id == id }),
      candidate.status == "published", let versionID = candidate.publishedVersionID,
      let profile = try skillProfile(versionID: versionID), profile.status == "approved",
      let method = try query(db, "SELECT id,method_id,title,category,instructions,created_at FROM teaching_method_versions WHERE id=?",
        [.text(versionID)], map: { MathTeachingMethod(id: Self.text($0,1), versionID: Self.text($0,0),
          title: Self.text($0,2), category: Self.text($0,3), instructions: Self.text($0,4),
          createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,5))) }).first else {
      throw MathQuestionStoreError.database("只能导出已发布且仍获批准的方法版本")
    }
    let evidence = try candidateEvidence(id: id)
    let rows = try query(db, "SELECT report_json FROM skill_learning_reports ORDER BY created_at DESC,id",
      map: { Self.text($0,0) })
    guard let research = rows.first(where: { row in
      guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
        let native = object["native_research"] as? [String: Any] else { return false }
      return native["candidate_id"] as? String == id && native["revision"] as? Int == candidate.revision
        && object["status"] as? String == "approved"
    }) else { throw MathQuestionStoreError.database("已发布版本缺少人工批准教研记录") }
    return MathSkillExport(candidate: candidate, method: method, profile: profile,
      evidence: evidence, researchJSON: research, events: try candidateEvents(id: id))
  }

  func candidateEvidence(id: String) throws -> [MathSkillCandidateEvidence] {
    try query(try database(),"SELECT id,candidate_id,revision,question_id,asset_id,content_digest,solution_id,review_id,reference_id,boundary,origin,note,snapshot_json,created_at FROM method_candidate_evidence WHERE candidate_id=? ORDER BY created_at",[.text(id)],map: Self.readSkillCandidateEvidence)
  }
  static func readSkillCandidateEvidence(_ statement: OpaquePointer) throws -> MathSkillCandidateEvidence {
    .init(id: Self.text(statement,0), candidateID: Self.text(statement,1), candidateRevision: Int(sqlite3_column_int64(statement,2)),
      questionID: Self.text(statement,3), assetID: Self.text(statement,4), contentDigest: Self.text(statement,5),
      solutionID: Self.optionalText(statement,6), reviewID: Self.optionalText(statement,7), referenceID: Self.optionalText(statement,8),
      boundary: Self.text(statement,9), origin: Self.text(statement,10), note: Self.text(statement,11),
      snapshot: try Self.skillDecode(MathSkillLearningSnapshot.self,Self.text(statement,12)),
      createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement,13)))
  }

  private func insertSkillEvidence(candidate: MathSkillCandidate,snapshot: MathSkillLearningSnapshot,boundary: String,origin: String,note: String,solutionID: String? = nil,reviewID: String? = nil,referenceID: String? = nil,db: OpaquePointer) throws {
    let normalized = snapshot.ocrText.filter { !$0.isWhitespace }
    let digest = normalized.isEmpty ? snapshot.assetID : Self.digest(Data(normalized.utf8))
    try execute(db,"INSERT INTO method_candidate_evidence VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[.text(UUID().uuidString),.text(candidate.id),.integer(Int64(candidate.revision)),.text(snapshot.questionID),.text(snapshot.assetID),.text(digest),solutionID.map(Value.text) ?? .null,reviewID.map(Value.text) ?? .null,referenceID.map(Value.text) ?? .null,.text(boundary),.text(origin),.text(note),.text(Self.skillJSON(snapshot)),.real(Date().timeIntervalSinceReferenceDate)])
  }

  func loadSkillEvidenceReview(candidateID: String) throws -> MathSkillEvidenceReviewPackage {
    guard let candidate = try listSkillCandidates().first(where: { $0.id == candidateID }) else {
      throw MathQuestionStoreError.notFound
    }
    var seen = Set<String>()
    // Historical identities are navigation aids only; decisions always start undecided.
    let evidence = try candidateEvidence(id: candidateID)
    let sources = try evidence.filter { seen.insert($0.questionID).inserted }.map {
      try learningSnapshot(questionID: $0.questionID)
    }
    return .init(candidate: candidate, sources: sources)
  }

  /// One explicit human action, all-or-nothing. Neither loading nor confirming
  /// evidence approves research or publishes a reusable skill.
  func confirmSkillEvidenceReview(package: MathSkillEvidenceReviewPackage,
    items: [MathSkillEvidenceReviewItem], note: String, confirmed: Bool) throws {
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard confirmed, !note.isEmpty else {
      throw MathQuestionStoreError.database("请明确勾选已检查原题、答案步骤、图解和 App 展示，并填写审核意见")
    }
    let db = try database()
    try transaction(db) {
      guard let current = try listSkillCandidates().first(where: { $0.id == package.candidate.id }),
        current == package.candidate, current.status == "draft" else {
        throw MathQuestionStoreError.database("候选版本已变化或不是待审草稿，请重新打开集中核验")
      }
      let ids = package.sources.map(\.questionID)
      guard !items.isEmpty, Set(ids).count == ids.count,
        Set(items.map(\.questionID)).isSubset(of: Set(ids)),
        Set(items.map(\.questionID)).count == items.count,
        items.allSatisfy({ ["", "applies", "excluded"].contains($0.boundary)
          && ["confirmed", "rejected"].contains($0.answerStatus)
          && ($0.answerStatus != "rejected" || !$0.correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }) else {
        throw MathQuestionStoreError.database("所选依据须独立且明确判断答案过程正误；方法适用性可暂未判断，错误答案须填写原因或修正")
      }
      let selected = Dictionary(uniqueKeysWithValues: items.map { ($0.questionID, $0) })
      let reviewedSources = package.sources.filter { selected[$0.questionID] != nil }
      // Compare every selected complete source before any write, including newer
      // answers, references and reviews. Undecided cards are not being attested.
      for source in reviewedSources {
        guard try learningSnapshot(questionID: source.questionID) == source,
          let latest = source.solutions.last,
          !latest.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw MathQuestionStoreError.database("原题、最新答案或审核记录已变化，或缺少答案；请重新打开核验")
        }
        _ = try originalImage(questionID: source.questionID)
      }
      func digest(_ source: MathSkillLearningSnapshot) -> String {
        let text = source.ocrText.filter { !$0.isWhitespace }
        return text.isEmpty ? source.assetID : Self.digest(Data(text.utf8))
      }
      guard Set(reviewedSources.map(\.assetID)).count == items.count,
        Set(reviewedSources.map(digest)).count == items.count else {
        throw MathQuestionStoreError.database("来源须为独立原图及题文，不能重复计入同一道题")
      }
      // Saving a truthful review is independent of qualifying enough evidence
      // for research/publication; those existing gates remain authoritative.
      for source in reviewedSources {
        let item = selected[source.questionID]!
        let solution = source.solutions.last!
        let referenceID: String? = nil
        let review = MathSolutionReview(id: UUID().uuidString, solutionID: solution.id,
          status: item.answerStatus, scope: "答案及解题过程", note: note,
          correction: item.correction.trimmingCharacters(in: .whitespacesAndNewlines), referenceID: referenceID, createdAt: Date())
        try insertSolutionReview(review, questionID: source.questionID, db: db)
        // An answer judgment does not imply any method-applicability judgment.
        guard !item.boundary.isEmpty else { continue }
        let snapshot = try learningSnapshot(questionID: source.questionID)
        try insertSkillEvidence(candidate: current, snapshot: snapshot,
          boundary: item.boundary,
          origin: "user", note: note, solutionID: solution.id, reviewID: review.id,
          referenceID: referenceID, db: db)
      }
    }
  }

  func assessSkillCandidate(id: String,questionID: String,solutionID: String,reviewID: String,referenceID: String? = nil,boundary: String,note: String) throws {
    guard ["applies","excluded"].contains(boundary), !note.isEmpty,
      let candidate = try listSkillCandidates().first(where:{$0.id == id}),candidate.status == "draft" else { throw MathQuestionStoreError.database("请先完成候选草稿，并注明适用或排除依据") }
    let snapshot = try learningSnapshot(questionID:questionID)
    guard let review = snapshot.reviews.last(where:{$0.solutionID == solutionID}), review.id == reviewID, review.status == "confirmed", review.scope == "答案及解题过程", snapshot.solutions.contains(where:{$0.id == solutionID}), referenceID == nil || snapshot.references.contains(where:{$0.id == referenceID}) else { throw MathQuestionStoreError.database("需要当前答案及解题过程的人工核验记录") }
    try insertSkillEvidence(candidate:candidate,snapshot:snapshot,boundary:boundary,origin:"user",note:note,solutionID:solutionID,reviewID:reviewID,referenceID:referenceID,db:try database())
  }

  func publishSkillCandidate(id: String) throws -> MathTeachingMethod {
    let db = try database()
    return try transaction(db) {
      guard let candidate = try listSkillCandidates().first(where:{$0.id == id}),candidate.status == "draft", !candidate.proposal.instructions.isEmpty, !candidate.proposal.trigger.isEmpty, !candidate.proposal.exclusions.isEmpty else { throw MathQuestionStoreError.database("候选草稿尚不完整") }
      let evidence = try candidateEvidence(id:id).filter {$0.origin == "user" && $0.candidateRevision == candidate.revision}
      var valid: [MathSkillCandidateEvidence] = []
      for entry in evidence {
        guard let solutionID = entry.solutionID, let reviewID = entry.reviewID,
          let current = try? learningSnapshot(questionID:entry.questionID),
          let latest = current.reviews.last(where:{$0.solutionID == solutionID}), latest.id == reviewID,
          latest.status == "confirmed",latest.scope == "答案及解题过程" else { continue }
        valid.append(entry)
      }
      let positives = valid.filter {$0.boundary == "applies"}
      guard Set(positives.map(\.assetID)).count >= 2,Set(positives.map(\.contentDigest)).count >= 2,
        valid.contains(where:{$0.boundary == "excluded" && !Set(positives.map(\.assetID)).contains($0.assetID) && !Set(positives.map(\.contentDigest)).contains($0.contentDigest)}) else { throw MathQuestionStoreError.database("发布需要两道独立正例和一道独立排除反例，且人工确认答案与过程") }
      let attempt = try candidateResearchAttempt(id: id)
      guard let report = try researchReportObject(attempt: attempt),
        report["status"] as? String == "approved" else {
        throw MathQuestionStoreError.database("请先完成当前版本的教研审校，再明确批准方法")
      }
      let draft = candidate.proposal
      let instructions = """
        ## 适用条件
        \(draft.trigger)

        ## 排除条件
        \(draft.exclusions)

        ## 先修知识
        \(draft.prerequisites)

        ## 学段与审校限制
        \(draft.constraints)

        ## 允许的图形模板
        \(draft.supportedDiagrams.joined(separator: ", "))

        ## 解题步骤
        \(draft.instructions)
        """
      let method = MathTeachingMethod(id:"learned-" + candidate.id,versionID:UUID().uuidString,title:draft.title,category:draft.category,instructions:instructions,createdAt:Date(),teachingPermissions:draft.teachingPermissions)
      try execute(db,"INSERT INTO teaching_methods(id) VALUES (?)",[.text(method.id)])
      try execute(db,"INSERT INTO teaching_method_versions VALUES (?,?,?,?,?,?)",[.text(method.versionID),.text(method.id),.text(method.title),.text(method.category),.text(method.instructions),.real(method.createdAt.timeIntervalSinceReferenceDate)])
      try execute(db,"UPDATE teaching_methods SET current_version_id=? WHERE id=?",[.text(method.versionID),.text(method.id)])
      let profile = MathSkillProfile(versionID:method.versionID,trigger:draft.trigger,constraints:draft.constraints,exclusions:draft.exclusions,prerequisites:draft.prerequisites,supportedDiagrams:draft.supportedDiagrams,status:"approved",sourceInstructions:draft.instructions,teachingPermissions:draft.teachingPermissions)
      try execute(db,"INSERT INTO skill_profiles VALUES (?,?,'approved')",[.text(method.versionID),.text(Self.skillJSON(profile))])
      try execute(db,"INSERT INTO skill_lifecycle_events VALUES (?,?,'approved',?,?)",[.text(UUID().uuidString),.text(method.versionID),.text("用户发布已核验候选 " + candidate.id),.real(Date().timeIntervalSinceReferenceDate)])
      try execute(db,"UPDATE method_candidates SET status='published',published_version_id=?,updated_at=? WHERE id=?",[.text(method.versionID),.real(Date().timeIntervalSinceReferenceDate),.text(id)])
      return method
    }
  }

  /// Current human evidence for the saved revision, including drafts with fewer
  /// than three entries. This read-only view uses the same freshness checks as
  /// research submission, so the UI never counts stale historical assessments.
  func candidateCurrentEvidence(id: String) throws -> [MathSkillCandidateEvidence] {
    guard let candidate = try listSkillCandidates().first(where: { $0.id == id }), candidate.status == "draft" else {
      throw MathQuestionStoreError.database("请先完成候选草稿")
    }
    var latest: [String: MathSkillCandidateEvidence] = [:]
    for entry in try candidateEvidence(id: id) where entry.origin == "user" && entry.candidateRevision == candidate.revision {
      latest[entry.questionID] = entry
    }
    var valid: [MathSkillCandidateEvidence] = []
    for entry in latest.values {
      guard let source = try? learningSnapshot(questionID: entry.questionID), source == entry.snapshot,
        let review = source.reviews.last(where: { $0.solutionID == entry.solutionID }),
        review.id == entry.reviewID, review.status == "confirmed", review.scope == "答案及解题过程" else { continue }
      valid.append(entry)
    }
    valid.sort { $0.questionID < $1.questionID }
    return valid
  }

  func candidateResearchAttempt(id: String) throws -> MathSkillResearchAttempt {
    guard let candidate = try listSkillCandidates().first(where: { $0.id == id }), candidate.status == "draft" else {
      throw MathQuestionStoreError.database("请先完成候选草稿")
    }
    let valid = try candidateCurrentEvidence(id: id)
    guard valid.count >= 3, valid.count <= 24 else {
      throw MathQuestionStoreError.database("教研审校需要至少三条当前版本的人工过程核验依据")
    }
    return .init(candidateID: id, revision: candidate.revision, proposal: candidate.proposal, evidence: valid)
  }

  private static func researchBinding(_ attempt: MathSkillResearchAttempt) throws -> String {
    Self.digest(Data(try Self.skillJSON(attempt).utf8))
  }

  func candidateResearchReport(attempt: MathSkillResearchAttempt) throws -> String? {
    guard let object = try researchReportObject(attempt: attempt) else { return nil }
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
  }

  private func researchReportObject(attempt: MathSkillResearchAttempt) throws -> [String: Any]? {
    let binding = try Self.researchBinding(attempt)
    let rows = try query(try database(), "SELECT report_json FROM skill_learning_reports ORDER BY created_at DESC", map: { Self.text($0, 0) })
    for row in rows {
      guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
        let native = object["native_research"] as? [String: Any],
        native["candidate_id"] as? String == attempt.candidateID,
        native["revision"] as? Int == attempt.revision,
        native["binding"] as? String == binding else { continue }
      return object
    }
    return nil
  }

  func recordCandidateResearch(attempt: MathSkillResearchAttempt, report: String, model: String) throws {
    let db = try database()
    try transaction(db) {
      guard try candidateResearchAttempt(id: attempt.candidateID) == attempt else {
        throw MathQuestionStoreError.database("方法或核验依据已更新，请重新教研审校")
      }
      let result = try MathSkillLearningResult.parse(report, questionIDs: Set(attempt.evidence.map(\.questionID)))
      guard let proposal = result.proposal, proposal.signature == attempt.proposal.signature,
        proposal.title == attempt.proposal.title, proposal.category == attempt.proposal.category,
        proposal.instructions == attempt.proposal.instructions, proposal.trigger == attempt.proposal.trigger,
        proposal.exclusions == attempt.proposal.exclusions, proposal.prerequisites == attempt.proposal.prerequisites,
        proposal.supportedDiagrams == attempt.proposal.supportedDiagrams,
        var object = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any],
        ["awaiting_human", "approved"].contains(object["status"] as? String ?? ""),
        let research = object["review"] as? [String: Any], let checks = research["checks"] as? [[String: Any]],
        checks.count == 5, Set(checks.compactMap { $0["dimension"] as? String }) == ["mathematics", "grade_scope", "conditions", "counterexamples", "diagram_grounding"],
        checks.allSatisfy({ ($0["passed"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true && ($0["reason"] as? String)?.isEmpty == false })
      else { throw MathQuestionStoreError.database("教研报告未准确对应当前方法和五项检查") }
      let learning = attempt.learningObject
      let candidate = learning["candidate"] as? [String: Any]
      try MathSkillResearchValidation.validate(object, evidence: learning["evidence"], proposal: candidate?["proposal"])
      if object["status"] as? String == "approved" {
        guard checks.allSatisfy({ $0["passed"] as? Bool == true }), research["recommendation"] as? String == "ready_for_human",
          let decision = object["human_decision"] as? [String: Any], decision["action"] as? String == "approve",
          (decision["reviewer"] as? String)?.isEmpty == false, (decision["note"] as? String)?.isEmpty == false,
          let prior = try researchReportObject(attempt: attempt), prior["status"] as? String == "awaiting_human",
          let before = prior["review"], let after = object["review"],
          try JSONSerialization.data(withJSONObject: before, options: .sortedKeys) == JSONSerialization.data(withJSONObject: after, options: .sortedKeys)
        else { throw MathQuestionStoreError.database("缺少当前教研检查和明确的人工批准记录") }
      }
      let proposalProof = try JSONSerialization.jsonObject(with: Data(Self.skillJSON(attempt.proposal).utf8))
      object["native_research"] = ["candidate_id": attempt.candidateID, "revision": attempt.revision,
        "binding": try Self.researchBinding(attempt), "evidence_ids": attempt.evidence.map(\.id), "proposal": proposalProof]
      let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
      guard text.utf8.count <= 512_000 else { throw MathQuestionStoreError.database("教研报告和来源绑定过大，请减少本次核验依据") }
      let first = attempt.evidence[0].snapshot
      try execute(db,"INSERT INTO skill_learning_reports VALUES (?,?,?,?,?,?,?)",[.text(UUID().uuidString),.text(first.questionID),.text(UUID().uuidString),.text(model),.text(text),.text(Self.skillJSON(first)),.real(Date().timeIntervalSinceReferenceDate)])
    }
  }

  func skillProfile(versionID:String) throws -> MathSkillProfile? {
    try query(try database(),"SELECT profile_json FROM skill_profiles WHERE version_id=?",[.text(versionID)],map:{try Self.skillDecode(MathSkillProfile.self,Self.text($0,0))}).first
  }
  func saveSkillProfile(profile:MathSkillProfile) throws {
    try Self.validateSkillProfile(profile)
    if let old = try skillProfile(versionID: profile.versionID) {
      var normalized = profile; normalized.status = old.status
      guard normalized == old else { throw MathQuestionStoreError.database("修改教研资料须保存为新方法版本") }
      return
    }
    guard profile.teachingPermissions == nil else { throw MathQuestionStoreError.database("教学权限须保存为新方法版本") }
    var draft=profile; draft.status="draft"
    try execute(try database(),"INSERT INTO skill_profiles VALUES (?,?,'draft')",[.text(profile.versionID),.text(Self.skillJSON(draft))])
  }
  private static func validateSkillProfile(_ profile: MathSkillProfile) throws {
    guard !profile.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !profile.exclusions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !profile.prerequisites.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      [profile.trigger, profile.constraints, profile.exclusions, profile.prerequisites].allSatisfy({ $0.utf8.count <= 12_000 }),
      (profile.sourceInstructions?.utf8.count ?? 0) <= 96_000, (profile.teachingPermissions?.isValid ?? true),
      profile.supportedDiagrams.count <= 10,
      Set(profile.supportedDiagrams).count == profile.supportedDiagrams.count,
      profile.supportedDiagrams.allSatisfy({ MathDiagram.Kind(rawValue: $0) != nil })
    else { throw MathQuestionStoreError.database("请填写适用条件、排除条件和先修知识，并使用支持的图解模板") }
  }

  /// A profile edit creates a new method version; the prior source and review stay intact.
  func saveSkillProfileRevision(method: MathTeachingMethod, profile: MathSkillProfile) throws -> MathTeachingMethod {
    try Self.validateSkillProfile(profile)
    guard profile.versionID == method.versionID else { throw MathQuestionStoreError.database("教研资料对应的方法版本已改变") }
    let db = try database()
    return try transaction(db) {
      guard try methods().contains(method) else { throw MathQuestionStoreError.database("方法已更新或停用，请重新打开教研档案") }
      let prior = try skillProfile(versionID: method.versionID)
      let source = prior?.sourceInstructions ?? method.instructions
      guard source.utf8.count <= 96_000 else {
        throw MathQuestionStoreError.database("原方法全文超过教研档案容量，未修改方法或截断来源")
      }
      let permissionText = profile.teachingPermissions.map { "结构化教学权限：\n\($0.summary)\n\n" } ?? ""
      let rules = permissionText + "教研适用条件：\n\(profile.trigger)\n\n学段与限制：\n\(profile.constraints)\n\n排除条件：\n\(profile.exclusions)\n\n先修知识：\n\(profile.prerequisites)\n\n可用图解：\n\(profile.supportedDiagrams.joined(separator: "、"))\n\n原方法全文：\n\(source)"
      guard rules.utf8.count <= 96_000 else {
        throw MathQuestionStoreError.database("完整方法与教研资料超过96 KB，未截断或修改来源，请精简新增资料后重试")
      }
      let saved = MathTeachingMethod(id: method.id, versionID: UUID().uuidString,
        title: method.title, category: method.category, instructions: rules, createdAt: Date(), teachingPermissions: profile.teachingPermissions)
      try execute(db, "INSERT INTO teaching_method_versions(id,method_id,title,category,instructions,created_at) VALUES (?,?,?,?,?,?)", [
        .text(saved.versionID), .text(saved.id), .text(saved.title), .text(saved.category), .text(saved.instructions), .real(saved.createdAt.timeIntervalSinceReferenceDate)])
      try execute(db, "UPDATE teaching_methods SET current_version_id=? WHERE id=?", [.text(saved.versionID), .text(saved.id)])
      let draft = MathSkillProfile(versionID: saved.versionID, trigger: profile.trigger, constraints: profile.constraints,
        exclusions: profile.exclusions, prerequisites: profile.prerequisites, supportedDiagrams: profile.supportedDiagrams,
        sourceInstructions: source, teachingPermissions: profile.teachingPermissions)
      try execute(db, "INSERT INTO skill_profiles VALUES (?,?,'draft')", [.text(saved.versionID), .text(Self.skillJSON(draft))])
      try execute(db, "INSERT INTO skill_lifecycle_events VALUES (?,?,'draft',?,?)", [.text(UUID().uuidString), .text(saved.versionID),
        .text("由版本 \(method.versionID) 保存教研资料；旧审核不认证新版本"), .real(Date().timeIntervalSinceReferenceDate)])
      return saved
    }
  }

  func skillLifecycleEvents(versionID: String) throws -> [MathSkillLifecycleEvent] {
    try query(try database(), "SELECT id,decision,note,created_at FROM skill_lifecycle_events WHERE version_id=? ORDER BY created_at,id", [.text(versionID)], map: {
      .init(id: Self.text($0,0), decision: Self.text($0,1), note: Self.text($0,2), createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0,3)))
    })
  }
  /// Capture sources and actual usages without treating AI answers as human verification.
  func profileResearchAttempt(method: MathTeachingMethod) throws -> MathSkillProfileResearchAttempt {
    guard try methods().contains(method) else { throw MathQuestionStoreError.database("方法已更新或停用，请重新打开教研档案") }
    let catalogue = try MathTeachingReviewCatalogue.load()
    let stored = try skillProfile(versionID: method.versionID)
    var profile = stored ?? catalogue.seed(for: method) ?? MathSkillProfile(versionID: method.versionID,
      trigger: "", constraints: "小学四年级，优先算术；待补充教学与学段要求", exclusions: "", prerequisites: "", supportedDiagrams: [], sourceInstructions: method.instructions)
    profile.status = "draft"
    let source = MathTeachingMethod(id: method.id, versionID: method.versionID, title: method.title,
      category: method.category, instructions: profile.sourceInstructions ?? method.instructions, createdAt: method.createdAt)
    let reference = catalogue.reference(for: source)
    var evidence: [MathSkillProfileResearchAttempt.Evidence] = []
    for example in catalogue.cases.filter({ reference?.evidence_case_ids.contains($0.id) == true }).prefix(12) {
      guard let name = reference?.skill_name else { continue }
      let positive = example.expected_methods.contains(name) || example.expected_visuals.contains(name)
      let excluded = example.forbidden_methods.contains(name)
      guard example.kind != "source_quarantine", positive != excluded else { continue }
      evidence.append(.init(questionID: "teaching-case:" + example.id, text: example.stem, answer: "", referenceAnswer: "",
        verification: "unverified", role: excluded ? "excluded" : "positive",
        grade: example.grade, userConstraint: example.user_constraint, provenance: "项目待审案例：\(example.kind)，不是用户确认或原题图"))
    }
    var snapshots: [MathSkillLearningSnapshot] = []
    let ids = try query(try database(), """
      SELECT DISTINCT q.id FROM questions q JOIN question_solutions s ON s.question_id=q.id
      WHERE q.deleted_at IS NULL AND instr(s.method_snapshot,?)>0 ORDER BY q.id
      """, [.text(method.versionID)], map: { Self.text($0,0) })
    for id in ids {
      let snapshot = try learningSnapshot(questionID: id)
      guard let solution = snapshot.solutions.last(where: { $0.method == method || $0.visualMethods.contains(method) }) else { continue }
      let latest = snapshot.reviews.last { $0.solutionID == solution.id }
      let confirmed = solution.verificationStatus == "confirmed" && latest?.status == "confirmed" && latest?.scope == "答案及解题过程"
      let answer = snapshot.references.first { $0.id == latest?.referenceID }
      evidence.append(.init(questionID: id, text: String(snapshot.ocrText.prefix(6000)), answer: String(solution.answer.prefix(6000)),
        referenceAnswer: String((answer?.text ?? "").prefix(6000)), verification: confirmed ? "confirmed" : "unverified",
        role: "positive", grade: snapshot.grade, userConstraint: String(solution.question.prefix(2000)),
        provenance: "本机题库当前方法版本实际调用；提交文字为至多6000字摘要，完整快照另存；未人工核验的回答不能认证方法"))
      snapshots.append(snapshot)
      if snapshots.count >= 12 { break }
    }
    let references = reference?.source_references.map { MathSkillProfileResearchAttempt.Source(locator: $0.locator, sha256: $0.sha256) } ?? []
    return .init(method: method, profile: profile, evidence: evidence, sourceReferences: references, questionSnapshots: snapshots)
  }

  func recordProfileResearch(attempt: MathSkillProfileResearchAttempt, report: String, model: String) throws {
    try Task.checkCancellation()
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 1000,
      try profileResearchAttempt(method: attempt.method) == attempt
    else { throw MathQuestionStoreError.database("方法或例题依据已改变，旧评估未写入当前版本，请重新教研") }
    let result = try MathSkillProfileResearchResult.parse(report, attempt: attempt)
    let archive = MathSkillProfileResearchArchive(version: 1, model: model, attempt: attempt, result: result)
    let note = try Self.skillJSON(archive)
    guard note.utf8.count <= 2_000_000 else { throw MathQuestionStoreError.database("教研依据和完整快照过大，请减少关联题目") }
    try execute(try database(), "INSERT INTO skill_lifecycle_events VALUES (?,?,'ai_research',?,?)", [
      .text(UUID().uuidString), .text(attempt.method.versionID), .text(note), .real(Date().timeIntervalSinceReferenceDate)])
  }

  func profileResearchArchives(versionID: String) throws -> [MathSkillProfileResearchArchive] {
    try skillLifecycleEvents(versionID: versionID).filter { $0.decision == "ai_research" }.map {
      let archive = try Self.skillDecode(MathSkillProfileResearchArchive.self, $0.note)
      guard archive.version == 1, archive.attempt.method.versionID == versionID else { throw MathQuestionStoreError.incompatibleDatabase }
      try archive.result.validate(attempt: archive.attempt)
      return archive
    }
  }

  func reviewSkillProfile(versionID:String,approved:Bool,note:String) throws {
    guard !note.isEmpty,var profile=try skillProfile(versionID:versionID) else { throw MathQuestionStoreError.database("请先填写技能资料与审校依据") }
    profile.status=approved ? "approved" : "review_required"
    let db=try database()
    try transaction(db){
      try execute(db,"UPDATE skill_profiles SET profile_json=?,status=? WHERE version_id=?",[.text(Self.skillJSON(profile)),.text(profile.status),.text(versionID)])
      try execute(db,"INSERT INTO skill_lifecycle_events VALUES (?,?,?,?,?)",[.text(UUID().uuidString),.text(versionID),.text(profile.status),.text(note),.real(Date().timeIntervalSinceReferenceDate)])
    }
  }
  func reviewCurrentSkillProfile(method: MathTeachingMethod, approved: Bool, note: String) throws {
    guard try methods().contains(method) else { throw MathQuestionStoreError.database("方法版本已改变，请重新打开教研档案") }
    try reviewSkillProfile(versionID: method.versionID, approved: approved, note: note)
  }
  func revokeCurrentSkillMethod(method: MathTeachingMethod, note: String) throws {
    guard try methods().contains(method) else { throw MathQuestionStoreError.database("方法版本已改变，请重新打开教研档案") }
    try revokeSkillMethod(versionID: method.versionID, note: note)
  }
  func revokeSkillMethod(versionID:String,note:String) throws {
    guard !note.isEmpty else { throw MathQuestionStoreError.database("请说明复核原因") }
    let db=try database()
    try transaction(db){
      if var profile=try skillProfile(versionID:versionID){
        profile.status="revoked"
        try execute(db,"UPDATE skill_profiles SET profile_json=?,status='revoked' WHERE version_id=?",[.text(Self.skillJSON(profile)),.text(versionID)])
      } else {
        let profile=MathSkillProfile(versionID:versionID,trigger:"待复核",constraints:note,exclusions:"待复核",prerequisites:"",supportedDiagrams:[],status:"revoked")
        try execute(db,"INSERT INTO skill_profiles VALUES (?,?,'revoked')",[.text(versionID),.text(Self.skillJSON(profile))])
      }
      try execute(db,"INSERT INTO skill_lifecycle_events VALUES (?,?,'revoked',?,?)",[.text(UUID().uuidString),.text(versionID),.text(note),.real(Date().timeIntervalSinceReferenceDate)])
    }
  }
  func automaticMethods() throws -> [MathTeachingMethod] {
    let db=try database()
    return try query(db,"SELECT m.id,v.id,v.title,v.category,v.instructions,v.created_at FROM teaching_methods m JOIN teaching_method_versions v ON v.id=m.current_version_id LEFT JOIN skill_profiles p ON p.version_id=v.id WHERE m.archived_at IS NULL AND ((p.version_id IS NULL AND NOT EXISTS (SELECT 1 FROM skill_profiles oldp JOIN teaching_method_versions oldv ON oldv.id=oldp.version_id WHERE oldv.method_id=m.id)) OR p.status='approved') ORDER BY v.created_at DESC,m.id",map:Self.readMethod).map { try methodWithPermissions($0) }
  }

  /// Every retained version is archived; only the current approved catalogue is active.
  func projectSkillSnapshots(versionID: String? = nil) throws -> [MathProjectSkillSnapshot] {
    let db = try database()
    let automatic = Set(try automaticMethods().map(\.versionID))
    let versions = try query(db, "SELECT method_id,id,title,category,instructions,created_at FROM teaching_method_versions ORDER BY method_id,created_at,id", map: Self.readMethod)
    guard versions.count <= 2_000 else { throw MathQuestionStoreError.database("项目技能超过2000个版本，请先整理历史；未截断导出") }
    let catalogue = try MathTeachingReviewCatalogue.load()
    var ordinals: [String:Int] = [:]
    return try versions.compactMap { raw -> MathProjectSkillSnapshot? in
      ordinals[raw.id, default: 0] += 1
      guard versionID == nil || raw.versionID == versionID else { return nil }
      let method = try methodWithPermissions(raw)
      let profile = try skillProfile(versionID: method.versionID)
      let policy = MathMethodMatcher.eligibilityPolicy(for: method, catalogue: catalogue)
      let known = policy?.schema_version == 1 || (method.teachingPermissions?.isComplete == true)
      let candidate = try query(db, "SELECT id FROM method_candidates WHERE published_version_id=?", [.text(method.versionID)], map: { Self.text($0,0) }).first
      let lifecycle = try skillLifecycleEvents(versionID: method.versionID).filter { $0.decision != "project_sync" }.map {
        MathSkillLifecycleEventSnapshot(id: $0.id, decision: $0.decision, note: $0.note, createdAt: $0.createdAt)
      }
      var review: MathProjectCandidateReviewSnapshot?
      if let candidateID = candidate, let entry = try listSkillCandidates().first(where: { $0.id == candidateID }) {
        let reports = try query(db, "SELECT report_json FROM skill_learning_reports ORDER BY created_at DESC,id", map: { Self.text($0,0) })
        guard let research = reports.first(where: { json in
          guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String:Any],
            let native = object["native_research"] as? [String:Any] else { return false }
          return native["candidate_id"] as? String == candidateID && native["revision"] as? Int == entry.revision
            && object["status"] as? String == "approved"
        }) else { throw MathQuestionStoreError.database("已发布技能缺少教研依据，未生成不完整项目快照") }
        review = .init(candidate: entry, evidence: try candidateEvidence(id: candidateID), researchJSON: research, events: try candidateEvents(id: candidateID))
      }
      return MathProjectSkillSnapshot(method: method, profile: profile, versionOrdinal: ordinals[method.id]!,
        automaticEligible: automatic.contains(method.versionID) && known, candidateID: candidate, lifecycle: lifecycle, candidateReview: review)
    }
  }

  func recordProjectSkillSync(_ receipt: MathSkillProjectSyncReceipt, snapshot: MathProjectSkillSnapshot) throws {
    try receipt.validate()
    guard receipt.methodID == snapshot.method.id, receipt.versionID == snapshot.method.versionID,
      try projectSkillSnapshots(versionID: receipt.versionID).first == snapshot else {
      throw MathQuestionStoreError.database("项目同步期间方法发生改变，请重试")
    }
    let previous = try query(try database(), "SELECT note FROM skill_lifecycle_events WHERE version_id=? AND decision='project_sync' ORDER BY created_at DESC,id LIMIT 1",
      [.text(receipt.versionID)], map: { try Self.skillDecode(MathSkillProjectSyncReceipt.self, Self.text($0,0)) }).first
    if let previous, previous.projectDirectory == receipt.projectDirectory, previous.relativePath == receipt.relativePath,
      previous.artifactSHA256 == receipt.artifactSHA256, previous.status == receipt.status, previous.error == receipt.error { return }
    try execute(try database(), "INSERT INTO skill_lifecycle_events VALUES (?,?,'project_sync',?,?)", [
      .text(UUID().uuidString), .text(receipt.versionID), .text(Self.skillJSON(receipt)), .real(receipt.createdAt.timeIntervalSinceReferenceDate)])
  }
}

/// A separate, local photo archive. OCR is replaceable search text; it never owns the original.
actor MathQuestionStore {
  nonisolated let directory: URL
  // The owner alone closes the connection. Its handle never leaves this actor's synchronous
  // methods; @unchecked Sendable covers only transfer of ownership into deinitialization.
  private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close_v2(handle) }
  }
  private var connection: Connection?
  private static let applicationID: Int64 = 0x4D41_5448
  private static let schemaVersion: Int64 = MathQuestionArchive.supportedVersion
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/VocabCapture/math-questions", isDirectory: true)
  }

  func save(_ request: MathQuestionSaveRequest) throws -> MathQuestionRecord {
    guard !request.captureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MathQuestionStoreError.invalidCapture
    }
    let image = try Self.inspectImage(request.imageData)
    let db = try database()
    let hash = Self.digest(request.imageData)
    let filename = "\(hash).\(image.extensionName)"
    // The byte-identical, synced original must exist before a committed record can reference it.
    try persistOriginal(request.imageData, filename: filename)
    let id = try transaction(db) {
      if let existing = try query(
        db,
        "SELECT id, asset_id FROM questions WHERE capture_id = ?", [.text(request.captureID)],
        map: { (Self.text($0, 0), Self.text($0, 1)) }
      ).first {
        guard existing.1 == hash else { throw MathQuestionStoreError.conflictingCapture }
        try execute(
          db, "UPDATE questions SET updated_at = ? WHERE id = ?",
          [.real(Date().timeIntervalSinceReferenceDate), .text(existing.0)])
        try appendSolutions(request.solutions, questionID: existing.0, db: db)
        // A later OCR result can fill an empty index without overwriting user-reviewed text.
        if !request.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          try execute(
            db,
            """
            UPDATE question_ocr SET text = ?, status = 'ready', updated_at = ?
            WHERE question_id = ? AND status != 'ready'
            """,
            [
              .text(request.ocrText), .real(Date().timeIntervalSinceReferenceDate),
              .text(existing.0),
            ])
        }
        let indexed = try record(existing.0, db: db)
        if indexed.ocrStatus == "ready" {
          try nameUnnamedQuestion(existing.0, text: indexed.ocrText, db: db)
        }
        return existing.0
      }
      let now = Date().timeIntervalSinceReferenceDate
      let id = UUID().uuidString
      try execute(
        db,
        """
        INSERT INTO image_assets(id, filename, media_type, byte_count, width, height, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """,
        [
          .text(hash), .text(filename), .text(image.mediaType),
          .integer(Int64(request.imageData.count)),
          .integer(Int64(image.width)), .integer(Int64(image.height)), .real(now),
        ])
      try execute(
        db,
        """
        INSERT INTO questions(id, capture_id, asset_id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          .text(id), .text(request.captureID), .text(hash),
          .text(Self.suggestedTitle(from: request.ocrText) ?? "未命名题目"), .real(now), .real(now),
        ])
      let status =
        request.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "pending" : "ready"
      try execute(
        db, "INSERT INTO question_ocr(question_id, text, status, updated_at) VALUES (?, ?, ?, ?)",
        [.text(id), .text(request.ocrText), .text(status), .real(now)])
      try appendSolutions(request.solutions, questionID: id, db: db)
      return id
    }
    return try record(id, db: db)
  }

  func list(query search: String = "", grade: Int? = nil, tags: [MathQuestionTag] = []) throws
    -> [MathQuestionRecord]
  {
    try Self.validateGrade(grade)
    for tag in tags { try Self.validateTagIdentity(tag) }
    let db = try database()
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    var condition = """
      WHERE q.deleted_at IS NULL AND (? = '' OR instr(lower(q.title), lower(?)) > 0
        OR instr(lower(o.text), lower(?)) > 0)
      """
    var values: [Value] = [.text(term), .text(term), .text(term)]
    if let grade {
      condition += " AND q.grade = ?"
      values.append(.integer(Int64(grade)))
    }
    for tag in tags {
      condition += """
         AND EXISTS (SELECT 1 FROM question_tags t WHERE t.question_id = q.id
          AND t.axis = ? AND t.tag_id = ? AND t.catalogue_version = ? AND (t.status = 'confirmed' OR (t.origin = 'ai' AND t.status = 'suggested')))
        """
      values += [.text(tag.axis), .text(tag.tagID), .text(tag.catalogueVersion)]
    }
    return try query(
      db, Self.recordSelect + " " + condition + " ORDER BY q.created_at DESC, q.id",
      values, map: Self.readRecord)
  }

  func tags(questionID: String) throws -> [MathQuestionTag] {
    let db = try database()
    _ = try record(questionID, db: db)
    return try query(
      db,
      """
      SELECT axis, tag_id, catalogue_version, label, origin, status FROM question_tags
      WHERE question_id = ? ORDER BY axis, label, tag_id, catalogue_version
      """, [.text(questionID)], map: Self.readTag)
  }

  /// Replaces the complete classification snapshot, including retained legacy catalogue tags.
  /// No answer, review, OCR, method or image data is changed by this transaction.
  func updateClassification(questionID: String, grade: Int?, tags: [MathQuestionTag]) throws {
    try updateClassificationSnapshot(questionID: questionID, grade: grade, tags: tags)
  }

  /// Read and merge inside the write transaction so editing one dimension never erases another.
  func updateTagAxis(questionID: String, axis: String, tags: [MathQuestionTag]) throws {
    guard ["question_form", "curriculum_knowledge", "problem_family", "custom"].contains(axis),
      tags.allSatisfy({ $0.axis == axis && $0.status != "rejected" })
    else { throw MathQuestionStoreError.database("标签必须属于当前维度") }
    try updateClassificationSnapshot(
      questionID: questionID, grade: nil, tags: tags, editingAxis: axis)
  }

  func updateQuestionGrade(questionID: String, grade: Int?) throws {
    try updateClassificationSnapshot(
      questionID: questionID, grade: grade, tags: [], gradeOnly: true)
  }

  private func updateClassificationSnapshot(
    questionID: String, grade: Int?, tags incoming: [MathQuestionTag],
    editingAxis: String? = nil, gradeOnly: Bool = false
  ) throws {
    try Self.validateGrade(grade)
    var identities = Set<String>()
    for tag in incoming {
      try Self.validateTagIdentity(tag)
      guard !tag.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        ["user", "teacher", "ai"].contains(tag.origin),
        ["suggested", "confirmed", "rejected"].contains(tag.status),
        identities.insert(tag.key).inserted
      else { throw MathQuestionStoreError.database("标签名称、来源、状态无效，或标签重复") }
    }
    let db = try database()
    try transaction(db) {
      let current = try record(questionID, db: db)
      let existing = try self.tags(questionID: questionID)
      let grade = editingAxis == nil ? grade : current.grade
      let tags =
        gradeOnly
        ? existing
        : editingAxis.map { axis in
          existing.filter { $0.axis != axis } + incoming
        } ?? incoming
      // A removed automatic label is an explicit rejection, not a transient deletion.
      let retainedKeys = Set(tags.map(\.key))
      let tombstones = existing.filter {
        !retainedKeys.contains($0.key) && ($0.axis != "custom" || $0.status == "rejected")
      }.map {
        MathQuestionTag(
          axis: $0.axis, tagID: $0.tagID, catalogueVersion: $0.catalogueVersion,
          label: $0.label, origin: $0.origin, status: "rejected")
      }
      try execute(
        db,
        "UPDATE questions SET grade = ?, updated_at = ?, classification_revision = classification_revision + 1 WHERE id = ?",
        [
          grade.map { .integer(Int64($0)) } ?? .null,
          .real(Date().timeIntervalSinceReferenceDate), .text(questionID),
        ])
      try execute(db, "DELETE FROM question_tags WHERE question_id = ?", [.text(questionID)])
      for tag in tags + tombstones {
        try execute(
          db,
          """
          INSERT INTO question_tags(question_id, axis, tag_id, catalogue_version, label, origin, status)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
          [
            .text(questionID), .text(tag.axis), .text(tag.tagID), .text(tag.catalogueVersion),
            .text(tag.label), .text(tag.origin), .text(tag.status),
          ])
      }
    }
  }

  /// Active automatic labels are immediately searchable, with their provenance preserved.
  func tagOptions() throws -> [MathQuestionTag] {
    let db = try database()
    let saved = try query(
      db,
      """
      SELECT t.axis, t.tag_id, t.catalogue_version, t.label, t.origin, t.status
      FROM question_tags t JOIN questions q ON q.id = t.question_id
      WHERE q.deleted_at IS NULL AND (t.status = 'confirmed' OR (t.origin = 'ai' AND t.status = 'suggested'))
      ORDER BY t.axis, t.label, t.tag_id, t.catalogue_version, q.id
      """, map: Self.readTag)
    var identities = Set<String>()
    return saved.filter { identities.insert($0.key).inserted }
  }

  @discardableResult
  func enqueueAutomaticTags(questionID: String, force: Bool = false) throws -> Bool {
    let db = try database()
    return try transaction(db) {
      guard
        try query(
          db, "SELECT id FROM questions WHERE id = ? AND deleted_at IS NULL", [.text(questionID)],
          map: { Self.text($0, 0) }
        ).first != nil
      else { return false }
      let job = try automaticTagJob(questionID: questionID)
      guard job == nil || (force && job?.status != "running") else { return false }
      try execute(
        db,
        """
        INSERT INTO question_auto_tag_jobs(question_id, status, updated_at) VALUES (?, 'pending', ?)
        ON CONFLICT(question_id) DO UPDATE SET status = 'pending', attempt_token = NULL, error = '', updated_at = excluded.updated_at
        """, [.text(questionID), .real(Date().timeIntervalSinceReferenceDate)])
      return true
    }
  }

  func recoverAutomaticTagJobs() throws {
    try execute(
      try database(),
      "UPDATE question_auto_tag_jobs SET status = 'pending', attempt_token = NULL WHERE status = 'running'"
    )
  }

  func pendingAutomaticTagQuestionIDs() throws -> [String] {
    try query(
      try database(),
      """
      SELECT j.question_id FROM question_auto_tag_jobs j JOIN questions q ON q.id = j.question_id
      WHERE j.status = 'pending' AND q.deleted_at IS NULL ORDER BY j.updated_at, j.question_id
      """, map: { Self.text($0, 0) })
  }

  func automaticTagJob(questionID: String) throws -> MathAutomaticTagJob? {
    try query(
      try database(),
      """
      SELECT question_id, status, error, model, prompt_version, catalogue_version, evidence
      FROM question_auto_tag_jobs WHERE question_id = ?
      """, [.text(questionID)],
      map: {
        MathAutomaticTagJob(
          questionID: Self.text($0, 0), status: Self.text($0, 1), error: Self.text($0, 2),
          model: Self.text($0, 3), promptVersion: Self.text($0, 4),
          catalogueVersion: Self.text($0, 5), evidence: Self.text($0, 6))
      }
    ).first
  }

  func claimAutomaticTags(questionID: String) throws -> MathAutomaticTagAttempt? {
    let db = try database()
    return try transaction(db) {
      guard try pendingAutomaticTagQuestionIDs().contains(questionID) else { return nil }
      let token = UUID().uuidString
      try execute(
        db,
        """
        UPDATE question_auto_tag_jobs SET status = 'running', attempt_token = ?, error = '',
        manual_revision = (SELECT classification_revision FROM questions WHERE id = ?), updated_at = ? WHERE question_id = ?
        """,
        [
          .text(token), .text(questionID), .real(Date().timeIntervalSinceReferenceDate),
          .text(questionID),
        ])
      return MathAutomaticTagAttempt(questionID: questionID, token: token)
    }
  }

  @discardableResult
  func completeAutomaticTags(
    attempt: MathAutomaticTagAttempt, tags: [MathQuestionTag], model: String, promptVersion: String,
    catalogueVersion: String, evidence: String
  ) throws -> Bool {
    var keys = Set<String>()
    for tag in tags {
      try Self.validateTagIdentity(tag)
      guard tag.axis != "custom", tag.origin == "ai", tag.status == "suggested", !tag.label.isEmpty,
        keys.insert(tag.key).inserted
      else { throw MathQuestionStoreError.database("自动标签格式无效") }
    }
    let db = try database()
    return try transaction(db) {
      let revisions = try query(
        db,
        """
        SELECT q.classification_revision, j.manual_revision FROM question_auto_tag_jobs j JOIN questions q ON q.id = j.question_id
        WHERE j.question_id = ? AND j.attempt_token = ? AND j.status = 'running' AND q.deleted_at IS NULL
        """, [.text(attempt.questionID), .text(attempt.token)],
        map: { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1)) })
      guard let revision = revisions.first else { return false }
      // Any intervening manual edit owns this snapshot. Never let a slow response undo it.
      if revision.0 == revision.1 {
        let ownedAxes = Set(
          try self.tags(questionID: attempt.questionID).filter {
            $0.status != "rejected" && ($0.origin != "ai" || $0.status == "confirmed")
          }.map(\.axis))
        try execute(
          db,
          "DELETE FROM question_tags WHERE question_id = ? AND origin = 'ai' AND status = 'suggested'",
          [.text(attempt.questionID)])
        for tag in tags where !ownedAxes.contains(tag.axis) {
          try execute(
            db,
            """
            INSERT OR IGNORE INTO question_tags(question_id, axis, tag_id, catalogue_version, label, origin, status)
            VALUES (?, ?, ?, ?, ?, 'ai', 'suggested')
            """,
            [
              .text(attempt.questionID), .text(tag.axis), .text(tag.tagID),
              .text(tag.catalogueVersion), .text(tag.label),
            ])
        }
      }
      try execute(
        db,
        """
        UPDATE question_auto_tag_jobs SET status = 'ready', attempt_token = NULL, error = '', model = ?, prompt_version = ?, catalogue_version = ?, evidence = ?, updated_at = ? WHERE question_id = ?
        """,
        [
          .text(model), .text(promptVersion), .text(catalogueVersion),
          .text(String(evidence.prefix(16000))), .real(Date().timeIntervalSinceReferenceDate),
          .text(attempt.questionID),
        ])
      return true
    }
  }

  func markAutomaticTagFailure(attempt: MathAutomaticTagAttempt, message: String) throws {
    // Caller supplies a fixed safe description, never an HTTP body or credentials.
    try execute(
      try database(),
      """
      UPDATE question_auto_tag_jobs SET status = 'failed', attempt_token = NULL, error = ?, updated_at = ?
      WHERE question_id = ? AND attempt_token = ? AND status = 'running'
      """,
      [
        .text(String(message.prefix(300))), .real(Date().timeIntervalSinceReferenceDate),
        .text(attempt.questionID), .text(attempt.token),
      ])
  }

  func cancelAutomaticTags(attempt: MathAutomaticTagAttempt) throws {
    try execute(
      try database(),
      """
      UPDATE question_auto_tag_jobs SET status = 'pending', attempt_token = NULL
      WHERE question_id = ? AND attempt_token = ? AND status = 'running'
      """, [.text(attempt.questionID), .text(attempt.token)])
  }

  private static func validateGrade(_ grade: Int?) throws {
    if let grade, !(1...6).contains(grade) {
      throw MathQuestionStoreError.database("小学年级应为一至六年级，或留空")
    }
  }

  private static func validateTagIdentity(_ tag: MathQuestionTag) throws {
    guard ["question_form", "curriculum_knowledge", "problem_family", "custom"].contains(tag.axis),
      !tag.tagID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !tag.catalogueVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw MathQuestionStoreError.database("不支持的标签维度，或标签标识、目录版本为空") }
  }

  private static func readTag(_ statement: OpaquePointer) -> MathQuestionTag {
    MathQuestionTag(
      axis: text(statement, 0), tagID: text(statement, 1),
      catalogueVersion: text(statement, 2), label: text(statement, 3),
      origin: text(statement, 4), status: text(statement, 5))
  }

  func originalImage(questionID: String) throws -> Data {
    let db = try database()
    guard
      let asset = try query(
        db,
        """
        SELECT a.id, a.filename FROM questions q JOIN image_assets a ON a.id = q.asset_id WHERE q.id = ?
        """, [.text(questionID)], map: { (Self.text($0, 0), Self.text($0, 1)) }
      ).first
    else {
      throw MathQuestionStoreError.notFound
    }
    return try verifiedOriginal(hash: asset.0, filename: asset.1)
  }

  func solutions(questionID: String) throws -> [MathQuestionSolution] {
    let db = try database()
    _ = try record(questionID, db: db)
    return try query(
      db,
      """
      SELECT id, question, answer, model, created_at, verification_status, method_snapshot, diagram_failure FROM question_solutions
      WHERE question_id = ? ORDER BY created_at, id
      """, [.text(questionID)],
      map: {
        let methods = try Self.optionalText($0, 6).map {
          try JSONDecoder().decode(MathSolutionMethodSnapshot.self, from: Data($0.utf8))
        }
        return MathQuestionSolution(
          id: Self.text($0, 0), question: Self.text($0, 1),
          answer: Self.text($0, 2), model: Self.text($0, 3),
          createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 4)),
          verificationStatus: Self.text($0, 5),
          method: methods?.method, visualMethods: methods?.visualMethods ?? [],
          diagrams: try diagrams(solutionID: Self.text($0, 0), db: db),
          diagramFailure: Self.optionalText($0, 7), selectionFailure: methods?.selectionFailure,
          methodClaimWarning: methods?.methodClaimWarning, reviewedExamples: methods?.reviewedExamples ?? [])
      })
  }

  /// A single existing human-reviewed reference. This performs no learning,
  /// verification or publishing writes, and never treats review of an answer as
  /// review of its process. Only exact active candidate method versions qualify.
  func reviewedExamples(methods: [MathTeachingMethod], textHint: String,
    excludingImageData: Data?) throws -> [MathReviewedExample] {
    let hint = String(textHint.prefix(1_200))
    guard !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !methods.isEmpty else { return [] }
    let active = try automaticMethods()
    let eligible = methods.filter { active.contains($0) }
    guard !eligible.isEmpty else { return [] }
    let excludedAsset = excludingImageData.map(Self.digest)
    let db = try database()
    let versions = Array(Set(eligible.map(\.versionID))).sorted()
    let versionFilter = versions.map { _ in "instr(s.method_snapshot,?)>0" }.joined(separator: " OR ")
    let ids = try query(db, """
      SELECT DISTINCT q.id, q.asset_id FROM questions q
      JOIN question_solutions s ON s.question_id=q.id
      JOIN image_assets a ON a.id=q.asset_id
      WHERE q.deleted_at IS NULL AND s.verification_status='confirmed' AND a.byte_count<=2097152
        AND (\(versionFilter))
      ORDER BY q.created_at DESC,q.id LIMIT 128
      """, versions.map(Value.text), map: { (Self.text($0, 0), Self.text($0, 1)) })
    var ranked: [(reference: MathReviewedExampleReference, text: String, answer: String, score: Int, date: Date)] = []
    for (id, asset) in ids where asset != excludedAsset {
      let record = try record(id, db: db)
      let source = String(record.ocrText.prefix(1_200))
      guard let score = MathReviewedExample.relevance(query: hint, source: source) else { continue }
      for solution in try solutions(questionID: id) where solution.verificationStatus == "confirmed" {
        guard let method = solution.method, eligible.contains(method),
          let review = try reviews(solutionID: solution.id).last, review.status == "confirmed",
          ["最终答案", "答案及解题过程"].contains(review.scope) else { continue }
        let answer = review.correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? solution.answer : review.correction
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let reference = MathReviewedExampleReference(questionID: id, solutionID: solution.id,
          reviewID: review.id, scope: review.scope, title: String(record.title.prefix(256)))
        guard reference.isValid else { continue }
        ranked.append((reference, source, String(answer.prefix(1_600)), score, review.createdAt))
      }
    }
    ranked.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.date != $1.date { return $0.date > $1.date }
      return $0.reference.solutionID < $1.reference.solutionID
    }
    // Read at most one retained image at a time; a bad historical asset must
    // not discard the current question or inflate the bounded reference payload.
    for item in ranked {
      guard let image = try? originalImage(questionID: item.reference.questionID),
        image.count <= 2 * 1024 * 1024 else { continue }
      return [.init(reference: item.reference, text: item.text, answer: item.answer, imageData: image)]
    }
    return []
  }

  func assetImage(assetID: String) throws -> Data {
    let db = try database()
    guard
      let filename = try query(
        db, "SELECT filename FROM image_assets WHERE id = ?", [.text(assetID)],
        map: { Self.text($0, 0) }
      ).first
    else { throw MathQuestionStoreError.notFound }
    return try verifiedOriginal(hash: assetID, filename: filename)
  }

  func referenceAnswers(questionID: String) throws -> [MathReferenceAnswer] {
    let db = try database()
    _ = try record(questionID, db: db)
    return try query(
      db,
      """
      SELECT id, text, source, scope, image_asset_id, created_at FROM question_reference_answers
      WHERE question_id = ? ORDER BY rowid
      """, [.text(questionID)],
      map: {
        MathReferenceAnswer(
          id: Self.text($0, 0), text: Self.text($0, 1), source: Self.text($0, 2),
          scope: Self.text($0, 3), imageAssetID: Self.optionalText($0, 4),
          createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 5)))
      })
  }

  func addReferenceAnswer(
    questionID: String, text: String, source: String, scope: String, imageData: Data? = nil
  ) throws -> MathReferenceAnswer {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty || imageData != nil else {
      throw MathQuestionStoreError.database("请填写参考答案或提供答案图片")
    }
    let db = try database()
    _ = try record(questionID, db: db)
    let image = try imageData.map(Self.inspectImage)
    let assetID = imageData.map(Self.digest)
    if let imageData, let image, let assetID {
      try persistOriginal(imageData, filename: "\(assetID).\(image.extensionName)")
    }
    let answer = MathReferenceAnswer(
      id: UUID().uuidString, text: normalized, source: source, scope: scope,
      imageAssetID: assetID, createdAt: Date())
    try transaction(db) {
      if let imageData, let image, let assetID {
        try execute(
          db,
          """
          INSERT INTO image_assets(id, filename, media_type, byte_count, width, height, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
          """,
          [
            .text(assetID), .text("\(assetID).\(image.extensionName)"), .text(image.mediaType),
            .integer(Int64(imageData.count)), .integer(Int64(image.width)),
            .integer(Int64(image.height)), .real(answer.createdAt.timeIntervalSinceReferenceDate),
          ])
      }
      try execute(
        db,
        """
        INSERT INTO question_reference_answers(id, question_id, text, source, scope, image_asset_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(answer.id), .text(questionID), .text(answer.text), .text(answer.source),
          .text(answer.scope), assetID.map(Value.text) ?? .null,
          .real(answer.createdAt.timeIntervalSinceReferenceDate),
        ])
    }
    return answer
  }

  func reviews(solutionID: String) throws -> [MathSolutionReview] {
    let db = try database()
    guard
      try query(
        db, "SELECT id FROM question_solutions WHERE id = ?", [.text(solutionID)],
        map: { Self.text($0, 0) }
      ).first != nil
    else { throw MathQuestionStoreError.notFound }
    return try query(
      db,
      """
      SELECT id, solution_id, status, scope, note, correction, reference_id, created_at
      FROM solution_reviews WHERE solution_id = ? ORDER BY rowid
      """, [.text(solutionID)],
      map: {
        MathSolutionReview(
          id: Self.text($0, 0), solutionID: Self.text($0, 1), status: Self.text($0, 2),
          scope: Self.text($0, 3), note: Self.text($0, 4), correction: Self.text($0, 5),
          referenceID: Self.optionalText($0, 6),
          createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 7)))
      })
  }

  func reviewSolution(
    questionID: String, solutionID: String, status: String, scope: String, note: String,
    correction: String, referenceID: String? = nil
  ) throws -> MathSolutionReview {
    guard ["unverified", "confirmed", "rejected"].contains(status) else {
      throw MathQuestionStoreError.database("不支持的答案核验状态")
    }
    let db = try database()
    let review = MathSolutionReview(
      id: UUID().uuidString, solutionID: solutionID, status: status, scope: scope, note: note,
      correction: correction, referenceID: referenceID, createdAt: Date())
    try transaction(db) {
      try insertSolutionReview(review, questionID: questionID, db: db)
    }
    return review
  }

  private func insertSolutionReview(_ review: MathSolutionReview, questionID: String, db: OpaquePointer) throws {
    let solutionID = review.solutionID
    guard
      try query(
        db, "SELECT question_id FROM question_solutions WHERE id = ?", [.text(solutionID)],
        map: { Self.text($0, 0) }
      ).first == questionID
    else { throw MathQuestionStoreError.notFound }
    if let referenceID = review.referenceID {
      guard
        try query(
          db, "SELECT question_id FROM question_reference_answers WHERE id = ?",
          [.text(referenceID)],
          map: { Self.text($0, 0) }
        ).first == questionID
      else { throw MathQuestionStoreError.notFound }
    }
    try execute(
      db,
      """
      INSERT INTO solution_reviews(id, solution_id, status, scope, note, correction, reference_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(review.id), .text(solutionID), .text(review.status), .text(review.scope), .text(review.note),
        .text(review.correction), review.referenceID.map(Value.text) ?? .null,
        .real(review.createdAt.timeIntervalSinceReferenceDate),
      ])
    try execute(
      db, "UPDATE question_solutions SET verification_status = ? WHERE id = ?",
      [.text(review.status), .text(solutionID)])
  }

  /// Includes archived identities so built-in aliases never revive or duplicate user-owned methods.
  func importBundledMathSkills(_ catalogue: MathSkillCatalogue) throws -> MathMethodImportResult {
    try importMethods(catalogue.importEntries())
  }

  func methods() throws -> [MathTeachingMethod] {
    let db = try database()
    return try query(
      db,
      """
      SELECT m.id, v.id, v.title, v.category, v.instructions, v.created_at
      FROM teaching_methods m JOIN teaching_method_versions v ON v.id = m.current_version_id
      WHERE m.archived_at IS NULL ORDER BY v.created_at DESC, m.id
      """, map: Self.readMethod).map { try methodWithPermissions($0) }
  }

  private func methodWithPermissions(_ method: MathTeachingMethod) throws -> MathTeachingMethod {
    let permissions = try skillProfile(versionID: method.versionID)?.teachingPermissions
    return .init(id: method.id, versionID: method.versionID, title: method.title, category: method.category,
      instructions: method.instructions, createdAt: method.createdAt, teachingPermissions: permissions)
  }

  func saveMethod(id: String? = nil, title: String, category: String, instructions: String,
    teachingPermissions: MathTeachingPermissions? = nil) throws
    -> MathTeachingMethod
  {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !instructions.isEmpty, teachingPermissions?.isValid ?? true else {
      throw MathQuestionStoreError.database("请填写方法名称和解题方法")
    }
    let db = try database()
    let method = MathTeachingMethod(
      id: id ?? UUID().uuidString, versionID: UUID().uuidString, title: title,
      category: category.trimmingCharacters(in: .whitespacesAndNewlines),
      instructions: instructions, createdAt: Date(), teachingPermissions: teachingPermissions)
    let priorProfile = try id.flatMap { methodID in
      try methods().first(where: { $0.id == methodID }).flatMap { try skillProfile(versionID: $0.versionID) }
    }
    try transaction(db) {
      if id != nil {
        guard
          try query(
            db, "SELECT id FROM teaching_methods WHERE id = ?", [.text(method.id)],
            map: { Self.text($0, 0) }
          ).first != nil
        else { throw MathQuestionStoreError.notFound }
      } else {
        try execute(db, "INSERT INTO teaching_methods(id) VALUES (?)", [.text(method.id)])
      }
      try execute(
        db,
        """
        INSERT INTO teaching_method_versions(id, method_id, title, category, instructions, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          .text(method.versionID), .text(method.id), .text(method.title), .text(method.category),
          .text(method.instructions), .real(method.createdAt.timeIntervalSinceReferenceDate),
        ])
      try execute(
        db,
        "UPDATE teaching_methods SET current_version_id = ?, archived_at = NULL WHERE id = ?",
        [.text(method.versionID), .text(method.id)])
      if teachingPermissions != nil || priorProfile != nil {
        let seed = (try? MathTeachingReviewCatalogue.load())?.seed(for: method)
        let profile = MathSkillProfile(versionID: method.versionID,
          trigger: priorProfile?.trigger ?? seed?.trigger ?? "待核对：适用条件见方法全文",
          constraints: priorProfile?.constraints ?? seed?.constraints ?? "小学四年级默认优先算术；等待人工审校",
          exclusions: priorProfile?.exclusions ?? seed?.exclusions ?? "待核对：条件不足时不套用",
          prerequisites: priorProfile?.prerequisites ?? seed?.prerequisites ?? "待核对：先修知识见方法全文",
          supportedDiagrams: priorProfile?.supportedDiagrams ?? seed?.supportedDiagrams ?? [],
          sourceInstructions: instructions, teachingPermissions: teachingPermissions)
        try execute(db, "INSERT INTO skill_profiles VALUES (?,?,'draft')", [.text(method.versionID), .text(Self.skillJSON(profile))])
        try execute(db, "INSERT INTO skill_lifecycle_events VALUES (?,?,'draft',?,?)", [.text(UUID().uuidString),
          .text(method.versionID), .text("方法正文或教学权限已保存新版本；旧人工审校不认证该版本"), .real(Date().timeIntervalSinceReferenceDate)])
      }
    }
    return method
  }

  /// Reimport clean source versions; manual edits and archived methods remain user-owned.
  func importMethods(_ entries: [MathMethodImportEntry]) throws -> MathMethodImportResult {
    let db = try database()
    let existingIDs = Set(try query(db, "SELECT id FROM teaching_methods", map: { Self.text($0, 0) }))
    let entries = try entries.map { entry in
      let matches = ([entry.sourceID] + entry.legacyAliasIDs).filter { existingIDs.contains($0) }
      guard Set(matches).count <= 1 else {
        throw MathQuestionStoreError.database("同一方法存在多个旧身份，请先处理重复方法")
      }
      return MathMethodImportEntry(sourceID: matches.first ?? entry.sourceID,
        title: entry.title, category: entry.category, instructions: entry.instructions)
    }
    guard !entries.isEmpty, Set(entries.map(\.sourceID)).count == entries.count,
      entries.allSatisfy({
        !$0.sourceID.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw MathQuestionStoreError.database("方法导入内容无效") }
    return try transaction(db) {
      var imported = 0
      var updated = 0
      var skipped = 0
      var conflicts = 0
      for entry in entries {
        let existing = try query(
          db,
          """
          SELECT m.current_version_id, m.archived_at, i.last_imported_version_id,
            v.title, v.category, v.instructions
          FROM teaching_methods m
          LEFT JOIN teaching_method_imports i ON i.method_id = m.id
          LEFT JOIN teaching_method_versions v ON v.id = m.current_version_id
          WHERE m.id = ?
          """, [.text(entry.sourceID)],
          map: { statement in
            (
              current: Self.text(statement, 0),
              archived: sqlite3_column_type(statement, 1) != SQLITE_NULL,
              baseline: Self.text(statement, 2), title: Self.text(statement, 3),
              category: Self.text(statement, 4), instructions: Self.text(statement, 5)
            )
          }
        ).first
        if let existing {
          if existing.archived {
            skipped += 1
            continue
          }
          guard !existing.baseline.isEmpty, existing.current == existing.baseline else {
            conflicts += 1
            continue
          }
          if existing.title == entry.title && existing.category == entry.category
            && existing.instructions == entry.instructions
          {
            skipped += 1
            continue
          }
        }
        let version = UUID().uuidString
        if existing == nil {
          try execute(db, "INSERT INTO teaching_methods(id) VALUES (?)", [.text(entry.sourceID)])
        }
        try execute(
          db,
          "INSERT INTO teaching_method_versions(id, method_id, title, category, instructions, created_at) VALUES (?, ?, ?, ?, ?, ?)",
          [
            .text(version), .text(entry.sourceID), .text(entry.title), .text(entry.category),
            .text(entry.instructions), .real(Date().timeIntervalSinceReferenceDate),
          ])
        try execute(
          db, "UPDATE teaching_methods SET current_version_id = ? WHERE id = ?",
          [.text(version), .text(entry.sourceID)])
        try execute(
          db,
          """
          INSERT INTO teaching_method_imports(method_id, last_imported_version_id) VALUES (?, ?)
          ON CONFLICT(method_id) DO UPDATE SET last_imported_version_id = excluded.last_imported_version_id
          """, [.text(entry.sourceID), .text(version)])
        if existing == nil { imported += 1 } else { updated += 1 }
      }
      return .init(imported: imported, skipped: skipped, updated: updated, conflicts: conflicts)
    }
  }

  func archiveMethod(id: String) throws {
    let db = try database()
    guard
      try query(
        db, "SELECT id FROM teaching_methods WHERE id = ?", [.text(id)],
        map: { Self.text($0, 0) }
      ).first != nil
    else { throw MathQuestionStoreError.notFound }
    try execute(
      db, "UPDATE teaching_methods SET archived_at = ? WHERE id = ?",
      [.real(Date().timeIntervalSinceReferenceDate), .text(id)])
  }

  private static func readMethod(_ statement: OpaquePointer) -> MathTeachingMethod {
    MathTeachingMethod(
      id: text(statement, 0), versionID: text(statement, 1), title: text(statement, 2),
      category: text(statement, 3), instructions: text(statement, 4),
      createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)))
  }

  func updateOCR(questionID: String, text: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    // An empty completed recognition is distinct from an unstarted job.
    try transaction(db) {
      try execute(
        db,
        "UPDATE question_ocr SET text = ?, status = 'ready', updated_at = ? WHERE question_id = ?",
        [.text(text), .real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
      try nameUnnamedQuestion(questionID, text: text, db: db)
    }
  }

  /// Titles are navigation metadata; the original image and complete OCR index stay intact.
  private static func suggestedTitle(from text: String) -> String? {
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"^\d+\s*[.．、:：)）]\s*"#, with: "", options: .regularExpression)
    }.filter { $0.count > 1 && $0.rangeOfCharacter(from: .letters) != nil }
    let line =
      lines.first { $0.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil }
      ?? lines.first
    guard let line else { return nil }
    return line.count > 32 ? String(line.prefix(32)) + "…" : line
  }

  private func nameUnnamedQuestion(_ id: String, text: String, db: OpaquePointer) throws {
    guard let title = Self.suggestedTitle(from: text) else { return }
    try execute(
      db, "UPDATE questions SET title = ? WHERE id = ? AND title = '未命名题目'",
      [.text(title), .text(id)])
  }

  func markOCRFailure(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    try execute(
      db, "UPDATE question_ocr SET status = 'failed', updated_at = ? WHERE question_id = ?",
      [.real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
  }

  func rename(questionID: String, title: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    try execute(
      db, "UPDATE questions SET title = ?, updated_at = ? WHERE id = ?",
      [
        .text(normalized.isEmpty ? "未命名题目" : normalized),
        .real(Date().timeIntervalSinceReferenceDate), .text(questionID),
      ])
  }

  func delete(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    let now = Date().timeIntervalSinceReferenceDate
    try transaction(db) {
      try execute(
        db, "UPDATE questions SET deleted_at = ?, updated_at = ? WHERE id = ?",
        [.real(now), .real(now), .text(questionID)])
      try execute(
        db,
        "UPDATE question_auto_tag_jobs SET status = 'pending', attempt_token = NULL WHERE question_id = ? AND status = 'running'",
        [.text(questionID)])
    }
  }

  func restore(questionID: String) throws {
    let db = try database()
    _ = try record(questionID, db: db)
    try execute(
      db, "UPDATE questions SET deleted_at = NULL, updated_at = ? WHERE id = ?",
      [.real(Date().timeIntervalSinceReferenceDate), .text(questionID)])
  }

  /// Creates a new directory containing a SQLite snapshot and every referenced original,
  /// including soft-deleted questions. WAL files are never copied as a backup strategy.
  func backup(to destination: URL) throws {
    // The actor connection is opened first for current-format export; the independent
    // helper handles pre-migration snapshots without entering this path.
    _ = try database()
    try MathQuestionArchive.create(directory: directory, to: destination)
  }

  /// Actor serialization prevents local writes during the directory exchange.
  /// UI owners must cancel asynchronous jobs before calling this destructive restore.
  func restoreBackup(from backup: URL) throws -> URL {
    _ = try database()
    return try MathQuestionBackupRestore.replace(
      directory: directory, from: backup,
      close: { self.connection = nil },
      activate: { _ = try self.database() })
  }

  func diagramImage(solutionID: String, ordinal: Int) throws -> Data {
    let db = try database()
    guard let assetID = try query(
      db, "SELECT image_asset_id FROM solution_diagrams WHERE solution_id = ? AND ordinal = ?",
      [.text(solutionID), .integer(Int64(ordinal))], map: { Self.text($0, 0) }
    ).first else { throw MathQuestionStoreError.notFound }
    return try assetImage(assetID: assetID)
  }

  private func diagrams(solutionID: String, db: OpaquePointer) throws -> [MathDiagram] {
    try query(
      db, "SELECT diagram_json FROM solution_diagrams WHERE solution_id = ? ORDER BY ordinal",
      [.text(solutionID)], map: {
        try JSONDecoder().decode(MathDiagram.self, from: Data(Self.text($0, 0).utf8))
      })
  }

  // Explicitly closes the actor-owned connection for export/reopen tests and shutdown.
  func close() {
    connection = nil
  }

  func storageConfiguration() throws -> (
    foreignKeys: Bool, journalMode: String, synchronous: Int, schemaVersion: Int
  ) {
    let db = try database()
    return (
      try integerPragma(db, "PRAGMA foreign_keys") == 1,
      try query(db, "PRAGMA journal_mode", map: { Self.text($0, 0) }).first ?? "",
      Int(try integerPragma(db, "PRAGMA synchronous")),
      Int(try integerPragma(db, "PRAGMA user_version"))
    )
  }

  private static let recordSelect = """
    SELECT q.id, q.title, q.created_at, a.width, a.height, o.text, o.status, q.grade,
      coalesce(j.status, 'unclassified'), coalesce(j.error, '')
    FROM questions q JOIN image_assets a ON a.id = q.asset_id
    JOIN question_ocr o ON o.question_id = q.id
    LEFT JOIN question_auto_tag_jobs j ON j.question_id = q.id
    """

  private static func readRecord(_ statement: OpaquePointer) -> MathQuestionRecord {
    MathQuestionRecord(
      id: text(statement, 0), title: text(statement, 1),
      createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
      imageWidth: Int(sqlite3_column_int64(statement, 3)),
      imageHeight: Int(sqlite3_column_int64(statement, 4)),
      ocrText: text(statement, 5), ocrStatus: text(statement, 6),
      grade: sqlite3_column_type(statement, 7) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, 7)),
      automaticTagStatus: text(statement, 8), automaticTagError: text(statement, 9))
  }

  private func record(_ id: String, db: OpaquePointer) throws -> MathQuestionRecord {
    guard
      let record = try query(
        db, Self.recordSelect + " WHERE q.id = ?", [.text(id)],
        map: Self.readRecord
      ).first
    else { throw MathQuestionStoreError.notFound }
    return record
  }

  private func appendSolutions(
    _ solutions: [MathQuestionSolution], questionID: String,
    db: OpaquePointer
  ) throws {
    for solution in solutions {
      guard !solution.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      if let owner = try query(
        db, "SELECT question_id FROM question_solutions WHERE id = ?",
        [.text(solution.id)], map: { Self.text($0, 0) }
      ).first,
        owner != questionID
      {
        throw MathQuestionStoreError.database("解答标识已经归属于另一道题目")
      }
      // A completed answer and its diagram snapshots are immutable on repeated saves.
      if !(try query(db, "SELECT id FROM question_solutions WHERE id = ?", [.text(solution.id)], map: { Self.text($0, 0) })).isEmpty { continue }
      // Store only the model identifier, never endpoint or authentication configuration.
      guard !solution.model.contains("://"), !solution.model.lowercased().contains("bearer "),
        !solution.model.hasPrefix("sk-"), solution.model.utf8.count <= 128
      else {
        throw MathQuestionStoreError.database("解答的模型字段必须为模型名称")
      }
      var preparedDiagrams: [(diagram: MathDiagram, bytes: Data)] = []
      var diagramFailures = solution.diagramFailure.map { [$0] } ?? []
      for (index, diagram) in solution.diagrams.enumerated() {
        do {
          try MathDiagramAnswer.validateRendering(diagram)
          preparedDiagrams.append((diagram, try MathDiagramRenderer.renderPNG(diagram)))
        } catch let error as MathDiagram.ValidationError {
          // Diagram validation/layout failures must not discard the archived question or
          // readable answer. Database and filesystem errors below still abort the write.
          diagramFailures.append("图 \(index + 1)：\(error.message)")
        }
      }
      try execute(
        db,
        """
        INSERT INTO question_solutions(id, question_id, question, answer, model, created_at, method_snapshot, diagram_failure)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
        """,
        [
          .text(solution.id), .text(questionID), .text(solution.question), .text(solution.answer),
          .text(solution.model), .real(solution.createdAt.timeIntervalSinceReferenceDate),
          try MathSolutionMethodSnapshot(
            method: solution.method, visualMethods: solution.visualMethods, selectionFailure: solution.selectionFailure,
            methodClaimWarning: solution.methodClaimWarning, reviewedExamples: solution.reviewedExamples
          )
          .encoded().map { .text($0) } ?? .null,
          diagramFailures.isEmpty ? .null : .text(diagramFailures.joined(separator: "\n")),
        ])
      for (ordinal, prepared) in preparedDiagrams.enumerated() {
        let (diagram, bytes) = prepared
        let image = try Self.inspectImage(bytes)
        let hash = Self.digest(bytes)
        let filename = "\(hash).png"
        try persistOriginal(bytes, filename: filename)
        try execute(db, "INSERT INTO image_assets(id,filename,media_type,byte_count,width,height,created_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING", [
          .text(hash), .text(filename), .text("image/png"), .integer(Int64(bytes.count)),
          .integer(Int64(image.width)), .integer(Int64(image.height)), .real(solution.createdAt.timeIntervalSinceReferenceDate),
        ])
        let json = String(decoding: try JSONEncoder().encode(diagram), as: UTF8.self)
        try execute(db, "INSERT INTO solution_diagrams(solution_id,ordinal,schema_version,renderer_version,diagram_json,image_asset_id) VALUES (?,?,?,?,?,?)", [
          .text(solution.id), .integer(Int64(ordinal)), .integer(Int64(MathDiagram.schemaVersion)),
          .integer(Int64(MathDiagramRenderer.rendererVersion)), .text(json), .text(hash),
        ])
      }
    }
  }

  private func database() throws -> OpaquePointer {
    if let connection { return connection.handle }
    let manager = FileManager.default
    let url = directory.appendingPathComponent("questions.sqlite")
    let existed = manager.fileExists(atPath: url.path)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK,
      let db
    else {
      if let db { sqlite3_close_v2(db) }
      throw MathQuestionStoreError.incompatibleDatabase
    }
    do {
      sqlite3_busy_timeout(db, 5000)
      try execute(db, "PRAGMA foreign_keys = ON")
      let version = try integerPragma(db, "PRAGMA user_version")
      if version > Self.schemaVersion { throw MathQuestionStoreError.newerDatabase(Int(version)) }
      if existed {
        guard (1...Self.schemaVersion).contains(version),
          try integerPragma(db, "PRAGMA application_id") == Self.applicationID,
          try query(db, "PRAGMA quick_check", map: { Self.text($0, 0) }) == ["ok"],
          try query(db, "PRAGMA foreign_key_check", map: { Self.text($0, 0) }).isEmpty
        else {
          throw MathQuestionStoreError.incompatibleDatabase
        }
        try validateSchema(db, version: version)
      }
      if existed && version < Self.schemaVersion {
        let snapshot = directory.appendingPathComponent("pre-migration-backups", isDirectory: true)
          .appendingPathComponent("schema-\(version)-\(UUID().uuidString)", isDirectory: true)
        try MathQuestionPreMigrationBackup.create(directory: directory, to: snapshot)
      }
      guard try query(db, "PRAGMA journal_mode = WAL", map: { Self.text($0, 0) }).first == "wal"
      else {
        throw MathQuestionStoreError.database("无法启用题库日志")
      }
      try execute(db, "PRAGMA synchronous = FULL")
      if !existed {
        try transaction(db) {
          try executeScript(db, Self.schema)
          try executeScript(db, Self.reviewSchema)
          try executeScript(db, Self.automaticTagSchema)
          try executeScript(db, Self.methodImportSchema)
          try executeScript(db, Self.diagramSchema)
          try executeScript(db, Self.skillLearningSchema)
          try validateSchema(db, version: Self.schemaVersion)
          try execute(db, "PRAGMA application_id = \(Self.applicationID)")
          try execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
        }
      }
      if existed && version < Self.schemaVersion {
        try transaction(db) {
          if version == 1 { try executeScript(db, Self.reviewSchema) }
          if version < 3 { try executeScript(db, Self.automaticTagSchema) }
          if version < 4 { try executeScript(db, Self.methodImportSchema) }
          if version < 5 { try executeScript(db, Self.diagramSchema) }
          if version < 6 { try executeScript(db, Self.skillLearningSchema) }
          try validateSchema(db, version: Self.schemaVersion)
          try execute(db, "PRAGMA user_version = \(Self.schemaVersion)")
        }
      }
      try manager.createDirectory(
        at: directory.appendingPathComponent("assets", isDirectory: true),
        withIntermediateDirectories: true)
      // Older photo-only saves already have an index but retained the placeholder title.
      let unnamed = try query(
        db,
        """
        SELECT q.id, o.text FROM questions q JOIN question_ocr o ON o.question_id = q.id
        WHERE q.title = '未命名题目' AND o.status = 'ready'
        """, map: { (Self.text($0, 0), Self.text($0, 1)) })
      if !unnamed.isEmpty {
        try transaction(db) {
          for (id, text) in unnamed { try nameUnnamedQuestion(id, text: text, db: db) }
        }
      }
      connection = Connection(db)
      return db
    } catch {
      sqlite3_close_v2(db)
      throw error
    }
  }

  // Timestamp REAL values use Foundation reference-date seconds (2001-01-01 UTC),
  // preserving Date precision exactly across SQLite and Codable round trips.
  private static let schema = """
    CREATE TABLE image_assets (
      id TEXT PRIMARY KEY, filename TEXT NOT NULL UNIQUE,
      media_type TEXT NOT NULL CHECK(media_type IN ('image/png','image/jpeg')),
      byte_count INTEGER NOT NULL CHECK(byte_count > 0),
      width INTEGER NOT NULL CHECK(width > 0), height INTEGER NOT NULL CHECK(height > 0),
      created_at REAL NOT NULL
    );
    CREATE TABLE questions (
      id TEXT PRIMARY KEY, capture_id TEXT NOT NULL UNIQUE,
      asset_id TEXT NOT NULL REFERENCES image_assets(id), title TEXT NOT NULL,
      grade INTEGER CHECK(grade BETWEEN 1 AND 6),
      created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL
    );
    CREATE INDEX questions_visible ON questions(deleted_at, created_at);
    CREATE TABLE question_ocr (
      question_id TEXT PRIMARY KEY REFERENCES questions(id), text TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','ready','failed')),
      updated_at REAL NOT NULL
    );
    CREATE TABLE question_solutions (
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES questions(id),
      question TEXT NOT NULL, answer TEXT NOT NULL, model TEXT NOT NULL, created_at REAL NOT NULL,
      source TEXT NOT NULL DEFAULT 'ai' CHECK(source = 'ai'),
      verification_status TEXT NOT NULL DEFAULT 'unverified' CHECK(verification_status IN ('unverified','confirmed','rejected'))
    );
    CREATE INDEX solutions_question ON question_solutions(question_id, created_at);
    CREATE TABLE question_tags (
      question_id TEXT NOT NULL REFERENCES questions(id),
      axis TEXT NOT NULL CHECK(axis IN ('question_form','curriculum_knowledge','problem_family','custom')),
      tag_id TEXT NOT NULL, catalogue_version TEXT NOT NULL, label TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN ('user','teacher','ai')),
      status TEXT NOT NULL DEFAULT 'suggested' CHECK(status IN ('suggested','confirmed','rejected')),
      PRIMARY KEY(question_id, axis, tag_id, catalogue_version)
    );
    """

  private static let reviewSchema = """
    ALTER TABLE question_solutions ADD COLUMN method_snapshot TEXT;
    CREATE TABLE question_reference_answers (
      id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES questions(id),
      text TEXT NOT NULL, source TEXT NOT NULL, scope TEXT NOT NULL,
      image_asset_id TEXT REFERENCES image_assets(id), created_at REAL NOT NULL,
      CHECK(length(trim(text)) > 0 OR image_asset_id IS NOT NULL)
    );
    CREATE INDEX references_question ON question_reference_answers(question_id, created_at);
    CREATE TABLE solution_reviews (
      id TEXT PRIMARY KEY, solution_id TEXT NOT NULL REFERENCES question_solutions(id),
      status TEXT NOT NULL CHECK(status IN ('unverified','confirmed','rejected')),
      scope TEXT NOT NULL, note TEXT NOT NULL, correction TEXT NOT NULL,
      reference_id TEXT REFERENCES question_reference_answers(id), created_at REAL NOT NULL
    );
    CREATE INDEX reviews_solution ON solution_reviews(solution_id, created_at);
    CREATE TABLE teaching_methods (
      id TEXT PRIMARY KEY, current_version_id TEXT REFERENCES teaching_method_versions(id),
      archived_at REAL
    );
    CREATE TABLE teaching_method_versions (
      id TEXT PRIMARY KEY, method_id TEXT NOT NULL REFERENCES teaching_methods(id),
      title TEXT NOT NULL CHECK(length(trim(title)) > 0), category TEXT NOT NULL,
      instructions TEXT NOT NULL CHECK(length(trim(instructions)) > 0), created_at REAL NOT NULL
    );
    CREATE INDEX method_versions_method ON teaching_method_versions(method_id, created_at);
    """

  private static let automaticTagSchema = """
    ALTER TABLE questions ADD COLUMN classification_revision INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE question_auto_tag_jobs (
      question_id TEXT PRIMARY KEY REFERENCES questions(id),
      status TEXT NOT NULL CHECK(status IN ('pending','running','ready','failed')),
      attempt_token TEXT, manual_revision INTEGER NOT NULL DEFAULT 0,
      error TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '',
      prompt_version TEXT NOT NULL DEFAULT '', catalogue_version TEXT NOT NULL DEFAULT '',
      evidence TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL
    );
    CREATE INDEX auto_tag_jobs_status ON question_auto_tag_jobs(status, updated_at);
    """

  /// A tracked source baseline protects later application edits during reimport.
  private static let methodImportSchema = """
    CREATE TABLE teaching_method_imports (
      method_id TEXT PRIMARY KEY REFERENCES teaching_methods(id),
      last_imported_version_id TEXT NOT NULL REFERENCES teaching_method_versions(id)
    );
    INSERT INTO teaching_method_imports(method_id, last_imported_version_id)
    SELECT m.id, (
      SELECT v.id FROM teaching_method_versions v WHERE v.method_id = m.id
      ORDER BY v.created_at, v.rowid LIMIT 1
    ) FROM teaching_methods m
    WHERE m.id LIKE 'markdown-%'
      AND EXISTS (SELECT 1 FROM teaching_method_versions v WHERE v.method_id = m.id);
    """

  private static let diagramSchema = """
    ALTER TABLE question_solutions ADD COLUMN diagram_failure TEXT;
    CREATE TABLE solution_diagrams (
      solution_id TEXT NOT NULL REFERENCES question_solutions(id),
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      schema_version INTEGER NOT NULL CHECK(schema_version > 0),
      renderer_version INTEGER NOT NULL CHECK(renderer_version > 0),
      diagram_json TEXT NOT NULL,
      image_asset_id TEXT NOT NULL REFERENCES image_assets(id),
      PRIMARY KEY(solution_id, ordinal)
    );
    """

  /// Each legacy schema is validated before migration writes.
  private func validateSchema(_ db: OpaquePointer, version: Int64) throws {
    let selects = [
      "SELECT id, filename, media_type, byte_count, width, height, created_at FROM image_assets LIMIT 0",
      "SELECT id, capture_id, asset_id, title, grade, created_at, updated_at, deleted_at FROM questions LIMIT 0",
      "SELECT question_id, text, status, updated_at FROM question_ocr LIMIT 0",
      "SELECT id, question_id, question, answer, model, created_at, source, verification_status FROM question_solutions LIMIT 0",
      "SELECT question_id, axis, tag_id, catalogue_version, label, origin, status FROM question_tags LIMIT 0",
    ]
    let reviewSelects = [
      "SELECT method_snapshot FROM question_solutions LIMIT 0",
      "SELECT id, question_id, text, source, scope, image_asset_id, created_at FROM question_reference_answers LIMIT 0",
      "SELECT id, solution_id, status, scope, note, correction, reference_id, created_at FROM solution_reviews LIMIT 0",
      "SELECT id, current_version_id, archived_at FROM teaching_methods LIMIT 0",
      "SELECT id, method_id, title, category, instructions, created_at FROM teaching_method_versions LIMIT 0",
    ]
    let automaticSelects = [
      "SELECT classification_revision FROM questions LIMIT 0",
      "SELECT question_id, status, attempt_token, manual_revision, error, model, prompt_version, catalogue_version, evidence, updated_at FROM question_auto_tag_jobs LIMIT 0",
    ]
    for sql in selects + (version >= 2 ? reviewSelects : [])
      + (version >= 3 ? automaticSelects : [])
      + (version >= 4
        ? ["SELECT method_id, last_imported_version_id FROM teaching_method_imports LIMIT 0"] : [])
      + (version >= 5 ? ["SELECT diagram_failure FROM question_solutions LIMIT 0", "SELECT solution_id,ordinal,schema_version,renderer_version,diagram_json,image_asset_id FROM solution_diagrams LIMIT 0"] : [])
      + (version >= 6 ? Self.skillLearningSchemaChecks : [])
    {
      _ = try query(db, sql, map: { Self.text($0, 0) })
    }
  }

  private func persistOriginal(_ bytes: Data, filename: String) throws {
    let assetDirectory = directory.appendingPathComponent("assets", isDirectory: true)
    let url = assetDirectory.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == bytes else { throw MathQuestionStoreError.damagedImage }
    } else {
      try Self.writeSynced(bytes, to: url)
      try Self.syncDirectory(assetDirectory)
    }
  }

  private func verifiedOriginal(hash: String, filename: String) throws -> Data {
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
      filename == "\(hash).png" || filename == "\(hash).jpg",
      let bytes = try? Data(
        contentsOf: directory.appendingPathComponent("assets").appendingPathComponent(filename)),
      Self.digest(bytes) == hash
    else { throw MathQuestionStoreError.damagedImage }
    return bytes
  }

  private static func writeSynced(_ bytes: Data, to url: URL) throws {
    try bytes.write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  private static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw MathQuestionStoreError.database("无法打开原图目录") }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw MathQuestionStoreError.database("无法同步原图目录") }
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct ImageInfo {
    let width: Int
    let height: Int
    let mediaType: String
    let extensionName: String
  }

  private static func inspectImage(_ data: Data) throws -> ImageInfo {
    guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
      let type = CGImageSourceGetType(source) as String?,
      type == "public.png" || type == "public.jpeg",
      let image = CGImageSourceCreateImageAtIndex(
        source, 0,
        [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
          as CFDictionary),
      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
      image.width > 0, image.height > 0
    else { throw MathQuestionStoreError.invalidImage }
    if type == "public.png" {
      guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        data.suffix(12) == Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
      else {
        throw MathQuestionStoreError.invalidImage
      }
    } else {
      guard data.starts(with: [255, 216]), data.suffix(2) == Data([255, 217]) else {
        throw MathQuestionStoreError.invalidImage
      }
    }
    return ImageInfo(
      width: image.width, height: image.height,
      mediaType: type == "public.png" ? "image/png" : "image/jpeg",
      extensionName: type == "public.png" ? "png" : "jpg")
  }

  private enum Value {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
  }

  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let bytes = sqlite3_column_text(statement, index) else { return "" }
    return String(
      decoding: UnsafeBufferPointer(
        start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
  }

  private static func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
  }

  private func databaseError(_ db: OpaquePointer) -> MathQuestionStoreError {
    .database(String(cString: sqlite3_errmsg(db)))
  }

  private func statement(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws
    -> OpaquePointer
  {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
      throw databaseError(db)
    }
    do {
      for (offset, value) in values.enumerated() {
        let index = Int32(offset + 1)
        let code: Int32
        switch value {
        case .text(let text):
          code = text.withCString {
            sqlite3_bind_text(result, index, $0, Int32(text.utf8.count), Self.transient)
          }
        case .integer(let number): code = sqlite3_bind_int64(result, index, number)
        case .real(let number): code = sqlite3_bind_double(result, index, number)
        case .null: code = sqlite3_bind_null(result, index)
        }
        guard code == SQLITE_OK else { throw databaseError(db) }
      }
      return result
    } catch {
      sqlite3_finalize(result)
      throw error
    }
  }

  private func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
    let statement = try statement(db, sql, values)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(db) }
  }

  private func executeScript(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError(db) }
  }

  private func query<T>(
    _ db: OpaquePointer, _ sql: String, _ values: [Value] = [],
    map: (OpaquePointer) throws -> T
  ) throws -> [T] {
    let statement = try statement(db, sql, values)
    defer { sqlite3_finalize(statement) }
    var result: [T] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      result.append(try map(statement))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw databaseError(db) }
    return result
  }

  private func integerPragma(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
    try query(db, sql, map: { sqlite3_column_int64($0, 0) }).first ?? 0
  }

  private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
    try execute(db, "BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute(db, "COMMIT")
      return value
    } catch {
      try? execute(db, "ROLLBACK")
      throw error
    }
  }
}
