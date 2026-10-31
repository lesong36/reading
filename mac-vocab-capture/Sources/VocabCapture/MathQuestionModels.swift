import Foundation

struct MathQuestionSolution: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let question: String
  let answer: String
  let model: String
  let createdAt: Date

  init(
    id: String = UUID().uuidString, question: String, answer: String, model: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.question = question
    self.answer = answer
    self.model = model
    self.createdAt = createdAt
  }
}

struct MathQuestionSaveRequest: Sendable {
  let captureID: String
  let imageData: Data
  let ocrText: String
  let solutions: [MathQuestionSolution]

  init(
    captureID: String, imageData: Data, ocrText: String = "",
    solutions: [MathQuestionSolution] = []
  ) {
    self.captureID = captureID
    self.imageData = imageData
    self.ocrText = ocrText
    self.solutions = solutions
  }
}

struct MathQuestionRecord: Sendable, Equatable, Identifiable {
  let id: String
  let title: String
  let createdAt: Date
  let imageWidth: Int
  let imageHeight: Int
  let ocrText: String
  let ocrStatus: String
}
