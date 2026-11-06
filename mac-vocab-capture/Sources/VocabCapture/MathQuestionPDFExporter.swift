import CoreGraphics
import CoreText
import Foundation
import ImageIO

struct MathQuestionPDFOptions: Sendable {
  var includeSolutions: Bool = false
}

enum MathQuestionPDFExportError: LocalizedError {
  case noQuestions, invalidImage, renderingFailed

  var errorDescription: String? {
    switch self {
    case .noQuestions: return "请先选择要导出的题目。"
    case .invalidImage: return "题目原图无法读取，未导出 PDF。"
    case .renderingFailed: return "PDF 排版失败，未覆盖已有文件。"
    }
  }
}

/// The question itself always comes from the archived photo, never reconstructed OCR text.
enum MathQuestionPDFExporter {
  private struct Item: Sendable {
    let record: MathQuestionRecord
    let imageData: Data
    let solutions: [MathQuestionSolution]
    var answerPages: [[Data]] = []
  }

  static func export(
    records: [MathQuestionRecord], store: MathQuestionStore, to destination: URL,
    options: MathQuestionPDFOptions = .init()
  ) async throws -> Int {
    guard !records.isEmpty else { throw MathQuestionPDFExportError.noQuestions }
    // Refresh visibility and titles instead of exporting stale/deleted list selections.
    let current = Dictionary(uniqueKeysWithValues: try await store.list().map { ($0.id, $0) })
    var seen = Set<String>()
    var items: [Item] = []
    for selection in records where seen.insert(selection.id).inserted {
      try Task.checkCancellation()
      guard let record = current[selection.id] else { throw MathQuestionStoreError.notFound }
      let imageData = try await store.originalImage(questionID: record.id)
      let solutions =
        options.includeSolutions ? try await store.solutions(questionID: record.id) : []
      items.append(Item(record: record, imageData: imageData, solutions: solutions))
    }
    for index in items.indices {
      for (answerIndex, solution) in items[index].solutions.enumerated() {
        try Task.checkCancellation()
        let method =
          (solution.method.map { "\n参考方法建议（未确认采用）：\($0.title)" } ?? "")
          + (solution.visualMethods.isEmpty
            ? "" : "\n数形结合：" + solution.visualMethods.map(\.title).joined(separator: "、"))
        let header =
          "AI 回答 \(answerIndex + 1) · \(verificationLabel(solution))\n模型：\(solution.model)\(method)\n\n提问：\(solution.question)"
          + (solution.arithmeticNotice.map { "\n\n\($0)" } ?? "")
        let note =
          (solution.methodClaimWarning.map { "方法声明提示：\($0)\n" } ?? "")
          + (solution.selectionFailure.map { "自动选法记录（未套用方法）：\($0)\n" } ?? "")
          + (solution.diagramFailure.map { "图解未生成：\($0)" } ?? "")
        let pages = try await MathAnswerPDFRenderer.pages(
          question: header, answer: solution.answer, note: note,
          size: CGSize(width: bodyWidth, height: bodyTop - bodyBottom))
        items[index].answerPages.append(pages)
      }
    }
    // CoreGraphics/CoreText avoid main-thread AppKit drawing and preserve image pixels.
    let renderer = Task.detached(priority: .userInitiated) { try render(items: items) }
    let result = try await withTaskCancellationHandler {
      try await renderer.value
    } onCancel: {
      renderer.cancel()
    }
    try Task.checkCancellation()
    try result.data.write(to: destination, options: .atomic)
    return result.pages
  }

  private static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
  private static let margin: CGFloat = 44
  private static let bodyTop: CGFloat = 738
  private static let bodyBottom: CGFloat = 58
  private static let bodyWidth = page.width - margin * 2

