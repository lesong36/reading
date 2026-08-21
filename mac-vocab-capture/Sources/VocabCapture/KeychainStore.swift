import Foundation
import Security

enum KeychainStore {
  private static let service = "com.coty.vocab-capture"
  private static let account = "openai-compatible-api-key"

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
}
