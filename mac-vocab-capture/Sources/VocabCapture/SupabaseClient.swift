import Foundation

struct SupabaseSession: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let user: SupabaseUser
  let expiresAt: Int?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case user
    case expiresAt = "expires_at"
    case expiresIn = "expires_in"
  }

  init(accessToken: String, refreshToken: String, user: SupabaseUser, expiresAt: Int?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.user = user
    self.expiresAt = expiresAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try values.decode(String.self, forKey: .accessToken)
    refreshToken = try values.decode(String.self, forKey: .refreshToken)
    user = try values.decode(SupabaseUser.self, forKey: .user)
    let expiresIn = try values.decodeIfPresent(Int.self, forKey: .expiresIn)
    expiresAt =
      try values.decodeIfPresent(Int.self, forKey: .expiresAt)
      ?? expiresIn.map { Int(Date().timeIntervalSince1970) + $0 }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(accessToken, forKey: .accessToken)
    try values.encode(refreshToken, forKey: .refreshToken)
    try values.encode(user, forKey: .user)
    try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
  }
}

struct SupabaseUser: Codable, Sendable { let id: String }

enum SupabaseSyncError: LocalizedError {
  case invalidResponse
  case notLoggedIn
  case sessionExpired
  case server(String)
  case http(Int)
  case upgradeRequired
  case conflict([String])
  case accountChanged

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "Supabase 返回了无法识别的数据。"
    case .notLoggedIn: "请先登录阅读达人账号。"
    case .sessionExpired: "阅读达人登录已失效，请重新登录。本机生词已保留。"
    case .server(let message): message
    case .http(let status): "云同步请求失败（HTTP \(status)），本机待上传内容已保留。"
    case .upgradeRequired: "云端词库同步协议尚未升级，已保留本机待上传内容。请部署词库同步 v2 后重试。"
    case .conflict: "云端词条已经修改或删除。已保留本机操作，请确认采用云端内容或重新编辑后同步。"
    case .accountChanged: "账号已经切换，已忽略旧账号的同步结果。"
    }
  }
}

struct VocabularySyncResult: Codable, Sendable {
  let userID: String
  let vocabulary: [VocabularyEntry]
  let uploadedCount: Int
  let revision: Int64
  let acknowledgedOperationIDs: [String]
  let tombstones: [VocabularyTombstone]
  let conflict: Bool
  let conflictingWordKeys: [String]
}

