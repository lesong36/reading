import AppKit

MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate = AppDelegate()
  application.delegate = delegate
  application.setActivationPolicy(.accessory)
  // NSApplication holds its delegate weakly; retain it throughout the event loop.
  withExtendedLifetime(delegate) { application.run() }
}
