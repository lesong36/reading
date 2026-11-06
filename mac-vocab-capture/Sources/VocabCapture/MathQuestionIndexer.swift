import AppKit
import ImageIO
import Vision

/// Indexing is independent of the English word-capture recognizer.
enum MathQuestionIndexer {
  static let languages = ["zh-Hans", "en-US"]

  @MainActor
  static func originalPNG(_ image: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  static func recognize(_ data: Data) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.recognitionLanguages = languages
          request.usesLanguageCorrection = true
          try VNImageRequestHandler(data: data).perform([request])
          let text =
            request.results?.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          guard !text.isEmpty else { throw OCRCaptureError.noTextFound }
          continuation.resume(returning: text)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
