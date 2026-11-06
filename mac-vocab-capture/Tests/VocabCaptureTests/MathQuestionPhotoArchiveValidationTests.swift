import Foundation
import ImageIO
import XCTest

@testable import VocabCapture

final class MathQuestionPhotoArchiveValidationTests: XCTestCase {
  /// Opt-in real-image validation; inputs and temporary archives never enter the repository/user library.
  func testProvidedPhotoBatchRemainsByteIdenticalAfterSaveAndBackup() async throws {
    guard let paths = ProcessInfo.processInfo.environment["MATH_ARCHIVE_SAMPLE_DIRS"] else {
      throw XCTSkip(
        "Set MATH_ARCHIVE_SAMPLE_DIRS to local image directories for optional sample validation")
    }
    let files = try paths.split(separator: ":").flatMap { path in
      try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: String(path)),
        includingPropertiesForKeys: nil
      ).filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }.sorted { $0.path < $1.path }
    XCTAssertFalse(files.isEmpty)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: backup)
    }
    let store = MathQuestionStore(directory: directory)
    var records: [(MathQuestionRecord, Data)] = []
    for file in files {
      let data = try Data(contentsOf: file)
      let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      let record = try await store.save(
        MathQuestionSaveRequest(
          captureID: file.lastPathComponent,
          imageData: data))
      XCTAssertEqual(record.imageWidth, image.width)
      XCTAssertEqual(record.imageHeight, image.height)
      let saved = try await store.originalImage(questionID: record.id)
      XCTAssertEqual(saved, data)
      records.append((record, data))
    }
    try await store.backup(to: backup)
    await store.close()
    let reopened = MathQuestionStore(directory: directory)
    let restored = MathQuestionStore(directory: backup)
    let liveRecords = try await reopened.list()
    let backupRecords = try await restored.list()
    XCTAssertEqual(liveRecords.count, files.count)
    XCTAssertEqual(backupRecords.count, files.count)
    for (record, data) in records {
      let saved = try await reopened.originalImage(questionID: record.id)
      let recovered = try await restored.originalImage(questionID: record.id)
      XCTAssertEqual(saved, data)
      XCTAssertEqual(recovered, data)
    }
    await reopened.close()
    await restored.close()
    print(
      "Validated \(files.count) original photos: dimensions, byte equality, reopen and complete backup"
    )
  }
}
