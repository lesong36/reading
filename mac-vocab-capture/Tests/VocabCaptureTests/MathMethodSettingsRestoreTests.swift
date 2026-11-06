import AppKit
import XCTest
@testable import VocabCapture

private actor SuspendedMethodRead {
  private var continuation: CheckedContinuation<[MathMethodImportEntry], Never>?
  private(set) var started = false
  func read() async -> [MathMethodImportEntry] {
    started = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish() {
    continuation?.resume(returning: [.init(sourceID: "late", title: "迟到的方法",
      category: "旧目录", instructions: "旧目录读取完毕后不得写入恢复后的库")])
    continuation = nil
  }
}

@MainActor
final class MathMethodSettingsRestoreTests: XCTestCase {
  func testLateReadAfterRestoreCannotImportOldMethodsOrCallSaveCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = MathQuestionStore(directory: root.appendingPathComponent("source"))
    let restoredMethod = try await source.saveMethod(title: "恢复的方法", category: "备份", instructions: "保留备份内容")
    let backup = root.appendingPathComponent("backup")
    try await source.backup(to: backup)
    await source.close()
    let store = MathQuestionStore(directory: root.appendingPathComponent("current"))
    _ = try await store.saveMethod(title: "旧的方法", category: "原库", instructions: "恢复前内容")
    let gate = SuspendedMethodRead()
    var callbacks = 0
    let editor = MathMethodSettings(store: store, readDirectory: { _ in await gate.read() },
      onSave: { callbacks += 1 })
    let readTask = try XCTUnwrap(editor.importDirectory(root))
    for _ in 0..<100 {
      if await gate.started { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let started = await gate.started
    XCTAssertTrue(started)
    await editor.prepareForLibraryRestore()
    _ = try await store.restoreBackup(from: backup)
    // The reader intentionally ignores cancellation and returns after the atomic restore.
    await gate.finish()
    await readTask.value
    let methods = try await store.methods()
    XCTAssertEqual(methods.map(\.id), [restoredMethod.id])
    XCTAssertEqual(callbacks, 0)
    XCTAssertNil(editor.importDirectory(root), "Invalidated editors must not restart old writes")
    await store.close()
  }

  func testCurrentGenerationImportStillWritesAndReportsCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var callbacks = 0
    let editor = MathMethodSettings(store: store, readDirectory: { _ in
      [.init(sourceID: "normal", title: "新方法", category: "正常导入", instructions: "解题步骤")]
    }, onSave: { callbacks += 1 })
    let task = try XCTUnwrap(editor.importDirectory(root))
    await task.value
    let methods = try await store.methods()
    XCTAssertEqual(methods.map(\.title), ["新方法"])
    XCTAssertEqual(callbacks, 1)
    await editor.prepareForLibraryRestore()
    await store.close()
  }
}