  private static func render(items: [Item]) throws -> (data: Data, pages: Int) {
    let bytes = NSMutableData()
    guard let consumer = CGDataConsumer(data: bytes),
      let context = CGContext(
        consumer: consumer, mediaBox: nil,
        [
          kCGPDFContextTitle as String: "数学题库",
          kCGPDFContextCreator as String: "拾词助手",
        ] as CFDictionary)
    else { throw MathQuestionPDFExportError.renderingFailed }
    var pageNumber = 0
    for (index, item) in items.enumerated() {
      try Task.checkCancellation()
      let image = try originalImage(item.imageData)
      let fullWidthScale = bodyWidth / CGFloat(image.width)
      let bodyHeight = bodyTop - bodyBottom
      // A page scan just over the available height should not leave only its
      // footer on a continuation page. Limit this reduction to about 11% so
      // genuinely tall screenshots retain the full-width slicing behavior.
      let nearPage = CGFloat(image.height) * fullWidthScale <= bodyHeight * 1.12
      let scale = nearPage ? min(fullWidthScale, bodyHeight / CGFloat(image.height)) : fullWidthScale
      // Slice by source pixel rows at the full-width scale; fitting a tall photo onto one
      // sheet would make its text microscopic. Every source row appears exactly once.
      let rowsPerPage = nearPage ? image.height : max(1, Int(floor(bodyHeight / scale)))
      var row = 0
      while row < image.height {
        try Task.checkCancellation()
        let rows = min(rowsPerPage, image.height - row)
        guard let slice = image.cropping(to: CGRect(x: 0, y: row, width: image.width, height: rows))
        else { throw MathQuestionPDFExportError.invalidImage }
        pageNumber += 1
        beginPage(
          context, number: pageNumber, heading: "题目 \(index + 1)", title: item.record.title,
          continuation: row > 0)
        let height = CGFloat(rows) * scale
        context.interpolationQuality = .high
        context.draw(
          slice, in: CGRect(x: margin + (bodyWidth - CGFloat(image.width) * scale) / 2,
            y: bodyTop - height, width: CGFloat(image.width) * scale, height: height))
        if row + rows == image.height && height < bodyTop - bodyBottom - 115 {
          drawText(
            "作答区", in: CGRect(x: margin, y: bodyTop - height - 40, width: bodyWidth, height: 18),
            context: context, size: 10, gray: 0.5)
          context.setStrokeColor(CGColor(gray: 0.88, alpha: 1))
          context.setLineWidth(0.5)
          var y = bodyTop - height - 62
          while y > bodyBottom {
            context.move(to: CGPoint(x: margin, y: y))
            context.addLine(to: CGPoint(x: page.width - margin, y: y))
            context.strokePath()
            y -= 26
          }
        }
        context.endPDFPage()
        row += rows
      }
    }
    // Keep practice sheets free of answers, even when an answer appendix is requested.
    for (index, item) in items.enumerated() where !item.solutions.isEmpty {
      for (answerIndex, solution) in item.solutions.enumerated() {
        try Task.checkCancellation()
        let status = verificationLabel(solution)
        for (sliceIndex, data) in item.answerPages[answerIndex].enumerated() {
          try Task.checkCancellation()
          guard let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider), let answerPage = document.page(at: 1)
          else { throw MathQuestionPDFExportError.renderingFailed }
          pageNumber += 1
          beginPage(
            context, number: pageNumber, heading: "答案附录 · 题目 \(index + 1)",
            title: item.record.title, continuation: sliceIndex > 0)
          let bounds = answerPage.getBoxRect(.mediaBox)
          context.saveGState()
          // WebKit may paint table borders beyond a requested PDF slice.
          // Keep that overflow out of the appendix header and footer.
          context.clip(
            to: CGRect(
              x: margin, y: bodyTop - bounds.height,
              width: bodyWidth, height: bounds.height))
          context.translateBy(x: margin, y: bodyTop - bounds.height)
          context.drawPDFPage(answerPage)
          context.restoreGState()
          context.endPDFPage()
        }
        for (diagramIndex, diagram) in solution.diagrams.enumerated() {
          try Task.checkCancellation()
          // Legacy snapshots may be semantically valid but impossible to lay out. Keep
          // their question and answer pages, and report only that diagram's failure.
          let natural: CGSize
          let scale: CGFloat
          do {
            try MathDiagramAnswer.validateRendering(diagram)
            natural = try MathDiagramRenderer.size(diagram, width: bodyWidth)
            scale = min(1, (bodyTop - bodyBottom - 35) / natural.height)
          } catch let error as MathDiagram.ValidationError {
            pageNumber += 1
            beginPage(
              context, number: pageNumber,
              heading: "答案图解 · 题目 \(index + 1) · 图 \(diagramIndex + 1)",
              title: item.record.title, continuation: false)
            drawText(
              "图解未显示：\(error.message)",
              in: CGRect(x: margin, y: bodyTop - 30, width: bodyWidth, height: 24),
              context: context, size: 11)
            context.endPDFPage()
            continue
          }
          pageNumber += 1
          beginPage(
            context, number: pageNumber,
            heading: "答案图解 · 题目 \(index + 1) · 图 \(diagramIndex + 1)",
            title: item.record.title, continuation: false)
          let size = CGSize(width: natural.width * scale, height: natural.height * scale)
          do {
            try MathDiagramRenderer.draw(
              diagram, in: context,
              rect: CGRect(
                x: margin + (bodyWidth - size.width) / 2,
                y: bodyTop - size.height, width: size.width, height: size.height),
              layoutWidth: bodyWidth)
          } catch let error as MathDiagram.ValidationError {
            drawText(
              "图解未显示：\(error.message)",
              in: CGRect(x: margin, y: bodyTop - 30, width: bodyWidth, height: 24),
              context: context, size: 11)
            context.endPDFPage()
            continue
          }
          drawText(
            "图解关系已检查 · \(status)",
            in: CGRect(x: margin, y: bodyTop - size.height - 25, width: bodyWidth, height: 18),
            context: context, size: 10, gray: 0.45)
          context.endPDFPage()
        }
      }
    }
    context.closePDF()
    guard bytes.length > 0, pageNumber > 0 else { throw MathQuestionPDFExportError.renderingFailed }
    return (bytes as Data, pageNumber)
  }

  private static func verificationLabel(_ solution: MathQuestionSolution) -> String {
    switch solution.verificationStatus {
    case "confirmed": return "用户已确认（核验范围请参阅题库）"
    case "rejected": return "用户标记有误"
    default: return "尚未核验"
    }
  }

  private static func originalImage(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw MathQuestionPDFExportError.invalidImage
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber,
      orientation.intValue != 1
    {
      // Respect camera rotation without downsampling the archived pixels.
      let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
      let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
      guard
        let transformed = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
          ] as CFDictionary)
      else { throw MathQuestionPDFExportError.invalidImage }
      return transformed
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw MathQuestionPDFExportError.invalidImage
    }
    return image
  }

  private static func beginPage(
    _ context: CGContext, number: Int, heading: String, title: String, continuation: Bool
  ) {
    context.beginPDFPage(
      [kCGPDFContextMediaBox as String: NSData(bytes: [page], length: MemoryLayout<CGRect>.size)]
        as CFDictionary)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(page)
    drawText(
      "数学题库", in: CGRect(x: margin, y: 800, width: bodyWidth, height: 17),
      context: context, size: 10, gray: 0.45)
    drawText(
      heading + (continuation ? "（续页）" : ""),
      in: CGRect(x: margin, y: 774, width: bodyWidth, height: 23), context: context, size: 16)
    drawText(
      title, in: CGRect(x: margin, y: 752, width: bodyWidth, height: 17),
      context: context, size: 10, gray: 0.35)
    context.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
    context.setLineWidth(0.5)
    context.move(to: CGPoint(x: margin, y: 745))
    context.addLine(to: CGPoint(x: page.width - margin, y: 745))
    context.strokePath()
    drawText(
      "第 \(number) 页", in: CGRect(x: margin, y: 27, width: bodyWidth, height: 16),
      context: context, size: 9, gray: 0.5)
  }

  private static func attributedText(_ string: String, size: CGFloat, gray: CGFloat = 0.12)
    -> NSAttributedString
  {
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
    var lineSpacing: CGFloat = 5
    let paragraph = withUnsafePointer(to: &lineSpacing) { pointer in
      var setting = CTParagraphStyleSetting(
        spec: .lineSpacingAdjustment,
        valueSize: MemoryLayout<CGFloat>.size, value: pointer)
      return CTParagraphStyleCreate(&setting, 1)
    }
    return NSAttributedString(
      string: string,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          gray: gray, alpha: 1),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
      ])
  }

  private static func drawText(
    _ text: String, in rect: CGRect, context: CGContext, size: CGFloat, gray: CGFloat = 0.12
  ) {
    let line = CTLineCreateWithAttributedString(attributedText(text, size: size, gray: gray))
    let ellipsis = CTLineCreateWithAttributedString(attributedText("…", size: size, gray: gray))
    let fitted = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) ?? line
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: rect.minX, y: rect.minY + 3)
    CTLineDraw(fitted, context)
  }
}
