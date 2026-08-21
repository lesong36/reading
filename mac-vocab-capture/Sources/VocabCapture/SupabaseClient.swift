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
  }
}

struct SupabaseUser: Codable, Sendable { let id: String }

enum SupabaseSyncError: LocalizedError {
  case invalidResponse
  case notLoggedIn
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "Supabase 返回了无法识别的数据。"
    case .notLoggedIn: "请先登录阅读达人账号。"
    case .server(let message): message
    }
  }
}

actor SupabaseVocabularySync {
  // Same public configuration used by the reader. This key is intentionally a
  // publishable key; RLS remains the authorization boundary.
  private let baseURL = URL(string: "https://faeixgpjhnwpfzfkgjsu.supabase.co")!
  private let publishableKey = "sb_publishable_vg-bfePJ4OSgoOOiMEJeCg_7YxdAdkx"

  func signIn(email: String, password: String) async throws -> SupabaseSession {
    let body = try JSONEncoder().encode(["email": email, "password": password])
    let request = makeRequest(path: "/auth/v1/token?grant_type=password", method: "POST", body: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data)
    let session = try JSONDecoder().decode(SupabaseSession.self, from: data)
    try KeychainStore.saveSupabaseSession(session)
    return session
  }

  func signOut() throws { try KeychainStore.saveSupabaseSession(nil) }

  func isLoggedIn() -> Bool { KeychainStore.readSupabaseSession() != nil }

  func sync(local: [VocabularyEntry]) async throws -> [VocabularyEntry] {
    guard let session = try await validSession() else { throw SupabaseSyncError.notLoggedIn }
    let encodedUserID = session.user.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.user.id
    let readRequest = makeRequest(
      path: "/rest/v1/reader_sync_state?user_id=eq.\(encodedUserID)&select=vocabulary",
      method: "GET",
      accessToken: session.accessToken
    )
    let (readData, readResponse) = try await URLSession.shared.data(for: readRequest)
    try validate(response: readResponse, data: readData)
    let remoteRows = try JSONDecoder().decode([ReaderStateRow].self, from: readData)
    let merged = merge(local, remoteRows.first?.vocabulary ?? [])
    let payload = try JSONEncoder().encode(ReaderStateUpdate(vocabulary: merged, updatedAt: ISO8601DateFormatter().string(from: .now)))
    var writeRequest = makeRequest(
      path: "/rest/v1/reader_sync_state?user_id=eq.\(encodedUserID)",
      method: "PATCH",
      accessToken: session.accessToken,
      body: payload
    )
    writeRequest.setValue("return=representation", forHTTPHeaderField: "Prefer")
    let (writeData, writeResponse) = try await URLSession.shared.data(for: writeRequest)
    try validate(response: writeResponse, data: writeData)
    return merged
  }

  private func validSession() async throws -> SupabaseSession? {
    guard let session = KeychainStore.readSupabaseSession() else { return nil }
    guard let expiresAt = session.expiresAt, Date(timeIntervalSince1970: TimeInterval(expiresAt)) < Date().addingTimeInterval(60) else { return session }
    let body = try JSONEncoder().encode(["refresh_token": session.refreshToken])
    let request = makeRequest(path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    try validate(response: response, data: data)
    let refreshed = try JSONDecoder().decode(SupabaseSession.self, from: data)
    try KeychainStore.saveSupabaseSession(refreshed)
    return refreshed
  }

  private func makeRequest(path: String, method: String, accessToken: String? = nil, body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
    request.httpMethod = method
    request.httpBody = body
    request.setValue(publishableKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
    return request
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw SupabaseSyncError.invalidResponse }
    guard 200..<300 ~= http.statusCode else {
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])? ["msg"] as? String
      throw SupabaseSyncError.server(message ?? "Supabase 请求失败（HTTP \(http.statusCode)）。")
    }
  }

  private func merge(_ local: [VocabularyEntry], _ remote: [VocabularyEntry]) -> [VocabularyEntry] {
    var byWord: [String: VocabularyEntry] = [:]
    for entry in remote + local {
      let key = entry.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !key.isEmpty else { continue }
      if byWord[key] == nil || entry.timestamp >= (byWord[key]?.timestamp ?? 0) { byWord[key] = entry }
    }
    return byWord.values.sorted { $0.timestamp > $1.timestamp }
  }
}

private struct ReaderStateRow: Codable { let vocabulary: [VocabularyEntry] }
private struct ReaderStateUpdate: Codable {
  let vocabulary: [VocabularyEntry]
  let updatedAt: String
  enum CodingKeys: String, CodingKey { case vocabulary; case updatedAt = "updated_at" }
}
