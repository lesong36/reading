import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionSessionStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("question-sessions-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

  private func image() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 9, bitsPerComponent: 8, bytesPerRow: 48, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func testSessionSurvivesReopenWithMultipleAttachmentsAndTurns() async throws {
    let bytes = try image()
    let store = ScreenshotQuestionSessionStore(directory: directory)
    let created = try await store.create(title: "PDF 第 3 页")
    let one = try await store.appendAttachment(id: created.id, imageData: bytes, ocrText: "第一页")
    let two = try await store.appendAttachment(id: created.id, imageData: bytes, ocrText: "第二页")
    _ = try await store.appendTurn(id: created.id, question: "比较两页", answer: "回答", model: "test", attachmentIDs: [one.attachments[0].id, two.attachments[1].id])
    await store.close()
    let reopened = ScreenshotQuestionSessionStore(directory: directory)
    let session = try await reopened.session(id: created.id)
    XCTAssertEqual(session.title, "PDF 第 3 页")
    XCTAssertEqual(session.attachments.map(\.ocrText), ["第一页", "第二页"])
    XCTAssertEqual(session.turns.first?.attachmentIDs.count, 2)
    let restored = try await reopened.attachmentData(sessionID: created.id, attachmentID: session.attachments[0].id)
    XCTAssertEqual(restored, bytes)
  }

  func testPinnedSessionsSortBeforeRecentSessionsAndBlankRenameUsesDefault() async throws {
    let store = ScreenshotQuestionSessionStore(directory: directory)
    let first = try await store.create(title: "旧")
    _ = try await store.create(title: "新")
    _ = try await store.rename(id: first.id, title: "   ")
    _ = try await store.setPinned(id: first.id, pinned: true)
    let listed = try await store.list()
    XCTAssertEqual(listed.first?.id, first.id)
    XCTAssertEqual(listed.first?.title, "未命名会话")
  }
}
