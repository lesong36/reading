import Foundation

struct MathQuestionSolution: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let question: String
  let answer: String
  let model: String
  let createdAt: Date
  let verificationStatus: String
  let method: MathTeachingMethod?
  let visualMethods: [MathTeachingMethod]
  let diagrams: [MathDiagram]
  let diagramFailure: String?
  /// Records an automatic method prerequisite refusal, independently of answer verification.
  let selectionFailure: String?
  let methodClaimWarning: String?
  let reviewedExamples: [MathReviewedExampleReference]

  /// Derived from the original answer, including when an older archive is reopened.
  var arithmeticNotice: String? { MathExplicitAdditionAudit.notice(in: answer) }

  init(
    id: String = UUID().uuidString, question: String, answer: String, model: String,
    createdAt: Date = Date(), verificationStatus: String = "unverified",
    method: MathTeachingMethod? = nil, visualMethods: [MathTeachingMethod] = [],
    diagrams: [MathDiagram] = [], diagramFailure: String? = nil, selectionFailure: String? = nil,
    methodClaimWarning: String? = nil, reviewedExamples: [MathReviewedExampleReference] = []
  ) {
    self.id = id
    self.question = question
    self.answer = answer
    self.model = model
    self.createdAt = createdAt
    self.verificationStatus = verificationStatus
    self.method = method
    self.visualMethods = visualMethods
    self.diagrams = diagrams
    self.diagramFailure = diagramFailure
    self.selectionFailure = selectionFailure
    self.methodClaimWarning = methodClaimWarning
    self.reviewedExamples = reviewedExamples
  }

  private enum CodingKeys: String, CodingKey {
    case id, question, answer, model, createdAt, verificationStatus, method, visualMethods, diagrams, diagramFailure, selectionFailure, methodClaimWarning, reviewedExamples
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(String.self, forKey: .id),
      question: try values.decode(String.self, forKey: .question),
      answer: try values.decode(String.self, forKey: .answer),
      model: try values.decode(String.self, forKey: .model),
      createdAt: try values.decode(Date.self, forKey: .createdAt),
      verificationStatus: try values.decodeIfPresent(String.self, forKey: .verificationStatus)
        ?? "unverified",
      method: try values.decodeIfPresent(MathTeachingMethod.self, forKey: .method),
      visualMethods: try values.decodeIfPresent([MathTeachingMethod].self, forKey: .visualMethods)
        ?? [],
      diagrams: try values.decodeIfPresent([MathDiagram].self, forKey: .diagrams) ?? [],
      diagramFailure: try values.decodeIfPresent(String.self, forKey: .diagramFailure),
      selectionFailure: try values.decodeIfPresent(String.self, forKey: .selectionFailure),
      methodClaimWarning: try values.decodeIfPresent(String.self, forKey: .methodClaimWarning),
      reviewedExamples: try values.decodeIfPresent([MathReviewedExampleReference].self, forKey: .reviewedExamples) ?? [])
    try MathSolutionMethodSnapshot(method: method, visualMethods: visualMethods, selectionFailure: selectionFailure, methodClaimWarning: methodClaimWarning, reviewedExamples: reviewedExamples).validateSelectionFailure()
  }
}

/// New answers retain each selected version; old single-method snapshots remain readable.
struct MathSolutionMethodSnapshot: Codable {
  let method: MathTeachingMethod?
  let visualMethods: [MathTeachingMethod]
  let selectionFailure: String?
  let methodClaimWarning: String?
  let reviewedExamples: [MathReviewedExampleReference]

  init(method: MathTeachingMethod?, visualMethods: [MathTeachingMethod], selectionFailure: String? = nil, methodClaimWarning: String? = nil, reviewedExamples: [MathReviewedExampleReference] = []) {
    self.method = method
    self.visualMethods = visualMethods
    self.selectionFailure = selectionFailure
    self.methodClaimWarning = methodClaimWarning
    self.reviewedExamples = reviewedExamples
  }

