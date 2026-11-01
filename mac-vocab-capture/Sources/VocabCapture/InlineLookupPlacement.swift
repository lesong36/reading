import AppKit

/// Prefer the selected word's whitespace, then the nearest clear edge of the capture.
enum InlineLookupPlacement {
  static func origin(size: CGSize, anchor: CGRect, occupied: [CGRect], capture: CGRect, visible: CGRect) -> CGPoint {
    let area = visible.insetBy(dx: 8, dy: 8)
    let gap: CGFloat = 10
    let candidates = [
      CGPoint(x: anchor.minX, y: anchor.minY - gap - size.height),
      CGPoint(x: anchor.minX, y: anchor.maxY + gap),
      CGPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2),
      CGPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2),
      CGPoint(x: capture.maxX + gap, y: anchor.midY - size.height / 2),
      CGPoint(x: capture.minX - gap - size.width, y: anchor.midY - size.height / 2),
      CGPoint(x: anchor.minX, y: capture.minY - gap - size.height),
      CGPoint(x: anchor.minX, y: capture.maxY + gap),
    ].map { point in
      CGRect(origin: CGPoint(x: max(area.minX, min(point.x, area.maxX - size.width)),
                             y: max(area.minY, min(point.y, area.maxY - size.height))), size: size)
    }
    func overlap(_ rect: CGRect) -> CGFloat {
      occupied.reduce(0) { total, word in
        let intersection = rect.intersection(word.insetBy(dx: -3, dy: -3))
        return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
      }
    }
    return candidates.min { lhs, rhs in
      let left = overlap(lhs), right = overlap(rhs)
      if left != right { return left < right }
      return hypot(lhs.midX - anchor.midX, lhs.midY - anchor.midY)
        < hypot(rhs.midX - anchor.midX, rhs.midY - anchor.midY)
    }?.origin ?? area.origin
  }
}
