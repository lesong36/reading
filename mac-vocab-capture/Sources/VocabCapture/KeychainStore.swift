import Foundation
import Security

protocol KeychainWriting {
  func update(_ query: [CFString: Any], changes: [CFString: Any]) -> OSStatus
  func add(_ item: [CFString: Any]) -> OSStatus
  func delete(_ query: [CFString: Any]) -> OSStatus
}

struct SystemKeychainWriter: KeychainWriting {
  func update(_ query: [CFString: Any], changes: [CFString: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, changes as CFDictionary)
  }
  func add(_ item: [CFString: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
  func delete(_ query: [CFString: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

enum KeychainStore {
  private static let service = "com.coty.vocab-capture"
  private static let account = "openai-compatible-api-key"
  private static let questionAccount = "screenshot-question-api-key"
  private static let supabaseSessionAccount = "supabase-session"

  static func readAPIKey() -> String {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func saveAPIKey(_ apiKey: String) throws {
    try upsert(apiKey.isEmpty ? nil : Data(apiKey.utf8), account: account)
  }

  static func readSupabaseSession() -> SupabaseSession? {
    guard let data = read(account: supabaseSessionAccount) else { return nil }
    return try? JSONDecoder().decode(SupabaseSession.self, from: data)
  }

  static func readQuestionAPIKey() -> String {
    guard let data = read(account: questionAccount) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func saveQuestionAPIKey(_ apiKey: String) throws {
    try updateQuestionKey(apiKey, account: questionAccount)
  }

  static func readWebSearchAPIKey() -> String {
    guard let data = read(account: "screenshot-question-tavily-api-key") else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func saveWebSearchAPIKey(_ apiKey: String) throws {
    try updateQuestionKey(apiKey, account: "screenshot-question-tavily-api-key")
  }

  static func readQuestionProfileAPIKey(id: String) -> String {
    let account = questionProfileAccount(id: id)
    guard let data = read(account: account) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func saveQuestionProfileAPIKey(_ apiKey: String, id: String) throws {
    try updateQuestionKey(apiKey, account: questionProfileAccount(id: id))
  }

  private static func questionProfileAccount(id: String) -> String {
    id == "legacy" ? questionAccount : "screenshot-question-profile-\(id)"
  }

  private static func updateQuestionKey(_ apiKey: String, account: String) throws {
    try upsert(apiKey.isEmpty ? nil : Data(apiKey.utf8), account: account)
  }

  // Inject only this write boundary in tests; production reads never use a fake keychain.
  static func upsert(_ data: Data?, account: String, writer: any KeychainWriting = SystemKeychainWriter()) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    guard let data else {
      let status = writer.delete(query)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
      }
      return
    }
    let changes: [CFString: Any] = [kSecValueData: data]
    var status = writer.update(query, changes: changes)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData] = data
      status = writer.add(item)
      // Another process may create the item between update and add.
      if status == errSecDuplicateItem { status = writer.update(query, changes: changes) }
    }
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  static func saveSupabaseSession(_ session: SupabaseSession?) throws {
    guard let session else { return try delete(account: supabaseSessionAccount) }
    try write(try JSONEncoder().encode(session), account: supabaseSessionAccount)
  }

  private static func read(account: String) -> Data? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func write(_ data: Data, account: String) throws {
    try upsert(data, account: account)
  }

  private static func delete(account: String) throws {
    try upsert(nil, account: account)
  }
}
