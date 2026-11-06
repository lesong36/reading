import AppKit
import XCTest
@testable import VocabCapture

@MainActor
final class MathResearchModelSelectionUITests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func testIdentitySelectionMissingProfileAndFailedChangeRemainExplicit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("research-choice-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    var profiles = [
      ScreenshotQuestionModelProfile(id: "first", name: "同名模型", baseURL: "https://first.test", model: "first"),
      ScreenshotQuestionModelProfile(id: "second", name: "同名模型", baseURL: "https://second.test", model: "second"),
    ]
    var chosen: String?
    var changes = 0
    var reject = false
    let library = MathQuestionLibrary(store: store, reindex: { _ in },
      researchProfiles: { profiles }, selectedResearchProfile: { chosen },
      onResearchProfileChanged: { id in
        if reject { throw ScreenshotQuestionPreferencesError.missingProfile }
        changes += 1; chosen = id
      })
    defer { library.close() }
    let views = descendants(try XCTUnwrap(library.contentView))
    let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "后台教研模型" })
    XCTAssertEqual(picker.numberOfItems, 3, "Same-name model identities must not disappear")
    XCTAssertNil(picker.selectedItem?.representedObject)
    picker.select(try XCTUnwrap(picker.itemArray.first { $0.representedObject as? String == "second" }))
    picker.sendAction(picker.action, to: picker.target)
    XCTAssertEqual(chosen, "second"); XCTAssertEqual(changes, 1)
    reject = true
    picker.select(try XCTUnwrap(picker.itemArray.first { $0.representedObject as? String == "first" }))
    picker.sendAction(picker.action, to: picker.target)
    XCTAssertEqual(chosen, "second"); XCTAssertEqual(changes, 1)
    XCTAssertEqual(picker.selectedItem?.representedObject as? String, "second")
    XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("后台模型未更新") })
    profiles.removeLast()
    library.present()
    XCTAssertEqual(picker.titleOfSelectedItem, "已移除的模型，请重新选择")
    XCTAssertFalse(try XCTUnwrap(picker.selectedItem).isEnabled)
    XCTAssertEqual(changes, 1, "Refreshing missing profile must not silently choose a provider")
    reject = false
    picker.selectItem(at: 0); picker.sendAction(picker.action, to: picker.target)
    XCTAssertNil(chosen); XCTAssertEqual(changes, 2)
    library.setContentSize(NSSize(width: 900, height: 760))
    library.contentView?.layoutSubtreeIfNeeded()
    let frame = picker.convert(picker.bounds, to: library.contentView)
    XCTAssertTrue(try XCTUnwrap(library.contentView).bounds.contains(frame))
    library.close(); await store.close()
  }
}
