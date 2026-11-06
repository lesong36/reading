import Darwin
import Foundation

/// Restores into a verified staging archive, then atomically exchanges whole directories.
/// The recovery archive stays outside the active library and is retained after success.
enum MathQuestionBackupRestore {
  static func replace(
    directory: URL, from backup: URL,
    close: () -> Void, activate: () throws -> Void
  ) throws -> URL {
    let manager = FileManager.default
    let current = directory.standardizedFileURL
    let source = backup.standardizedFileURL
    guard source != current,
      !source.path.hasPrefix(current.path + "/"),
      !current.path.hasPrefix(source.path + "/"),
      (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw MathQuestionStoreError.database("备份目录与当前题库必须相互独立")
    }
    let parent = current.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".math-restore-stage-\(UUID().uuidString)", isDirectory: true)
    let recovery = parent.appendingPathComponent("math-before-restore-\(UUID().uuidString)", isDirectory: true)
    // A broken or newer backup fails here without closing or altering the active library.
    try MathQuestionArchive.create(directory: source, to: staging)
    var installed = false
    var preserveStaging = false
    defer { if !preserveStaging { try? manager.removeItem(at: staging) } }
    close()
    try MathQuestionArchive.create(directory: current, to: recovery)
    try exchange(staging, current)
    installed = true
    do {
      try MathQuestionArchive.syncDirectory(parent)
      try activate()
      try MathQuestionArchive.syncDirectory(current)
    } catch {
      close()
      if installed {
        do {
          try exchange(staging, current)
          installed = false
          try MathQuestionArchive.syncDirectory(parent)
        } catch {
          // Both complete directory trees remain recoverable; do not discard either.
          preserveStaging = true
          throw MathQuestionStoreError.database("恢复回滚失败，原库保留于 \(staging.path)，恢复前快照位于 \(recovery.path)")
        }
      }
      throw error
    }
    return recovery
  }

  private static func exchange(_ first: URL, _ second: URL) throws {
    // RENAME_SWAP prevents a crash from leaving the library path temporarily absent.
    guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
      throw MathQuestionStoreError.database("无法原子切换题库目录（\(String(cString: strerror(errno)))）")
    }
  }
}
