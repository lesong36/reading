import AppKit

/// A local, selectable answer view: model output never becomes executable HTML.
@MainActor
enum ScreenshotQuestionAnswerRenderer {
  static func render(_ markdown: String, scale: CGFloat = 1) -> NSAttributedString {
    let size = 16 * scale
    let result = NSMutableAttributedString(string: "")
    let lines = markdown.components(separatedBy: "\n")
    var fence: String?
    for (index, original) in lines.enumerated() {
      let trimmed = original.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        let marker = String(trimmed.prefix(3))
        if fence == nil { fence = marker; continue }
        if fence == marker { fence = nil; continue }
      }
      let line: NSAttributedString
      if fence != nil {
        line = NSAttributedString(string: original, attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular),
          .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor,
        ])
      } else {
        var body = original
        var font = NSFont.systemFont(ofSize: size)
        var quote = false
        if let heading = body.range(of: "^ {0,3}#{1,6} +", options: .regularExpression) {
          let level = body[heading].filter { $0 == "#" }.count
          body.removeSubrange(heading)
          font = .systemFont(ofSize: size * (level <= 2 ? 1.35 : 1.15), weight: .bold)
        } else if let bullet = body.range(of: "^([ \\t]*)[-+*] +", options: .regularExpression) {
          let indentation = String(body.prefix { $0 == " " || $0 == "\t" })
          body.replaceSubrange(bullet, with: indentation + "• ")
        } else if let prefix = body.range(of: "^ {0,3}> ?", options: .regularExpression) {
          body.replaceSubrange(prefix, with: "│ ")
          quote = true
        }
        let rendered = inline(body, font: font)
        if quote {
          rendered.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: 0, length: rendered.length))
        }
        line = rendered
      }
      result.append(line)
      if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 4 * scale
    result.addAttribute(.paragraphStyle, value: paragraph,
                        range: NSRange(location: 0, length: result.length))
    return result
  }

  private static func inline(_ text: String, font: NSFont) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(string: "")
    // Foundation's Markdown parser consumes backslash escapes. Isolate TeX first so
    // even unsupported commands and incomplete streaming formulas retain their source.
    let formula = try! NSRegularExpression(pattern: #"\\\([\s\S]*?(?:\\\)|$)|\\\[[\s\S]*?(?:\\\]|$)|\$\$[\s\S]*?(?:\$\$|$)"#)
    let source = text as NSString
    var cursor = 0
    for match in formula.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      if match.range.location > cursor {
        result.append(markdownInline(source.substring(with: NSRange(location: cursor,
          length: match.range.location - cursor)), font: font))
      }
      result.append(NSAttributedString(string: source.substring(with: match.range), attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.95, weight: .regular),
        .foregroundColor: NSColor.labelColor,
      ]))
      cursor = NSMaxRange(match.range)
    }
    if cursor < source.length {
      result.append(markdownInline(source.substring(from: cursor), font: font))
    }
    return result
  }

  private static func markdownInline(_ text: String, font: NSFont) -> NSAttributedString {
    guard let parsed = try? AttributedString(markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
      return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
    let result = NSMutableAttributedString(string: "")
    for run in parsed.runs {
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
      if let intent = run.inlinePresentationIntent {
        var traits: NSFontTraitMask = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
        attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
        if intent.contains(.code) {
          attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
          attributes[.backgroundColor] = NSColor.quaternaryLabelColor
        }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      }
      if let url = run.link, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
        attributes[.link] = url
      }
      result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
    }
    // Keep ordinary URLs clickable too, without enabling file/javascript schemes.
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      detector.enumerateMatches(in: result.string, range: NSRange(location: 0, length: result.length)) { match, _, _ in
        guard let match, let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        result.addAttribute(.link, value: url, range: match.range)
      }
    }
    return result
  }
}
