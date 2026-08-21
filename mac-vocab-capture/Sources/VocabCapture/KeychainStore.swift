import Foundation
import Security

enum KeychainStore {
  private static let service = "com.coty.vocab-capture"
  private static let account = "openai-compatible-api-key"
  private static let supabaseSessionAccount = "supabase-session"

  static func readAPIKey() -> String {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  static func saveAPIKey(_ apiKey: String) throws {
    let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    SecItemDelete(base as CFDictionary)
    guard !apiKey.isEmpty else { return }
    var item = base
    item[kSecValueData] = Data(apiKey.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  static func readSupabaseSession() -> SupabaseSession? {
    guard let data = read(account: supabaseSessionAccount) else { return nil }
    return try? JSONDecoder().decode(SupabaseSession.self, from: data)
  }

  static func saveSupabaseSession(_ session: SupabaseSession?) throws {
    guard let session else { return try delete(account: supabaseSessionAccount) }
    try write(try JSONEncoder().encode(session), account: supabaseSessionAccount)
  }

  private static func read(account: String) -> Data? {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func write(_ data: Data, account: String) throws {
    try delete(account: account)
    let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecValueData: data]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }

  private static func delete(account: String) throws {
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
