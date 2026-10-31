import CryptoKit
import Foundation
import ImageIO

enum ScreenshotQuestionSessionStoreError: LocalizedError {
  case invalidImage, notFound, conflictingAttachment, damagedAttachment

  var errorDescription: String? {
    switch self {
    case .invalidImage: return "会话截图不是可读取的图片。"
    case .notFound: return "找不到这个问答会话。"
    case .conflictingAttachment: return "同一截图标识对应不同图片。"
    case .damagedAttachment: return "会话截图缺失或已损坏。"
    }
  }
}

/// Persists long-running screenshot conversations independently from the math question archive.
actor ScreenshotQuestionSessionStore {
  nonisolated let directory: URL
  private let indexURL: URL
  private let assetsURL: URL
  private var sessions: [String: ScreenshotQuestionSession] = [:]
  private var loaded = false

  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/VocabCapture/question-sessions", isDirectory: true)
    self.indexURL = self.directory.appendingPathComponent("sessions.json")
    self.assetsURL = self.directory.appendingPathComponent("assets", isDirectory: true)
  }

  func create(title: String = "未命名会话") throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    let session = ScreenshotQuestionSession(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名会话" : title)
    sessions[session.id] = session
    try persist()
    return session
  }

  func list() throws -> [ScreenshotQuestionSession] {
    try loadIfNeeded()
    return sessions.values.sorted { lhs, rhs in
      if lhs.pinned != rhs.pinned { return lhs.pinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  func close() {
    sessions.removeAll()
    loaded = false
  }

  func session(id: String) throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    guard let session = sessions[id] else { throw ScreenshotQuestionSessionStoreError.notFound }
    return session
  }

  @discardableResult
  func rename(id: String, title: String) throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    guard var session = sessions[id] else { throw ScreenshotQuestionSessionStoreError.notFound }
    session.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名会话" : title
    session.updatedAt = Date()
    sessions[id] = session
    try persist()
    return session
  }

  @discardableResult
  func setPinned(id: String, pinned: Bool) throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    guard var session = sessions[id] else { throw ScreenshotQuestionSessionStoreError.notFound }
    session.pinned = pinned
    session.updatedAt = Date()
    sessions[id] = session
    try persist()
    return session
  }

  @discardableResult
  func appendAttachment(
    id sessionID: String, attachmentID: String = UUID().uuidString, imageData: Data,
    ocrText: String = ""
  ) throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    guard var session = sessions[sessionID] else { throw ScreenshotQuestionSessionStoreError.notFound }
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw ScreenshotQuestionSessionStoreError.invalidImage }
    let hash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    let filename = "\(hash).png"
    if let existing = session.attachments.first(where: { $0.id == attachmentID }), existing.filename != filename {
      throw ScreenshotQuestionSessionStoreError.conflictingAttachment
    }
    try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    let assetURL = assetsURL.appendingPathComponent(filename)
    if !FileManager.default.fileExists(atPath: assetURL.path) {
      try imageData.write(to: assetURL, options: .atomic)
    }
    if !session.attachments.contains(where: { $0.id == attachmentID }) {
      session.attachments.append(.init(id: attachmentID, filename: filename, ocrText: ocrText, width: width, height: height))
    }
    session.updatedAt = Date()
    sessions[sessionID] = session
    try persist()
    return session
  }

  @discardableResult
  func appendTurn(
    id sessionID: String, question: String, answer: String, model: String,
    attachmentIDs: [String] = []
  ) throws -> ScreenshotQuestionSession {
    try loadIfNeeded()
    guard var session = sessions[sessionID] else { throw ScreenshotQuestionSessionStoreError.notFound }
    let turn = ScreenshotQuestionSessionTurn(
      question: question, answer: answer, model: model,
      attachmentIDs: attachmentIDs.filter { id in session.attachments.contains { $0.id == id } })
    session.turns.append(turn)
    session.updatedAt = Date()
    sessions[sessionID] = session
    try persist()
    return session
  }

  func attachmentData(sessionID: String, attachmentID: String) throws -> Data {
    try loadIfNeeded()
    guard let session = sessions[sessionID], let attachment = session.attachments.first(where: { $0.id == attachmentID })
    else { throw ScreenshotQuestionSessionStoreError.notFound }
    let url = assetsURL.appendingPathComponent(attachment.filename)
    guard let data = try? Data(contentsOf: url), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == attachment.filename.split(separator: ".").first.map(String.init)
    else { throw ScreenshotQuestionSessionStoreError.damagedAttachment }
    return data
  }

  private func loadIfNeeded() throws {
    guard !loaded else { return }
    loaded = true
    guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
    let data = try Data(contentsOf: indexURL)
    sessions = try JSONDecoder.sessionDecoder.decode([String: ScreenshotQuestionSession].self, from: data)
  }

  private func persist() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder.sessionEncoder.encode(sessions)
    try data.write(to: indexURL, options: .atomic)
  }
}

private extension JSONEncoder {
  static var sessionEncoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}

private extension JSONDecoder {
  static var sessionDecoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
