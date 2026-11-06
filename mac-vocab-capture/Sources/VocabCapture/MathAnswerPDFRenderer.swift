import AppKit
import WebKit

/// Uses the same sanitized, offline renderer as the answer window. Each slice
/// remains vector PDF; no generated bitmap substitutes for mathematical text.
@MainActor
enum MathAnswerPDFRenderer {
  static func pages(question: String, answer: String, note: String, size: CGSize) async throws
    -> [Data]
  {
    let view = ScreenshotAnswerWebView()
    view.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    defer {
      view.stopLoading()
      window.contentView = nil
      window.close()
    }
    window.isReleasedWhenClosed = false
    var loaded: Bool?
    view.onReady = { loaded = $0 }
    for _ in 0..<300 {
      try Task.checkCancellation()
      if loaded != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard loaded == true else { throw MathQuestionPDFExportError.renderingFailed }
    let data = try JSONEncoder().encode([
      ScreenshotAnswerTurn(question: question, answer: answer, note: note.isEmpty ? nil : note)
    ])
    let turns = try JSONSerialization.jsonObject(with: data)
    let layout: Any = try await withCheckedThrowingContinuation { continuation in
      view.callAsyncJavaScript(
        """
        const style = document.createElement('style');
        style.textContent = `:root { color-scheme: light; color: #222; background: white; }
          body { padding: 0; } .table-scroll, .katex-display, .diagram { overflow: visible; }
          .diagram svg { min-width: 0; max-width: 100%; }
          table { width: 100%; min-width: 0; table-layout: fixed; }
          th,td { padding: 4px 6px; overflow-wrap: anywhere; }
          .question { font-size: 10px; margin-bottom: 16px; }`;
        document.head.append(style);
        await Promise.race([
          window.answerRenderer.render(turns, 11 / 17, false),
          new Promise((_, reject) => setTimeout(() => reject(new Error('PDF rendering timed out')), 15000))
        ]);
        window.scrollTo(0, 0);
        if (document.documentElement.scrollWidth > width + 1) throw new Error('PDF content too wide');
        const boxes = [];
        const add = r => { if (r.height > 0 && r.width > 0) boxes.push([r.top, r.bottom]); };
        document.querySelectorAll('.katex-display, table, tr, blockquote, .diagram, .checked-diagram').forEach(
          node => add(node.getBoundingClientRect()));
        document.querySelectorAll('table').forEach(table => {
          const block = table.closest('.table-scroll') || table;
          const caption = block.previousElementSibling;
          if (!caption) return;
          const text = caption.textContent.trim();
          const isHeading = /^H[1-6]$/.test(caption.tagName);
          const startsWithLabel = caption.firstElementChild?.tagName === 'STRONG'
            && caption.firstChild === caption.firstElementChild;
          if (text.length > 120 || !(isHeading || (caption.tagName === 'P'
            && (/[:：]$/.test(text) || startsWithLabel)))) return;
          const start = caption.getBoundingClientRect(), end = table.getBoundingClientRect();
          boxes.push([start.top, end.bottom]);
        });
        const walker = document.createTreeWalker(document.getElementById('transcript'), NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (node.parentElement.closest('.katex-mathml')) continue;
          const range = document.createRange(); range.selectNodeContents(node);
          Array.from(range.getClientRects()).forEach(add);
        }
        return {height: Math.max(document.body.scrollHeight,
          document.getElementById('transcript').getBoundingClientRect().bottom), boxes};
        """,
        arguments: ["turns": turns, "width": Double(size.width)], in: nil, in: .page
      ) { result in
        continuation.resume(with: result)
      }
    }
    guard let layout = layout as? [String: Any], let height = layout["height"] as? Double,
      height.isFinite, height > 0, height <= 1_000_000,
      let boxes = layout["boxes"] as? [[Double]]
    else { throw MathQuestionPDFExportError.renderingFailed }
    var result: [Data] = []
    var top = 0.0
    while top < height {
      try Task.checkCancellation()
      var end = min(height, top + size.height)
      // Keep a page-sized table together, as well as formulas and text lines.
      // Oversize blocks may span pages, but their individual text lines still fit.
      for _ in 0..<boxes.count + 1 {
        let crossing = boxes.filter {
          $0.count == 2 && $0[0] < end - 0.1 && $0[1] > end + 0.1
            && $0[0] > top + 1 && $0[1] - $0[0] <= size.height
        }
        guard let boundary = crossing.map({ $0[0] }).min() else { break }
        end = boundary
      }
      guard end > top, result.count < 2000 else {
        throw MathQuestionPDFExportError.renderingFailed
      }
      let config = WKPDFConfiguration()
      config.rect = CGRect(x: 0, y: top, width: size.width, height: end - top)
      result.append(try await view.pdf(configuration: config))
      top = end
    }
    return result
  }
}
