import Foundation

/// A floating button and its delayed reads belong to exactly one selection.
struct SelectionCaptureState {
  private(set) var revision = UUID()
  private(set) var selection: SelectedText?

  @discardableResult
  mutating func invalidate() -> UUID {
    revision = UUID()
    selection = nil
    return revision
  }

  @discardableResult
  mutating func accept(_ value: SelectedText, revision expected: UUID) -> Bool {
    guard revision == expected else { return false }
    selection = value
    return true
  }

  mutating func consume() -> SelectedText? {
    let value = selection
    invalidate()
    return value
  }
}
