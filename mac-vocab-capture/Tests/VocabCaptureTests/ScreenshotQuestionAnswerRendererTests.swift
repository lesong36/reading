import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class ScreenshotQuestionAnswerRendererTests: XCTestCase {
  func testHeadingsEmphasisListsAndCodeHaveNativeFormatting() throws {
    let rendered = ScreenshotQuestionAnswerRenderer.render("### 要点\n1. **核心**与*说明*\n- 项目\n`x_1`\n```swift\nlet value = **literal**\n```", scale: 1)
    XCTAssertTrue(rendered.string.contains("要点\n1. 核心与说明\n• 项目\nx_1"))
    XCTAssertFalse(rendered.string.contains("###"))
    XCTAssertTrue(rendered.string.contains("let value = **literal**"))
    let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertGreaterThan(heading.pointSize, 16)
    let bold = try font("核心", in: rendered)
    XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    let italic = try font("说明", in: rendered)
    XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    XCTAssertTrue(try font("x_1", in: rendered).isFixedPitch)
  }

  func testFormulaSourceAndUnknownCommandsSurviveMarkdownEscapes() {
    let formulas = #"\(P(\text{child}|\text{parents})\) 和 \[P(x_1,x_2,\dots,x_n) = \prod_i P(x_i|pa_i)\]"#
    XCTAssertEqual(ScreenshotQuestionAnswerRenderer.render(formulas).string, formulas)
    let incomplete = #"正在生成 \(x_1 + \unknown{"#
    XCTAssertEqual(ScreenshotQuestionAnswerRenderer.render(incomplete).string, incomplete)
  }

  func testLinksAllowOnlyWebSchemesAndKeepLabels() {
    let rendered = ScreenshotQuestionAnswerRenderer.render("[网页](https://example.com) [危险](javascript:alert) [文件](file:///tmp/test)")
    XCTAssertEqual(rendered.string, "网页 危险 文件")
    XCTAssertEqual((rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
    for label in ["危险", "文件"] {
      let range = (rendered.string as NSString).range(of: label)
      XCTAssertNil(rendered.attribute(.link, at: range.location, effectiveRange: nil))
    }
  }

  func testPlainStreamingTextKeepsWhitespaceAndScale() throws {
    let text = "首行  空格\n第二行 **尚未闭合\n最后一行"
    XCTAssertEqual(ScreenshotQuestionAnswerRenderer.render(text).string, text)
    XCTAssertEqual(try font("文字", in: ScreenshotQuestionAnswerRenderer.render("文字", scale: 1.5)).pointSize, 24)
  }

  private func font(_ needle: String, in text: NSAttributedString) throws -> NSFont {
    let range = (text.string as NSString).range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound)
    return try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
  }
}
