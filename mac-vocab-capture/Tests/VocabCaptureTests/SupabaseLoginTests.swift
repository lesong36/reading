import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class SupabaseLoginTests: XCTestCase {
  func testExpiredLoginExplainsRecoveryAndPreservesSecurePasswordInput() {
    _ = NSApplication.shared
    let prompt = AppDelegate().makeSupabaseLoginAlert(sessionExpired: true)
    XCTAssertEqual(prompt.alert.messageText, "请重新登录阅读达人")
    XCTAssertTrue(prompt.alert.informativeText.contains("本机生词已保留"))
    XCTAssertTrue(prompt.alert.informativeText.contains("重新登录后会同步"))
    XCTAssertEqual(prompt.alert.buttons.map(\.title), ["登录并同步", "取消"])
    XCTAssertEqual(prompt.email.stringValue, "")
    XCTAssertEqual(prompt.password.stringValue, "")
    XCTAssertNotNil(prompt.password.superview)
    prompt.alert.layout()
    XCTAssertGreaterThan(prompt.email.frame.width, 300)
    XCTAssertGreaterThan(prompt.password.frame.height, 20)
  }

  func testFirstLoginDoesNotClaimAnExpiredSession() {
    _ = NSApplication.shared
    let prompt = AppDelegate().makeSupabaseLoginAlert()
    XCTAssertEqual(prompt.alert.messageText, "登录阅读达人账号")
    XCTAssertFalse(prompt.alert.informativeText.contains("失效"))
    XCTAssertTrue(prompt.alert.informativeText.contains("密码不会保存"))
  }
}
