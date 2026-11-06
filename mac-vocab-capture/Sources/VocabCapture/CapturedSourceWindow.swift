import AppKit

/// A screen-space OCR layer is only valid while its original window stays put.
struct CapturedSourceWindow: Equatable, Sendable {
  let id: CGWindowID
  let ownerPID: pid_t
  let bounds: CGRect

  static func snapshot(at region: CGRect) -> CapturedSourceWindow? {
    // Quartz uses a top-left origin, unlike AppKit screen coordinates.
    let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
    let point = CGPoint(x: region.midX, y: desktopTop - region.midY)
    return visibleWindows().first { $0.bounds.contains(point) }
  }

  var isCurrent: Bool {
    Self.visibleWindows().contains { $0.id == id && $0.ownerPID == ownerPID && $0.bounds == bounds }
  }

  private static func visibleWindows() -> [CapturedSourceWindow] {
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return rows.compactMap { row in
      guard let id = row[kCGWindowNumber as String] as? UInt32,
        let pid = row[kCGWindowOwnerPID as String] as? Int32,
        pid != ProcessInfo.processInfo.processIdentifier,
        let layer = row[kCGWindowLayer as String] as? Int, layer == 0,
        let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary)
      else { return nil }
      return CapturedSourceWindow(id: id, ownerPID: pid, bounds: bounds)
    }
  }
}
