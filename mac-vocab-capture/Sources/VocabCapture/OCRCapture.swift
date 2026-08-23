import AppKit
import Vision

enum OCRCaptureError: LocalizedError {
  case noTextFound
  case screenRecordingPermissionRequired
  case screenCaptureFailed

  var errorDescription: String? {
    switch self {
    case .noTextFound: "没有识别到英文文字，请框选得更紧一些。"
    case .screenRecordingPermissionRequired: "需要“屏幕录制”权限，才能在不提供原文的 App 中自动识别选词所在句子。"
    case .screenCaptureFailed: "无法读取当前屏幕内容。"
    }
  }
}

enum ScreenContextCapture {
  /// A full-screen capture is intentionally taken only after the user invokes
  /// capture. Vision then extracts the sentence containing the selected term.
  static func capture() async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      throw OCRCaptureError.screenRecordingPermissionRequired
    }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-context-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-t", "png", fileURL.path]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      process.terminationHandler = { finished in
        finished.terminationStatus == 0
          ? continuation.resume()
          : continuation.resume(throwing: OCRCaptureError.screenCaptureFailed)
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
    guard let image = NSImage(contentsOf: fileURL),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw OCRCaptureError.screenCaptureFailed
    }
    return cgImage
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
            .joined(separator: "\n")
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
