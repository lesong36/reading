import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenContentMonitor {
  private let region: ScreenCaptureRegion
  private let original: CGImage
  private let onChange: () -> Void
  private var task: Task<Void, Never>?

  init(region: ScreenCaptureRegion, original: CGImage, onChange: @escaping () -> Void) {
    self.region = region
    self.original = original
    self.onChange = onChange
  }

  func start() {
    guard task == nil, #available(macOS 14.0, *), let baseline = Self.signature(original) else { return }
    task = Task { [weak self] in
      guard let self else { return }
      var failures = 0
      while !Task.isCancelled {
        do {
          let current = try await self.capture()
          guard !Task.isCancelled else { return }
          guard let signature = Self.signature(current) else { throw CocoaError(.fileReadCorruptFile) }
          failures = 0
          if Self.changed(baseline, signature) {
            self.onChange()
            return
          }
        } catch {
          guard !Task.isCancelled else { return }
          failures += 1
          if failures >= 3 { self.onChange(); return }
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
    }
  }

  func stop() { task?.cancel(); task = nil }

  @available(macOS 14.0, *)
  private func capture() async throws -> CGImage {
    guard let displayID = ScreenshotRegionCapture.displayID(for: region.screenFrame) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = ScreenshotRegionCapture.sourceRect(for: region)
    configuration.width = original.width
    configuration.height = original.height
    configuration.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
  }

  static func signature(_ image: CGImage) -> [UInt8]? {
    let width = 128, height = 128
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
  }

  static func changed(_ original: [UInt8], _ current: [UInt8]) -> Bool {
    guard original.count == current.count, !original.isEmpty else { return true }
    let changed = zip(original, current).filter { abs(Int($0) - Int($1)) > 24 }.count
    return Double(changed) / Double(original.count) > 0.04
  }
}
