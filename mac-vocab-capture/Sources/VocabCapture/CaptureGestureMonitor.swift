import AppKit
import MultitouchBridge

struct CaptureGesture {
  enum Direction { case left, right }
  struct Point { let id: Int; let x: Double; let y: Double }
  private var start: TimeInterval?
  private var origins: [Int: Point] = [:]
  private var peak = 0
  private var invalid = false
  private var pending: (Int, TimeInterval)?
  private var blockedUntil: TimeInterval = 0

  mutating func consume(_ points: [Point], timestamp: TimeInterval) -> Direction? {
    guard timestamp.isFinite else { return nil }
    guard timestamp >= blockedUntil else { return nil }
    if !points.isEmpty {
      if start == nil { start = timestamp; origins = [:]; peak = 0; invalid = false }
      peak = max(peak, points.count)
      for point in points {
        if let origin = origins[point.id] {
          if hypot(point.x - origin.x, point.y - origin.y) > 0.025 { invalid = true }
        } else { origins[point.id] = point }
      }
      if origins.count > peak { invalid = true }
      return nil
    }
    guard let began = start else { return nil }
    start = nil
    guard !invalid, (3...4).contains(peak), timestamp - began >= 0.02,
      timestamp - began <= 0.25 else { pending = nil; return nil }
    if let previous = pending, previous.0 == peak,
      began >= previous.1, timestamp - previous.1 <= 0.55 {
      pending = nil
      blockedUntil = timestamp + 0.6
      return peak == 3 ? .left : .right
    }
    pending = (peak, timestamp)
    return nil
  }
}

// Raw frames are copied while the C callback holds its lock; no borrowed pointer escapes.
final class CaptureGestureMonitor {
  private final class CallbackBox { weak var monitor: CaptureGestureMonitor? }
  private let callbackBox = CallbackBox()
  private var recognizers: [UInt64: CaptureGesture] = [:]
  private var active = true
  private let trigger: (CaptureGesture.Direction) -> Void
  private var reconnect: NSObjectProtocol?
  private var wake: NSObjectProtocol?
  private(set) var deviceCount = 0

  init(trigger: @escaping (CaptureGesture.Direction) -> Void) {
    self.trigger = trigger
    callbackBox.monitor = self
    start()
    reconnect = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in self?.restart() }
    wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main) { [weak self] _ in self?.restart() }
  }

  private func restart() { MTBStop(); recognizers = [:]; start() }
  private func start() {
    deviceCount = Int(MTBStart({ context, device, touches, count, timestamp, _ in
      guard let context, count >= 0, count <= 32, count == 0 || touches != nil else { return }
      let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
      let points = UnsafeBufferPointer(start: touches, count: Int(count)).filter {
        $0.state == 3 || $0.state == 4
      }.map { CaptureGesture.Point(id: Int($0.identifier), x: Double($0.x), y: Double($0.y)) }
      DispatchQueue.main.async { [weak box] in
        guard let monitor = box?.monitor, monitor.active else { return }
        var recognizer = monitor.recognizers[device] ?? CaptureGesture()
        let action = recognizer.consume(points, timestamp: timestamp)
        monitor.recognizers[device] = recognizer
        if let action { monitor.trigger(action) }
      }
    }, Unmanaged.passUnretained(callbackBox).toOpaque()))
  }

  deinit {
    active = false
    MTBStop()
    if let reconnect { NotificationCenter.default.removeObserver(reconnect) }
    if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
  }
}
