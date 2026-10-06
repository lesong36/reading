import Foundation

enum VocabularyMutationKind: String, Codable, Sendable { case upsert, restore, delete }

enum VocabularyConflictStrategy: Sendable { case adoptCloud, resubmitLocal }

struct VocabularyWriteScope: Sendable, Equatable {
  let userID: String?
  let accountGeneration: UInt64
}

struct VocabularyMutation: Codable, Sendable, Equatable {
  let operationID: String
  let kind: VocabularyMutationKind
  let wordKey: String
  let entry: VocabularyEntry?
  let baseVersion: Int64?
}

struct VocabularySyncBatch: Sendable {
  let userID: String
  let baseRevision: Int64
  let operations: [VocabularyMutation]
  let accountGeneration: UInt64
  init(userID: String, baseRevision: Int64, operations: [VocabularyMutation], accountGeneration: UInt64 = 0) {
    self.userID = userID
    self.baseRevision = baseRevision
    self.operations = operations
    self.accountGeneration = accountGeneration
  }
}

struct VocabularyTombstone: Codable, Sendable, Equatable {
  let wordKey: String
  let version: Int64
  let deletedAt: String?
}

struct VocabularyPersistenceStatus: Sendable {
  let userID: String?
  let pendingCount: Int
  let unassignedCount: Int
  let issue: String?
  let fileURL: URL
  let backupURLs: [URL]
  var canSync: Bool { userID != nil && issue == nil }
}

enum VocabularyPersistenceError: LocalizedError {
  case unreadableStore(String), unsupportedVersion(Int), accountChanged, unknownOperations, bindingInProgress
  var errorDescription: String? {
    switch self {
    case .unreadableStore: "本机词库无法读取，已停止写入。请导出原文件或从备份恢复。"
    case .unsupportedVersion: "本机词库版本暂不支持，已保留原文件并停止写入。"
    case .accountChanged: "账号已经切换，已忽略旧账号的同步结果。"
    case .unknownOperations: "同步确认与待上传操作不一致，已保留本机待上传内容。"
    case .bindingInProgress: "本机词库绑定尚未完成，请先继续原账号的绑定。原始文件已保留。"
    }
  }
}

struct VocabularyEnvelope: Codable, Sendable {
  var schemaVersion = 1
  var userID: String?
  var localRevision: Int64 = 0
  var cloudRevision: Int64 = 0
  var entries: [VocabularyEntry] = []
  var pending: [VocabularyMutation] = []
  var tombstones: [VocabularyTombstone] = []
  var legacyAdoptedBy: String?
  var adoption: VocabularyAdoptionRecord?
  var completedAdoptionIDs: [String]?
}

struct VocabularyAdoptionRecord: Codable, Sendable {
  let bindingID: String
  let userID: String
  let operations: [VocabularyMutation]
}
