import Foundation

/// Kept in the account envelope so cursor and materialized cloud data commit together.
struct VocabularyDeltaState: Codable, Sendable {
  var legacyOperationIDs: Set<String>?
  var epoch: String?
  var cursor: Int64 = 0
  var entities: [String: VocabularyDeltaEntity] = [:]
}

struct VocabularyDeltaEntity: Codable, Sendable {
  let entityType: String
  let entityID: String
  let version: Int64
  let deleted: Bool
  let payload: VocabularyEntry?
}