actor SupabaseVocabularySync {
  // Same public configuration used by the reader. This key is intentionally a
  // publishable key; RLS remains the authorization boundary.
  private let baseURL = URL(string: "https://faeixgpjhnwpfzfkgjsu.supabase.co")!
  private let publishableKey = "sb_publishable_vg-bfePJ4OSgoOOiMEJeCg_7YxdAdkx"

  private let session: URLSession
  private let readSession: @Sendable () -> SupabaseSession?
  private let saveSession: @Sendable (SupabaseSession?) throws -> Void
  private var sessionRevision = 0
  private var refreshFlight:
    (
      id: UUID, token: String, revision: Int, task: Task<SupabaseSession?, Error>
    )?

  init(
    session: URLSession = .shared,
    readSession: @escaping @Sendable () -> SupabaseSession? = {
      KeychainStore.readSupabaseSession()
    },
    saveSession: @escaping @Sendable (SupabaseSession?) throws -> Void = {
      try KeychainStore.saveSupabaseSession($0)
    }
  ) {
    self.session = session
    self.readSession = readSession
    self.saveSession = saveSession
  }

  func signIn(email: String, password: String) async throws -> SupabaseSession {
    let body = try JSONEncoder().encode(["email": email, "password": password])
    let request = makeRequest(
      path: "/auth/v1/token?grant_type=password", method: "POST", body: body)
    let (data, response) = try await self.session.data(for: request)
    try validate(response: response, data: data)
    let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
    try saveSession(session)
    sessionRevision += 1
    refreshFlight = nil
    return session
  }

  func signOut() throws {
    try saveSession(nil)
    sessionRevision += 1
    refreshFlight = nil
  }

  func isLoggedIn() -> Bool { readSession() != nil }

  func currentUserID() -> String? { readSession()?.user.id }
  func currentSessionRevision() -> Int { sessionRevision }

  // Kept for existing read-only integrations. Full-array writes are intentionally
  // forbidden: they cannot express ownership, per-entry conflicts or restoration.
  func sync(local: [VocabularyEntry]) async throws -> VocabularySyncResult {
    guard let stored = try await validSession() else { throw SupabaseSyncError.notLoggedIn }
    guard local.isEmpty else { throw SupabaseSyncError.upgradeRequired }
    return try await sync(batch: VocabularySyncBatch(userID: stored.user.id, baseRevision: 0, operations: []))
  }

  func sync(batch: VocabularySyncBatch) async throws -> VocabularySyncResult {
    guard let stored = try await validSession() else { throw SupabaseSyncError.notLoggedIn }
    let ownerRevision = sessionRevision
    guard stored.user.id.lowercased() == batch.userID.lowercased() else {
      throw SupabaseSyncError.accountChanged
    }
    let ids = batch.operations.map(\.operationID)
    guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }), batch.baseRevision >= 0,
      batch.operations.allSatisfy({ !$0.wordKey.isEmpty && VocabularyEntry.canonicalWordKey($0.wordKey) == $0.wordKey })
    else { throw SupabaseSyncError.invalidResponse }
    var expectedRevision = batch.baseRevision
    for attempt in 0..<3 {
      try guardAccount(batch.userID, revision: ownerRevision)
      let body = try JSONEncoder().encode(VocabularyRPCRequest(
        expectedRevision: batch.operations.isEmpty ? nil : expectedRevision,
        operations: batch.operations))
      let data = try await authenticatedRPC(body: body, userID: batch.userID, revision: ownerRevision)
      try guardAccount(batch.userID, revision: ownerRevision)
      guard let result = try? JSONDecoder().decode(VocabularySyncResult.self, from: data),
        result.userID.lowercased() == batch.userID.lowercased(), result.revision >= expectedRevision,
        result.uploadedCount >= 0, result.uploadedCount <= batch.operations.count,
        Set(result.acknowledgedOperationIDs).isSubset(of: Set(ids)),
        Set(result.acknowledgedOperationIDs).count == result.acknowledgedOperationIDs.count,
        Set(result.vocabulary.map { VocabularyEntry.canonicalWordKey($0.word) }).count == result.vocabulary.count,
        result.vocabulary.allSatisfy({ !VocabularyEntry.canonicalWordKey($0.word).isEmpty && ($0.cloudVersion ?? -1) >= 0 }),
        result.tombstones.allSatisfy({ !$0.wordKey.isEmpty && VocabularyEntry.canonicalWordKey($0.wordKey) == $0.wordKey && $0.version >= 0 }),
        Set(result.tombstones.map(\.wordKey)).count == result.tombstones.count,
        Set(result.vocabulary.map { VocabularyEntry.canonicalWordKey($0.word) }).isDisjoint(with: Set(result.tombstones.map(\.wordKey)))
      else { throw SupabaseSyncError.invalidResponse }
      if !result.conflict {
        guard Set(result.acknowledgedOperationIDs) == Set(ids) else {
          throw SupabaseSyncError.invalidResponse
        }
        return result
      }
      guard result.conflictingWordKeys.isEmpty, attempt < 2 else {
        throw SupabaseSyncError.conflict(result.conflictingWordKeys)
      }
      // Only advance the snapshot revision. Keep original entry base versions;
      // changing them here would silently overwrite another device's edit.
      expectedRevision = result.revision
    }
    throw SupabaseSyncError.invalidResponse
  }

  private func guardAccount(_ userID: String, revision: Int) throws {
    guard sessionRevision == revision, readSession()?.user.id.lowercased() == userID.lowercased() else {
      throw SupabaseSyncError.accountChanged
    }
  }

  private func authenticatedRPC(body: Data, userID: String, revision: Int) async throws -> Data {
    var rejectedAccessToken: String?
    for attempt in 0..<2 {
      try guardAccount(userID, revision: revision)
      guard let stored = try await validSession(forceRefresh: attempt == 1 && readSession()?.accessToken == rejectedAccessToken) else {
        throw SupabaseSyncError.notLoggedIn
      }
      try guardAccount(userID, revision: revision)
      let request = makeRequest(path: "/rest/v1/rpc/sync_reader_vocabulary_v2", method: "POST",
        accessToken: stored.accessToken, body: body)
      let (data, response) = try await session.data(for: request)
      try guardAccount(userID, revision: revision)
      guard let http = response as? HTTPURLResponse else { throw SupabaseSyncError.invalidResponse }
      if http.statusCode == 401 {
        if attempt == 0 { rejectedAccessToken = stored.accessToken; continue }
        try saveSession(nil)
        sessionRevision += 1
        throw SupabaseSyncError.sessionExpired
      }
      if [404, 405].contains(http.statusCode) { throw SupabaseSyncError.upgradeRequired }
      if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        ["PGRST202", "42883"].contains(payload["code"] as? String ?? "") {
        throw SupabaseSyncError.upgradeRequired
      }
      try validate(response: response, data: data)
      return data
    }
    throw SupabaseSyncError.sessionExpired
  }

  private func validSession(forceRefresh: Bool = false) async throws -> SupabaseSession? {
    guard let stored = readSession() else { return nil }
    let expiresSoon = stored.expiresAt.map {
      Date(timeIntervalSince1970: TimeInterval($0)) < Date().addingTimeInterval(60)
    } ?? false
    guard forceRefresh || expiresSoon else { return stored }

    let flight: (id: UUID, token: String, revision: Int, task: Task<SupabaseSession?, Error>)
    if let active = refreshFlight,
      active.token == stored.refreshToken, active.revision == sessionRevision
    {
      flight = active
    } else {
      let revision = sessionRevision
      let task = Task { try await refreshSession(stored, revision: revision) }
      flight = (UUID(), stored.refreshToken, revision, task)
      refreshFlight = flight
    }
    defer {
      if refreshFlight?.id == flight.id { refreshFlight = nil }
    }
    return try await flight.task.value
  }

  private func refreshSession(_ stored: SupabaseSession, revision: Int) async throws
    -> SupabaseSession?
  {
    let body = try JSONEncoder().encode(["refresh_token": stored.refreshToken])
    let request = makeRequest(
      path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: body)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      guard ownsSession(stored, revision: revision) else { return readSession() }
      throw error
    }
    // An older refresh must not erase or overwrite a login completed while it awaited the server.
    guard ownsSession(stored, revision: revision) else { return readSession() }
    if isInvalidRefresh(response: response, data: data) {
      try saveSession(nil)
      throw SupabaseSyncError.sessionExpired
    }
    try validate(response: response, data: data)
    let refreshed = try JSONDecoder().decode(SupabaseSession.self, from: data)
    try saveSession(refreshed)
    return refreshed
  }

  private func ownsSession(_ stored: SupabaseSession, revision: Int) -> Bool {
    sessionRevision == revision && readSession()?.refreshToken == stored.refreshToken
  }

  private func isInvalidRefresh(response: URLResponse, data: Data) -> Bool {
    guard let http = response as? HTTPURLResponse, [400, 401].contains(http.statusCode),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    let code = payload["code"] as? String ?? payload["error_code"] as? String
    if let code {
      return ["refresh_token_not_found", "refresh_token_already_used", "session_not_found"]
        .contains(code)
    }
    let message =
      payload["msg"] as? String
      ?? payload["message"] as? String
      ?? payload["error_description"] as? String
    return message?.lowercased().contains("invalid refresh token") == true
  }

  private func makeRequest(
    path: String, method: String, accessToken: String? = nil, body: Data? = nil
  ) -> URLRequest {
    var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
    request.httpMethod = method
    request.httpBody = body
    request.setValue(publishableKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let accessToken {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw SupabaseSyncError.invalidResponse }
    guard 200..<300 ~= http.statusCode else {
      throw SupabaseSyncError.http(http.statusCode)
    }
  }

}

private struct VocabularyRPCRequest: Encodable {
  let expectedRevision: Int64?
  let operations: [VocabularyMutation]
  enum CodingKeys: String, CodingKey {
    case expectedRevision = "p_expected_revision"
    case operations = "p_operations"
  }
}
