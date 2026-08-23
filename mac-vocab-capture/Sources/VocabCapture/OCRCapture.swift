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
  /// Captures only the area around the pointer. This excludes unrelated panes
  /// that often repeat the same word elsewhere on a large desktop window.
  static func capture(around pointer: CGPoint) async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      throw OCRCaptureError.screenRecordingPermissionRequired
    }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-context-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    guard let screen else { throw OCRCaptureError.screenCaptureFailed }
    let size = CGSize(width: min(1_080, screen.frame.width), height: min(720, screen.frame.height))
    let localPointer = CGPoint(x: pointer.x - screen.frame.minX, y: screen.frame.maxY - pointer.y)
    let origin = CGPoint(
      x: min(max(0, localPointer.x - size.width / 2), max(0, screen.frame.width - size.width)),
      y: min(max(0, localPointer.y - size.height / 2), max(0, screen.frame.height - size.height))
    )
    let rectangle = "\(Int(origin.x)),\(Int(origin.y)),\(Int(size.width)),\(Int(size.height))"
    process.arguments = ["-x", "-R", rectangle, "-t", "png", fileURL.path]
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
