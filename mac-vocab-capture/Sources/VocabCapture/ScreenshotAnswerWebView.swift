import AppKit
import WebKit

struct ScreenshotAnswerTurn: Codable {
  var question: String
  var answer: String
  var diagramPNGs: [String] = []
  var note: String? = nil
}

/// An offline-only renderer. The native transcript remains available if loading fails.
@MainActor
final class ScreenshotAnswerWebView: WKWebView, WKNavigationDelegate {
  private static let sharedProcessPool = WKProcessPool()
  var onReady: ((Bool) -> Void)?
  private var rendererLoaded = false
  private var pendingTurns: [ScreenshotAnswerTurn] = []
  private var pendingZoom: CGFloat = 1
  private var pendingFocus = false
  private var resourceRoot: URL?

  init() {
    let configuration = WKWebViewConfiguration()
    configuration.processPool = Self.sharedProcessPool
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    super.init(frame: .zero, configuration: configuration)
    navigationDelegate = self
    setAccessibilityLabel("截图问答记录，支持 Markdown、流程图和数学公式")
    // Never touch Bundle.module here: SwiftPM's generated accessor fatally traps
    // when the developer resource bundle is absent from a packaged application.
    var directories = [Bundle.main.resourceURL, Bundle(for: ScreenshotAnswerWebView.self).resourceURL,
      Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
    #if DEBUG
    if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
      ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
      directories.insert(URL(fileURLWithPath: path), at: 0)
    }
    #endif
    let root = Self.findResourceRoot(
      installedRoot: Bundle.main.resourceURL?.appendingPathComponent("AnswerRenderer"),
      bundleDirectories: directories)
    guard let root,
      FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
    else { return }
    resourceRoot = root
    loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
  }

  static func findResourceRoot(installedRoot: URL?, bundleDirectories: [URL]) -> URL? {
    func containsRenderer(_ url: URL) -> Bool {
      FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path)
    }
    if let installedRoot, containsRenderer(installedRoot) { return installedRoot }
    for directory in bundleDirectories {
      let bundle = directory.appendingPathComponent("VocabCapture_VocabCapture.bundle", isDirectory: true)
      // SwiftPM bundles use Contents/Resources on macOS, while some build
      // layouts put copied resources directly inside the bundle directory.
      for root in [bundle.appendingPathComponent("AnswerRenderer"),
        bundle.appendingPathComponent("Contents/Resources/AnswerRenderer")] {
        if containsRenderer(root) { return root }
      }
    }
    return nil // Missing resources leave the existing native text transcript usable.
  }

  required init?(coder: NSCoder) { nil }

  func render(turns: [ScreenshotAnswerTurn], zoom: CGFloat, focusLatestDiagram: Bool = false) {
    pendingTurns = turns
    pendingZoom = min(2.5, max(0.6, zoom.isFinite ? zoom : 1))
    pendingFocus = focusLatestDiagram
    if rendererLoaded { submitPendingRender() }
  }

  private func submitPendingRender() {
    guard let data = try? JSONEncoder().encode(pendingTurns),
      let turns = try? JSONSerialization.jsonObject(with: data)
    else { return }
    callAsyncJavaScript("window.answerRenderer.render(turns, zoom, focus)",
      arguments: ["turns": turns, "zoom": Double(pendingZoom), "focus": pendingFocus],
      in: nil, in: .page) { [weak self] result in
        if case .failure = result { self?.onReady?(false) }
      }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    evaluateJavaScript("Boolean(window.answerRenderer && window.answerRenderer.ready)") { [weak self] value, _ in
      guard let self else { return }
      self.rendererLoaded = value as? Bool == true
      self.onReady?(self.rendererLoaded)
      if self.rendererLoaded { self.submitPendingRender() }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    rendererLoaded = false
    onReady?(false)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    rendererLoaded = false
    onReady?(false)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    rendererLoaded = false
    onReady?(false)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
      return
    }
    guard navigationAction.navigationType == .other,
      let url = navigationAction.request.url, url.isFileURL,
      let root = resourceRoot,
      url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    else { decisionHandler(.cancel); return }
    decisionHandler(.allow)
  }
}
