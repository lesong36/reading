import XCTest
import Security
@testable import VocabCapture

final class KeychainWriteTests: XCTestCase {
  func testFailedUpdatePreservesOldValueWithoutDeletingOrAdding() throws {
    let writer = FakeKeychainWriter()
    writer.updateStatus = errSecAuthFailed
    XCTAssertThrowsError(try KeychainStore.upsert(Data("replacement".utf8), account: "fake-only", writer: writer))
    XCTAssertEqual(writer.calls, ["update"])
    XCTAssertEqual(writer.value, Data("original".utf8))
  }

  func testUpdateExistingValueUsesNoDelete() throws {
    let writer = FakeKeychainWriter()
    try KeychainStore.upsert(Data("replacement".utf8), account: "fake-only", writer: writer)
    XCTAssertEqual(writer.calls, ["update"])
    XCTAssertEqual(writer.value, Data("replacement".utf8))
  }

  func testMissingValueAddsAndConcurrentCreationRetriesUpdate() throws {
    let writer = FakeKeychainWriter()
    writer.updateStatus = errSecItemNotFound
    try KeychainStore.upsert(Data("replacement".utf8), account: "fake-only", writer: writer)
    XCTAssertEqual(writer.calls, ["update", "add"])
    let race = FakeKeychainWriter()
    race.updateStatus = errSecItemNotFound
    race.addStatus = errSecDuplicateItem
    XCTAssertThrowsError(try KeychainStore.upsert(Data("replacement".utf8), account: "fake-only", writer: race))
    XCTAssertEqual(race.calls, ["update", "add", "update"])
    XCTAssertEqual(race.value, Data("original".utf8))
  }

  func testOnlyExplicitClearDeletesAndReportsFailure() throws {
    let writer = FakeKeychainWriter()
    try KeychainStore.upsert(nil, account: "fake-only", writer: writer)
    XCTAssertEqual(writer.calls, ["delete"])
    XCTAssertNil(writer.value)
    let denied = FakeKeychainWriter()
    denied.deleteStatus = errSecAuthFailed
    XCTAssertThrowsError(try KeychainStore.upsert(nil, account: "fake-only", writer: denied))
    XCTAssertEqual(denied.value, Data("original".utf8))
  }
}

private final class FakeKeychainWriter: KeychainWriting {
  var value: Data? = Data("original".utf8)
  var updateStatus: OSStatus = errSecSuccess
  var addStatus: OSStatus = errSecSuccess
  var deleteStatus: OSStatus = errSecSuccess
  var calls: [String] = []
  func update(_ query: [CFString: Any], changes: [CFString: Any]) -> OSStatus {
    calls.append("update")
    if updateStatus == errSecSuccess { value = changes[kSecValueData] as? Data }
    return updateStatus
  }
  func add(_ item: [CFString: Any]) -> OSStatus {
    calls.append("add")
    if addStatus == errSecSuccess { value = item[kSecValueData] as? Data }
    return addStatus
  }
  func delete(_ query: [CFString: Any]) -> OSStatus {
    calls.append("delete")
    if deleteStatus == errSecSuccess { value = nil }
    return deleteStatus
  }
}
