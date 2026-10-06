import AppKit
import Foundation

enum ContextDebugLog {
  private static let queue = DispatchQueue(label: "com.coty.vocab-capture.context-log")
  private static let maximumBytes = 120_000

  private static let modeLock = NSLock()
  private static var rawUntil: Date?
  static var isRawDiagnosticsEnabled: Bool {
    modeLock.lock(); defer { modeLock.unlock() }
    return rawUntil.map { $0 > Date() } ?? false
  }
  static func enableRawDiagnostics(for duration: TimeInterval = 600) {
    let duration = min(max(duration, 0), 600)
    let deadline = Date().addingTimeInterval(duration)
    modeLock.lock(); rawUntil = deadline; modeLock.unlock()
    queue.asyncAfter(deadline: .now() + duration) {
      modeLock.lock()
      let expires = rawUntil == deadline
      if expires { rawUntil = nil }
      modeLock.unlock()
      if expires { try? FileManager.default.removeItem(at: fileURL) }
    }
  }
  static func disableRawDiagnostics() {
    modeLock.lock(); rawUntil = nil; modeLock.unlock()
    clear()
  }
  static func clear() { queue.sync { try? FileManager.default.removeItem(at: fileURL) } }
  static func formatted(_ event: String, word: String?, context: String?, includeRaw: Bool) -> String {
    // Events are controlled metadata. Never interpolate selected text into the event argument.
    let details = includeRaw
      ? [word.map { "目标词: \($0)" }, context.map { "上下文: \($0.replacingOccurrences(of: "\n", with: " "))" }]
      : [word.map { "目标词长度: \($0.count)" }, context.map { "上下文长度: \($0.count)" }]
    return ([event] + details.compactMap { $0 }).joined(separator: "\n")
  }

  static var fileURL: URL {
    let injectedDirectory = ProcessInfo.processInfo.environment["VOCAB_CAPTURE_DIAGNOSTICS_DIR"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let directory = injectedDirectory ?? (try? FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ))?.appendingPathComponent("VocabCapture", isDirectory: true)
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("VocabCapture", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("context-debug.log")
  }

  static func write(_ event: String, word: String? = nil, context: String? = nil) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    queue.async {
      // Determine the mode on the writer queue: queued raw text cannot outlive
      // expiry or reappear after the user has cleared diagnostics.
      let entry = "[\(timestamp)] " + formatted(event, word: word, context: context, includeRaw: isRawDiagnosticsEnabled) + "\n\n"
      let url = fileURL
      if let existing = try? Data(contentsOf: url), existing.count > maximumBytes {
        try? existing.suffix(maximumBytes / 2).write(to: url, options: .atomic)
      }
      guard let data = entry.data(using: .utf8) else { return }
      if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: url, options: .atomic)
      }
    }
  }

  static func open() {
    queue.sync {
      let url = fileURL
      if !FileManager.default.fileExists(atPath: url.path) {
        try? "尚未产生取词记录。\n".data(using: .utf8)?.write(to: url, options: .atomic)
      }
    }
    NSWorkspace.shared.open(fileURL)
  }
}