  private enum CodingKeys: String, CodingKey { case method, visualMethods, selectionFailure, methodClaimWarning, reviewedExamples }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if values.contains(.visualMethods) || values.contains(.selectionFailure) || values.contains(.reviewedExamples) {
      method = try values.decodeIfPresent(MathTeachingMethod.self, forKey: .method)
      visualMethods = try values.decode([MathTeachingMethod].self, forKey: .visualMethods)
      selectionFailure = try values.decodeIfPresent(String.self, forKey: .selectionFailure)
    } else {
      method = try MathTeachingMethod(from: decoder)
      visualMethods = []
      selectionFailure = nil
    }
    methodClaimWarning = try values.decodeIfPresent(String.self, forKey: .methodClaimWarning)
    reviewedExamples = try values.decodeIfPresent([MathReviewedExampleReference].self, forKey: .reviewedExamples) ?? []
    try validateSelectionFailure()
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(method, forKey: .method)
    try values.encode(visualMethods, forKey: .visualMethods)
    try values.encodeIfPresent(selectionFailure, forKey: .selectionFailure)
    try values.encodeIfPresent(methodClaimWarning, forKey: .methodClaimWarning)
    if !reviewedExamples.isEmpty { try values.encode(reviewedExamples, forKey: .reviewedExamples) }
  }

  func validateSelectionFailure() throws {
    guard reviewedExamples.count <= 1, reviewedExamples.allSatisfy(\.isValid) else {
      throw MathQuestionStoreError.database("历史例题引用数量或审核范围无效")
    }
    if let warning = methodClaimWarning {
      guard !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        warning.count <= 512, warning.utf8.count <= 2048
      else { throw MathQuestionStoreError.database("方法声明提示无效") }
    }
    guard let failure = selectionFailure else { return }
    guard !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      failure.count <= 512, failure.utf8.count <= 2048, method == nil, visualMethods.isEmpty
    else { throw MathQuestionStoreError.database("自动方法前提复核记录无效，或同时保存了未通过的方法") }
  }

  func encoded() throws -> String? {
    try validateSelectionFailure()
    if !visualMethods.isEmpty || selectionFailure != nil || methodClaimWarning != nil || !reviewedExamples.isEmpty {
      return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
    return try method.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
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
  let grade: Int?
  let automaticTagStatus: String
  let automaticTagError: String

  init(
    id: String, title: String, createdAt: Date, imageWidth: Int, imageHeight: Int,
    ocrText: String, ocrStatus: String, grade: Int? = nil,
    automaticTagStatus: String = "unclassified", automaticTagError: String = ""
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.ocrText = ocrText
    self.ocrStatus = ocrStatus
    self.grade = grade
    self.automaticTagStatus = automaticTagStatus
    self.automaticTagError = automaticTagError
  }
}

/// Stable catalogue identity is separate from its editable display label and provenance.
struct MathQuestionTag: Codable, Sendable, Equatable, Hashable {
  let axis: String
  let tagID: String
  let catalogueVersion: String
  let label: String
  let origin: String
  let status: String

  init(
    axis: String, tagID: String, catalogueVersion: String, label: String,
    origin: String = "user", status: String = "confirmed"
  ) {
    self.axis = axis
    self.tagID = tagID
    self.catalogueVersion = catalogueVersion
    self.label = label
    self.origin = origin
    self.status = status
  }

  var key: String {
    [axis, tagID, catalogueVersion].map { "\($0.utf8.count):\($0)" }.joined()
  }
}

/// User-provided evidence remains distinct from AI answers and does not confirm them automatically.
struct MathReferenceAnswer: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let text: String
  let source: String
  let scope: String
  let imageAssetID: String?
  let createdAt: Date
}

/// Each user decision is retained; a solution's status only caches the latest decision.
struct MathSolutionReview: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let solutionID: String
  let status: String
  let scope: String
  let note: String
  let correction: String
  let referenceID: String?
  let createdAt: Date
}

/// A logical method can be edited or archived without changing earlier solution snapshots.
/// Human-declared teaching permissions are content of one immutable version, not AI approval.
struct MathTeachingPermissions: Codable, Sendable, Equatable {
  enum Equation: String, Codable, Sendable { case unknown, notRequired, required }
  enum Extension: String, Codable, Sendable { case unknown, none, explicitPermission }
  let minimumGrade: Int?
  let equationRequirement: Equation
  let extensionRequirement: Extension
  init(minimumGrade: Int?, equationRequirement: Equation, extensionRequirement: Extension) {
    self.minimumGrade = minimumGrade; self.equationRequirement = equationRequirement
    self.extensionRequirement = extensionRequirement
  }
  private enum CodingKeys: String, CodingKey { case minimumGrade, equationRequirement, extensionRequirement }
  private struct Field: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: Field.self)
    guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: ["minimumGrade", "equationRequirement", "extensionRequirement"]) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown teaching permission field"))
    }
    let values = try decoder.container(keyedBy: CodingKeys.self)
    minimumGrade = try values.decodeIfPresent(Int.self, forKey: .minimumGrade)
    equationRequirement = try values.decode(Equation.self, forKey: .equationRequirement)
    extensionRequirement = try values.decode(Extension.self, forKey: .extensionRequirement)
    guard isValid else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Teaching grade must be 1–6"))
    }
  }
  var isComplete: Bool { minimumGrade != nil && equationRequirement != .unknown && extensionRequirement != .unknown }
  var isValid: Bool { minimumGrade.map { (1...6).contains($0) } ?? true }
  var summary: String {
    "最低适用年级：\(minimumGrade.map { "\($0)年级" } ?? "未核对")；方程：\(equationRequirement == .unknown ? "未核对" : equationRequirement == .required ? "需要明确允许" : "不需要")；拓展许可：\(extensionRequirement == .unknown ? "未核对" : extensionRequirement == .explicitPermission ? "需要明确允许" : "不需要额外许可")"
  }
}

struct MathTeachingMethod: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let versionID: String
  let title: String
  let category: String
  let instructions: String
  let createdAt: Date
  let teachingPermissions: MathTeachingPermissions?

  init(id: String, versionID: String, title: String, category: String, instructions: String, createdAt: Date,
    teachingPermissions: MathTeachingPermissions? = nil) {
    self.id = id; self.versionID = versionID; self.title = title; self.category = category
    self.instructions = instructions; self.createdAt = createdAt; self.teachingPermissions = teachingPermissions
  }
}

/// A unique claim prevents cancelled or pre-restart requests from writing late results.
struct MathAutomaticTagAttempt: Sendable, Equatable {
  let questionID: String
  let token: String
}

struct MathAutomaticTagJob: Sendable, Equatable {
  let questionID: String
  let status: String
  let error: String
  let model: String
  let promptVersion: String
  let catalogueVersion: String
  let evidence: String
}
