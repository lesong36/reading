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
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest { request, error in
          if let error { continuation.resume(throwing: error); return }
          let text = (request.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          text.isEmpty ? continuation.resume(throwing: OCRCaptureError.noTextFound) : continuation.resume(returning: text)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(cgImage: image).perform([request])
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
