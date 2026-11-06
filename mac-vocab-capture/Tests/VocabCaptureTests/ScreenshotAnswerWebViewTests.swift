import AppKit
import WebKit
import XCTest

@testable import VocabCapture

@MainActor
final class ScreenshotAnswerWebViewTests: XCTestCase {
  func testInstalledResourcesWorkWithoutAnySwiftPMBundleAndMissingResourcesAreSafe() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let installed = directory.appendingPathComponent("App.app/Contents/Resources/AnswerRenderer")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try Data("offline renderer".utf8).write(to: installed.appendingPathComponent("index.html"))
    let absent = directory.appendingPathComponent("missing-developer-bundle")
    XCTAssertEqual(ScreenshotAnswerWebView.findResourceRoot(installedRoot: installed,
      bundleDirectories: [absent]), installed)
    XCTAssertNil(ScreenshotAnswerWebView.findResourceRoot(installedRoot: absent, bundleDirectories: [absent]))
    let development = directory.appendingPathComponent("VocabCapture_VocabCapture.bundle/AnswerRenderer")
    try FileManager.default.createDirectory(at: development, withIntermediateDirectories: true)
    try Data("developer renderer".utf8).write(to: development.appendingPathComponent("index.html"))
    XCTAssertEqual(ScreenshotAnswerWebView.findResourceRoot(installedRoot: absent,
      bundleDirectories: [directory])?.path, development.path)
    XCTAssertEqual(ScreenshotAnswerWebView.findResourceRoot(installedRoot: installed,
      bundleDirectories: [directory]), installed)
  }

  private func loadedView() async throws -> ScreenshotAnswerWebView {
    _ = NSApplication.shared
    let view = ScreenshotAnswerWebView()
    view.frame = NSRect(x: 0, y: 0, width: 820, height: 760)
    var ready: Bool?
    view.onReady = { ready = $0 }
    for _ in 0..<200 {
      if let ready { XCTAssertTrue(ready, "Offline renderer must load all bundled assets"); return view }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Offline renderer did not load")
    return view
  }

  private func js(_ code: String, _ view: WKWebView) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
      view.evaluateJavaScript(code) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value) }
      }
    }
  }

  private func assertJS(_ code: String, _ view: WKWebView, _ expected: AnyHashable) async throws {
    let actual = try await js(code, view) as? AnyHashable
    XCTAssertEqual(actual, expected, code)
  }

  private func waitFor(_ expression: String, _ view: WKWebView) async throws {
    for _ in 0..<200 {
      if try await js(expression, view) as? Bool == true { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Renderer condition timed out: \(expression)")
  }

  func testOfflineMarkdownMermaidAndBothMathDelimitersRender() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "比较数量并画出关系", answer: #"""
      ## 解题过程
      **先算总数**，再比较。
      
      | 项目 | 数量 |
      | --- | --- |
      | 原数 | 8 |
      
      公式 \(a_1 + b_2 = 10\)，行内 $x^2$。
      
      \[\frac{72}{10-1}=8\]
      
      $$\sum_{i=1}^{3}i=6$$
      
      ```mermaid
      flowchart LR
        A[原数 8] --> B[乘 10 得 80]
        B --> C[相差 72]
      ```
      """# )], zoom: 1)
    try await waitFor("document.querySelectorAll('.diagram svg').length === 1", view)
    try await assertJS("document.querySelectorAll('h2').length", view, 1)
    try await assertJS("document.querySelectorAll('table').length", view, 1)
    try await assertJS("document.querySelectorAll('.katex').length", view, 4)
    try await assertJS("document.querySelectorAll('.katex-display').length", view, 2)
    try await assertJS("document.querySelectorAll('.diagram svg text').length > 0", view, true)
    if let snapshotPath = ProcessInfo.processInfo.environment["SCREENSHOT_RENDERER_SNAPSHOT"] {
      let configuration = WKSnapshotConfiguration()
      let image: NSImage = try await withCheckedThrowingContinuation { continuation in
        view.takeSnapshot(with: configuration) { image, error in
          if let image { continuation.resume(returning: image) }
          else { continuation.resume(throwing: error ?? NSError(domain: "snapshot", code: 1)) }
        }
      }
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: snapshotPath))
    }
  }

  func testUntrustedHTMLAndRemoteAssetsCannotExecuteOrLoad() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "<img src=x onerror=alert(1)>", answer: #"""
      <script>window.answerPwned=true</script>
      <img src="https://example.invalid/leak" onerror="window.answerPwned=true">
      <iframe src="https://example.invalid"></iframe>
      [外部链接](javascript:window.answerPwned=true)
      ![远程图片](https://example.invalid/secret)

      ```mermaid
      flowchart LR
        A --> B
        click A "https://example.invalid/secret"
      ```
      """# )], zoom: 1)
    try await waitFor("document.querySelector('.render-error') !== null", view)
    try await assertJS("Boolean(window.answerPwned)", view, false)
    try await assertJS("document.querySelectorAll('#transcript script, #transcript iframe, #transcript img, #transcript [href], #transcript [onerror]').length", view, 0)
    try await assertJS("document.querySelector('.question').textContent.includes('<img')", view, true)
  }

  func testIncompleteMathAndMermaidKeepReadableSourceAndLatestRenderWins() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "旧问题", answer: "```mermaid\nflowchart LR\nA --> B\n```")], zoom: 1)
    view.render(turns: [ScreenshotAnswerTurn(question: "新问题", answer: #"""
      最新回答：\(\frac{\)，以及代码 `\(literal\)`。
      ```mermaid
      this is not a diagram
      ```
      """# )], zoom: 1.4)
    try await waitFor("document.querySelector('.render-error') !== null", view)
    try await assertJS("document.querySelectorAll('.turn').length", view, 1)
    try await assertJS("document.querySelector('.question').textContent", view, "你：新问题")
    try await assertJS("document.querySelectorAll('.math-error').length", view, 1)
    try await assertJS("document.querySelector('.answer code').textContent", view, #"\(literal\)"#)
    try await assertJS("document.documentElement.style.fontSize", view, "23.8px")
    try await assertJS("document.querySelector('.diagram pre').textContent.includes('not a diagram')", view, true)
    view.render(turns: [], zoom: 1)
    try await waitFor("document.querySelectorAll('.turn').length === 0", view)
  }

  func testCurrencyAndLiteralCodeDoNotConsumeFollowingMath() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "格式边界", answer: #"""
      价格 $5，公式 $x$，另一价格 $10。

      ~~~text
      $literal$ 和 \(code\)
      ~~~

      ```mermaid
      flowchart LR
        A --> B
      """#)], zoom: 1)
    try await waitFor("document.querySelectorAll('pre').length === 2", view)
    try await assertJS("document.querySelectorAll('.katex').length", view, 1)
    try await assertJS("document.querySelectorAll('.diagram').length", view, 0)
    try await assertJS("document.querySelector('pre').textContent.includes('$literal$')", view, true)
    try await assertJS("document.body.textContent.includes('MATHPLACEHOLDER')", view, false)
    try await assertJS("document.querySelector('.answer').textContent.includes('$5')", view, true)
  }

  func testValidLinksRemainClickableButUnsafeSchemesAndImagesDoNotLoad() async throws {
    let view = try await loadedView()
    view.render(turns: [ScreenshotAnswerTurn(question: "链接", answer: "[官方文档](https://example.com/docs) [邮件](mailto:test@example.com) ![图片](https://example.com/image.png)")], zoom: 1)
    try await waitFor("document.querySelectorAll('.answer a').length === 2", view)
    try await assertJS("document.querySelectorAll('.answer a[href]').length", view, 1)
    try await assertJS("document.querySelector('.answer a[href]').getAttribute('href')", view, "https://example.com/docs")
    try await assertJS("document.querySelectorAll('.answer img').length", view, 0)
    try await assertJS("performance.getEntriesByType('resource').filter(x => x.name.startsWith('https:')).length", view, 0)
  }

  func testPendingContentRendersAfterLoadWithoutInterpolation() async throws {
    _ = NSApplication.shared
    let view = ScreenshotAnswerWebView()
    view.render(turns: [ScreenshotAnswerTurn(question: "Unicode 中文", answer: "Literal </script> ' \\\n\u{2028}末尾")], zoom: .nan)
    try await waitFor("document.querySelector('.answer') !== null", view)
    try await assertJS("document.querySelectorAll('.turn').length", view, 1)
    try await assertJS("document.documentElement.style.fontSize", view, "17px")
  }
}
