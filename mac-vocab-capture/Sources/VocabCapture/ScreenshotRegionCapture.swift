import ApplicationServices
import Foundation
import ImageIO

struct ScreenshotProcessResult {
  let status: Int32
  let diagnostic: String
}

enum ScreenshotRegionError: LocalizedError, Equatable {
  case permissionDenied, launchFailed, captureFailed(Int32), invalidImage
  var errorDescription: String? {
    switch self {
    case .permissionDenied: return "未获得屏幕录制权限。请在系统设置 → 隐私与安全性 → 屏幕录制中允许拾词助手，再重试。"
    case .launchFailed: return "无法启动系统截图工具，请重试。"
    case .captureFailed(let status): return "系统截图未成功（退出码 \(status)），请重试。"
    case .invalidImage: return "系统截图未生成有效图片，请重试。"
    }
  }
}

enum ScreenshotRegionOutcome { case captured, cancelled, failed(ScreenshotRegionError) }

/// Cancel is a specific successful user decision, not a catch-all for process failures.
@MainActor
final class ScreenshotRegionCapture {
  typealias Runner = (URL, @escaping (Result<ScreenshotProcessResult, Error>) -> Void) -> Void
  private let permission: () -> Bool
  private let runner: Runner
  private(set) var isRunning = false

  init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }, runner: Runner? = nil) {
    self.permission = permission
    self.runner = runner ?? Self.runSystemCapture
  }

  static func classify(_ result: ScreenshotProcessResult, hasImage: Bool, outputExists: Bool) -> ScreenshotRegionOutcome {
    if result.status == 0 {
      if hasImage { return .captured }
      // Current macOS screencapture can exit 0 on Escape without creating a file.
      // An existing but unreadable image, or a diagnostic, remains a real failure.
      if !outputExists && result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .cancelled
      }
      return .failed(.invalidImage)
    }
    // Older screencapture versions report Escape as status 1. Any actual
    // diagnostic or another exit status remains a visible process failure.
    if result.status == 1 && result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .cancelled }
    return .failed(.captureFailed(result.status))
  }

  func capture(_ completion: @escaping (Result<CGImage?, ScreenshotRegionError>) -> Void) {
    guard !isRunning else { return }
    guard permission() else { completion(.failure(.permissionDenied)); return }
    isRunning = true
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ocr-\(UUID().uuidString).png")
    runner(url) { [weak self] result in
      defer { try? FileManager.default.removeItem(at: url) }
      self?.isRunning = false
      switch result {
      case .failure: completion(.failure(.launchFailed))
      case .success(let result):
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        // OCR runs after this callback returns and the temporary file is removed.
        // Decode pixels now; ImageIO otherwise defers decoding until rendering.
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
        switch Self.classify(result, hasImage: image != nil, outputExists: FileManager.default.fileExists(atPath: url.path)) {
        case .captured: completion(.success(image))
        case .cancelled: completion(.success(nil))
        case .failed(let error): completion(.failure(error))
        }
      }
    }
  }

  private static func runSystemCapture(url: URL, completion: @escaping (Result<ScreenshotProcessResult, Error>) -> Void) {
    let process = Process()
    let diagnostic = BoundedScreenshotDiagnostic()
    let pipe = Pipe()
    process.standardError = pipe
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-o", "-t", "png", url.path]
    pipe.fileHandleForReading.readabilityHandler = { handle in diagnostic.append(handle.availableData) }
    process.terminationHandler = { finished in
      pipe.fileHandleForReading.readabilityHandler = nil
      diagnostic.append(pipe.fileHandleForReading.readDataToEndOfFile())
      DispatchQueue.main.async {
        completion(.success(ScreenshotProcessResult(status: finished.terminationStatus, diagnostic: diagnostic.text)))
      }
    }
    do { try process.run() }
    catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      completion(.failure(error))
    }
  }
}

private final class BoundedScreenshotDiagnostic: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ chunk: Data) {
    lock.lock(); defer { lock.unlock() }
    data.append(chunk.prefix(max(0, 64 * 1_024 - data.count)))
  }
  var text: String {
    lock.lock(); defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}
