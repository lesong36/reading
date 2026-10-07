import AppKit

/// Screenshot results must be visible before accessory-app activation completes.
@MainActor
class ScreenshotPanel: NSPanel {
  private var observesDeactivation = false

  func bringToFront() {
    if !observesDeactivation {
      NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
        name: NSApplication.didResignActiveNotification, object: NSApp)
      observesDeactivation = true
    }
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    if isMiniaturized { deminiaturize(nil) }
    level = .floating
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    // Activation is asynchronous; ordinary ordering can leave us behind the source app.
    orderFrontRegardless()
  }

  override func resignKey() {
    super.resignKey()
    // Give other windows their normal stacking order once the user leaves this panel.
    level = .normal
  }

  override func orderOut(_ sender: Any?) {
    super.orderOut(sender)
    level = .normal
  }

  @objc private func applicationDeactivated(_ notification: Notification) {
    level = .normal
  }
}
