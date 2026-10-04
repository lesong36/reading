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
  static func recognize(_ image: CGImage) async throws -> String {
    try Task.checkCancellation()
    let text: String = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(cgImage: image).perform([request])
          let text =
            request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          guard !text.isEmpty else { throw OCRCaptureError.noTextFound }
          continuation.resume(returning: text)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    try Task.checkCancellation()
    return text
  }
}
