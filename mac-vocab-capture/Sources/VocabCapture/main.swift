import AppKit

MainActor.assumeIsolated {
  let application = NSApplication.shared
  let delegate: any NSApplicationDelegate
  if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--isolated-math-review" {
    guard let review = try? MathIsolatedReview.makeDelegate(path: CommandLine.arguments[2]) else { exit(64) }
    delegate = review
  } else if CommandLine.arguments.contains("--isolated-math-review") {
    exit(64)
  } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--evaluate-math-routing" {
    delegate = MathRoutingEvaluationDelegate(requestPath: CommandLine.arguments[2])
  } else if CommandLine.arguments.contains("--evaluate-math-routing") {
    // Malformed diagnostics never fall through into normal app initialization.
    exit(64)
  } else {
    delegate = AppDelegate()
  }
  application.delegate = delegate
  application.setActivationPolicy(.accessory)
  // NSApplication holds its delegate weakly; retain it throughout the event loop.
  withExtendedLifetime(delegate) { application.run() }
}
