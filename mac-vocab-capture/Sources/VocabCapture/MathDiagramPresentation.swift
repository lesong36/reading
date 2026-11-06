import AppKit
import CryptoKit

/// One attachment presentation for the question window and archived answers.
@MainActor
enum MathDiagramPresentation {
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 24
    cache.totalCostLimit = 48 * 1024 * 1024
    return cache
  }()

  static func append(
    _ diagrams: [MathDiagram], failure: String?, to text: NSMutableAttributedString,
    width: CGFloat, fontSize: CGFloat = 16
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor,
    ]
    for diagram in diagrams {
      do {
        let data = try JSONEncoder().encode(diagram)
        let size = max(360, min(900, width))
        let key = (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          + ":\(Int(size)):\(MathDiagramRenderer.rendererVersion)") as NSString
        let image: NSImage
        if let existing = images.object(forKey: key) {
          image = existing
        } else {
          image = try MathDiagramRenderer.image(diagram, width: size)
          images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 16))
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: image.size)
        text.append(NSAttributedString(string: "\n\n", attributes: attributes))
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\n图解关系已检查 · 答案核验以用户标记为准\n", attributes: [
          .font: NSFont.systemFont(ofSize: max(10, fontSize * 0.72)),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]))
      } catch {
        text.append(NSAttributedString(string: "\n图解未显示：\(error.localizedDescription)\n", attributes: attributes))
      }
    }
    if let failure {
      text.append(NSAttributedString(string: "\n\(diagrams.isEmpty ? "图解未生成" : "部分图解未完成")：\(failure)\n", attributes: attributes))
    }
  }
}
