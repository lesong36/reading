import Foundation

struct ScreenshotQuestionSessionAttachment: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let filename: String
  let ocrText: String
  let createdAt: Date
  let width: Int
  let height: Int

  init(
    id: String = UUID().uuidString, filename: String, ocrText: String = "",
    createdAt: Date = Date(), width: Int, height: Int
  ) {
    self.id = id
    self.filename = filename
    self.ocrText = ocrText
    self.createdAt = createdAt
    self.width = width
    self.height = height
  }
}

struct ScreenshotQuestionSessionTurn: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let question: String
  let answer: String
  let model: String
  let attachmentIDs: [String]
  let createdAt: Date

  init(
    id: String = UUID().uuidString, question: String, answer: String, model: String,
    attachmentIDs: [String] = [], createdAt: Date = Date()
  ) {
    self.id = id
    self.question = question
    self.answer = answer
    self.model = model
    self.attachmentIDs = attachmentIDs
    self.createdAt = createdAt
  }
}

struct ScreenshotQuestionSession: Codable, Sendable, Equatable, Identifiable {
  let id: String
  var title: String
  let createdAt: Date
  var updatedAt: Date
  var pinned: Bool
  var attachments: [ScreenshotQuestionSessionAttachment]
  var turns: [ScreenshotQuestionSessionTurn]

  init(
    id: String = UUID().uuidString, title: String = "未命名会话", createdAt: Date = Date(),
    updatedAt: Date = Date(), pinned: Bool = false,
    attachments: [ScreenshotQuestionSessionAttachment] = [],
    turns: [ScreenshotQuestionSessionTurn] = []
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.pinned = pinned
    self.attachments = attachments
    self.turns = turns
  }
}
