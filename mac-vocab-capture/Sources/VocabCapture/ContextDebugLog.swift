import AppKit
import Foundation

enum ContextDebugLog {
  private static let queue = DispatchQueue(label: "com.coty.vocab-capture.context-log")
  private static let maximumBytes = 120_000

  static var fileURL: URL {
    let directory = try! FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("VocabCapture", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("context-debug.log")
  }

  static func write(_ event: String, word: String? = nil, context: String? = nil) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let entry = [
      "[\(timestamp)] \(event)",
      word.map { "目标词: \($0)" },
      context.map { "上下文: \($0.replacingOccurrences(of: "\n", with: " "))" }
    ].compactMap { $0 }.joined(separator: "\n") + "\n\n"
    queue.async {
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
