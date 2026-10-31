import AppKit
import Vision

enum OCRCaptureError: LocalizedError {
  case noTextFound

  var errorDescription: String? {
    switch self {
    case .noTextFound: "没有识别到英文文字，请框选得更紧一些。"
    }
  }
}

enum OCRClient {
  struct Observation: Sendable, Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
  }

  struct Result: Sendable, Equatable {
    let text: String
    let observations: [Observation]
  }

  static func recognize(_ image: CGImage) async throws -> String {
    let result = try await recognizeWithLayout(image)
    return result.text
  }

  static func recognizeWithLayout(_ image: CGImage) async throws -> Result {
    try Task.checkCancellation()
    let result: Result = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(cgImage: image).perform([request])
          let observations = request.results?.compactMap { observation -> Observation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Observation(
              text: candidate.string, boundingBox: observation.boundingBox,
              confidence: candidate.confidence)
          } ?? []
          let text = observations.map(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { throw OCRCaptureError.noTextFound }
          continuation.resume(returning: Result(text: text, observations: observations))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    try Task.checkCancellation()
    return result
  }
}
