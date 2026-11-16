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
    case .upgradeRequired: "云端增量同步暂不可用，本机待上传内容已保留，请更新服务后重试。"
    case .conflict: "云端词条已经修改或删除。已保留本机操作，请确认采用云端内容或重新编辑后同步。"
    case .accountChanged: "账号已经切换，已忽略旧账号的同步结果。"
    }
  }
}

struct VocabularySyncResult: Codable, Sendable {
  var deltaState: VocabularyDeltaState? = nil
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
    guard batch.operations.count <= 50, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }), batch.baseRevision >= 0,
      batch.operations.allSatisfy({ !$0.wordKey.isEmpty && VocabularyEntry.canonicalWordKey($0.wordKey) == $0.wordKey })
    else { throw SupabaseSyncError.invalidResponse }
    return try await syncDelta(batch: batch, ownerRevision: ownerRevision)
  }

  private func syncDelta(batch: VocabularySyncBatch, ownerRevision: Int) async throws -> VocabularySyncResult {
    var state = batch.deltaState ?? VocabularyDeltaState()
    if batch.deltaState == nil { state.legacyOperationIDs = batch.legacyOperationIDs ?? Set(batch.operations.map(\.operationID)) }
    func rpc(_ name: String, _ body: [String: Any]) async throws -> [String: Any] {
      let data = try await authenticatedRPC(body: JSONSerialization.data(withJSONObject: body),
        userID: batch.userID, revision: ownerRevision, name: name)
      guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SupabaseSyncError.invalidResponse }
      return value
    }
    func entity(_ raw: [String: Any]) throws -> VocabularyDeltaEntity {
      let row = try JSONDecoder().decode(VocabularyDeltaEntity.self, from: JSONSerialization.data(withJSONObject: raw))
      guard row.entityType == "vocabulary", !row.entityID.isEmpty,
        VocabularyEntry.canonicalWordKey(row.entityID) == row.entityID, row.version >= 0,
        row.deleted || row.payload != nil,
        row.payload.map({ VocabularyEntry.canonicalWordKey($0.word) == row.entityID }) ?? row.deleted
      else { throw SupabaseSyncError.invalidResponse }
      return row
    }
    // Complete the cloud mirror before projecting a full vocabulary snapshot.
    var finished = false
    for _ in 0..<10000 {
      let page = try await rpc("reader_delta_pull", ["p_epoch": state.epoch as Any? ?? NSNull(), "p_cursor": state.cursor, "p_limit": 50])
      guard let epoch = page["epoch"] as? String else { throw SupabaseSyncError.invalidResponse }
      if page["resetRequired"] as? Bool == true {
        state = VocabularyDeltaState(legacyOperationIDs: state.legacyOperationIDs, epoch: epoch)
        continue
      }
      guard state.epoch == nil || state.epoch == epoch,
        let cursor = page["nextCursor"] as? Int64, cursor >= state.cursor,
        let changes = page["changes"] as? [[String: Any]], changes.count <= 50,
        let more = page["hasMore"] as? Bool else { throw SupabaseSyncError.invalidResponse }
      guard !more || cursor > state.cursor else { throw SupabaseSyncError.invalidResponse }
      for raw in changes where raw["entityType"] as? String == "vocabulary" {
        let row = try entity(raw)
        state.entities[row.entityID] = row
      }
      state.epoch = epoch
      state.cursor = cursor
      if !more { finished = true; break }
    }
    guard finished else { throw SupabaseSyncError.invalidResponse }
    if !batch.operations.isEmpty {
      let response = try await rpc("reader_delta_get", ["p_entities": batch.operations.map { ["entityType": "vocabulary", "entityID": $0.wordKey] }])
      guard let rows = response["entities"] as? [[String: Any]], rows.count == batch.operations.count else { throw SupabaseSyncError.invalidResponse }
      let decoded = try rows.map(entity)
      guard Set(decoded.map(\.entityID)) == Set(batch.operations.map(\.wordKey)) else { throw SupabaseSyncError.invalidResponse }
      for row in decoded { state.entities[row.entityID] = row }
    }
    let journalRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("VocabCapture/delta-wire", isDirectory: true)
      .appendingPathComponent(batch.userID.utf8.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
    var conflicts: [String] = []
    var equivalentIDs: [String] = []
    var operations: [[String: Any]] = []
    for op in batch.operations {
      let journalURL = journalRoot.appendingPathComponent(op.operationID.utf8.map { String(format: "%02x", $0) }.joined()).appendingPathExtension("json")
      let mutationEncoder = JSONEncoder()
      mutationEncoder.outputFormatting = [.sortedKeys]
      let mutationFingerprint = try mutationEncoder.encode(op).base64EncodedString()
      if FileManager.default.fileExists(atPath: journalURL.path) {
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
        guard let record = saved as? [String: Any], record["mutation"] as? String == mutationFingerprint,
          let wire = record["wire"] as? [String: Any], wire["operationID"] as? String == op.operationID,
          wire["entityID"] as? String == op.wordKey else { throw SupabaseSyncError.invalidResponse }
        operations.append(wire)
        continue
      }
      let remote = state.entities[op.wordKey]
      // A v2 global revision cannot prove a protocol3 entity base. Existing
      // legacy records are acknowledged only when the full payload is equal.
      let base: Int64
      if !(state.legacyOperationIDs ?? []).contains(op.operationID) { base = op.baseVersion ?? 0 }
      else if let remote, remote.version > 0 {
        if op.kind != .delete, !remote.deleted, let local = op.entry, let cloud = remote.payload {
          var localJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as! [String: Any]
          var cloudJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud)) as! [String: Any]
          localJSON.removeValue(forKey: "cloudVersion"); cloudJSON.removeValue(forKey: "cloudVersion")
          if NSDictionary(dictionary: localJSON).isEqual(to: cloudJSON) { equivalentIDs.append(op.operationID); continue }
        }
        conflicts.append(op.wordKey)
        continue
      } else {
        guard op.baseVersion == nil else { conflicts.append(op.wordKey); continue }
        base = 0
      }
      var wire: [String: Any] = ["operationID": op.operationID, "entityType": "vocabulary", "entityID": op.wordKey, "baseVersion": base, "kind": op.kind.rawValue]
      wire["payload"] = try op.entry.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
      try JSONSerialization.data(withJSONObject: ["mutation": mutationFingerprint, "wire": wire], options: [.sortedKeys]).write(to: journalURL, options: .atomic)
      operations.append(wire)
    }
    guard try JSONSerialization.data(withJSONObject: ["p_operations": operations]).count <= 100_000,
      try operations.allSatisfy({ try JSONSerialization.data(withJSONObject: $0).count <= 64_000 })
    else { throw SupabaseSyncError.invalidResponse }
    var acknowledged: [String] = equivalentIDs
    if !operations.isEmpty {
      let pushed = try await rpc("reader_delta_push", ["p_operations": operations])
      guard pushed["epoch"] as? String == state.epoch, let acks = pushed["acknowledgements"] as? [[String: Any]], acks.count == operations.count, Set(acks.compactMap { $0["operationID"] as? String }).count == acks.count else { throw SupabaseSyncError.invalidResponse }
      for ack in acks {
        guard let id = ack["operationID"] as? String, let op = batch.operations.first(where: { $0.operationID == id }),
          let version = ack["version"] as? Int64, version >= 0,
          let status = ack["status"] as? String else { throw SupabaseSyncError.invalidResponse }
        if status == "conflict" { conflicts.append(op.wordKey); continue }
        guard status == "applied" || status == "duplicate" else { throw SupabaseSyncError.invalidResponse }
        acknowledged.append(id)
        // Read current state after receipt acknowledgement: a duplicate receipt
        // can precede a newer edit from another device.
        let fresh = try await rpc("reader_delta_get", ["p_entities": [["entityType": "vocabulary", "entityID": op.wordKey]]])
        guard let rows = fresh["entities"] as? [[String: Any]], rows.count == 1 else { throw SupabaseSyncError.invalidResponse }
        let current = try entity(rows[0])
        guard current.entityID == op.wordKey, current.version >= version else { throw SupabaseSyncError.invalidResponse }
        state.entities[op.wordKey] = current
      }
    }
    state.legacyOperationIDs?.subtract(acknowledged)
    let vocabulary = state.entities.values.filter { !$0.deleted }.compactMap { row -> VocabularyEntry? in
      guard var entry = row.payload else { return nil }; entry.cloudVersion = row.version; return entry
    }
    let tombstones = state.entities.values.filter(\.deleted).map { VocabularyTombstone(wordKey: $0.entityID, version: $0.version, deletedAt: nil) }
    return VocabularySyncResult(deltaState: state, userID: batch.userID, vocabulary: vocabulary,
      uploadedCount: acknowledged.count - equivalentIDs.count, revision: max(batch.baseRevision, state.cursor), acknowledgedOperationIDs: acknowledged,
      tombstones: tombstones, conflict: !conflicts.isEmpty, conflictingWordKeys: conflicts)
  }

  private func guardAccount(_ userID: String, revision: Int) throws {
    guard sessionRevision == revision, readSession()?.user.id.lowercased() == userID.lowercased() else {
      throw SupabaseSyncError.accountChanged
    }
  }

  private func authenticatedRPC(body: Data, userID: String, revision: Int, name: String) async throws -> Data {
    var rejectedAccessToken: String?
    for attempt in 0..<2 {
      try guardAccount(userID, revision: revision)
      guard let stored = try await validSession(forceRefresh: attempt == 1 && readSession()?.accessToken == rejectedAccessToken) else {
        throw SupabaseSyncError.notLoggedIn
      }
      try guardAccount(userID, revision: revision)
      let request = makeRequest(path: "/rest/v1/rpc/\(name)", method: "POST",
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
      if !(200..<300).contains(http.statusCode),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let code = payload["code"] as? String,
        code.range(of: "^[A-Z0-9]{5,10}$", options: .regularExpression) != nil {
        let upgrade = payload["message"] as? String == "READER_UPGRADE_REQUIRED: protocol 3 required"
        let reason = upgrade ? " READER_UPGRADE_REQUIRED" : ""
        let diagnosticURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
          .appendingPathComponent("VocabCapture/sync-error-code.txt")
        if let diagnosticURL {
          try? "HTTP \(http.statusCode) code \(code) rpc \(name)\(reason)".write(to: diagnosticURL, atomically: true, encoding: .utf8)
        }
        // Never expose server details that may contain user data.
        throw SupabaseSyncError.server("云同步请求失败（HTTP \(http.statusCode)，代码 \(code)\(reason)），本机待上传内容已保留。")
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
