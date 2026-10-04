import AppKit
import Carbon.HIToolbox
import XCTest

@testable import VocabCapture

final class CaptureShortcutTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    super.setUp()
    suite = "CaptureShortcutTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }
  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testDefaultsPreserveExistingShortcuts() {
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentSelection, .defaultSelection)
    XCTAssertEqual(preferences.currentScreenshot, .defaultScreenshot)
  }

  func testLegacySelectionPresetMigrates() {
    defaults.set("control-option-w", forKey: "VocabCapture.shortcut")
    XCTAssertEqual(ShortcutPreferences(defaults: defaults).currentSelection.id, "control-option-w")
  }

  func testLegacyCustomSelectionTakesPrecedence() throws {
    defaults.set("control-option-w", forKey: "VocabCapture.shortcut")
    let legacyJSON = Data(#"{"id":"legacy","title":"⌃⌥D","keyCode":2,"modifiers":6144}"#.utf8)
    defaults.set(legacyJSON, forKey: "VocabCapture.customShortcut")
    let expected = try JSONDecoder().decode(CaptureShortcut.self, from: legacyJSON)
    XCTAssertEqual(ShortcutPreferences(defaults: defaults).currentSelection, expected)
  }

  func testSavePersistsBothShortcutsAndLegacySelection() throws {
    let preferences = ShortcutPreferences(defaults: defaults)
    preferences.save(selection: .defaultSelection, screenshot: .simpleScreenshot)
    let reloaded = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(reloaded.currentSelection, .defaultSelection)
    XCTAssertEqual(reloaded.currentScreenshot, .simpleScreenshot)
    XCTAssertEqual(
      defaults.string(forKey: "VocabCapture.shortcut"), CaptureShortcut.defaultSelection.id)
    XCTAssertNotNil(defaults.data(forKey: "VocabCapture.customShortcut"))
  }

  func testMalformedAndUnsafePreferencesFallBack() throws {
    defaults.set(Data("broken".utf8), forKey: "VocabCapture.customShortcut")
    let unsafe = CaptureShortcut(id: "unsafe", title: "D", keyCode: 2, modifiers: 0)
    defaults.set(try JSONEncoder().encode(unsafe), forKey: "VocabCapture.screenshotShortcut")
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentSelection, .defaultSelection)
    XCTAssertEqual(preferences.currentScreenshot, .defaultScreenshot)
  }

  func testExistingCustomSelectionDoesNotCollideWithScreenshotFallback() throws {
    defaults.set(
      try JSONEncoder().encode(CaptureShortcut.defaultScreenshot),
      forKey: "VocabCapture.customShortcut")
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentSelection, .defaultScreenshot)
    XCTAssertFalse(preferences.currentScreenshot.matches(preferences.currentSelection))
  }

  func testDuplicateCombinationRejectsDifferentLabels() {
    let duplicate = CaptureShortcut(
      id: "other", title: "different label", keyCode: CaptureShortcut.defaultSelection.keyCode,
      modifiers: CaptureShortcut.defaultSelection.modifiers)
    XCTAssertNotNil(
      CaptureShortcut.validationError(selection: .defaultSelection, screenshot: duplicate))
    let preferences = ShortcutPreferences(defaults: defaults)
    preferences.save(selection: .defaultSelection, screenshot: duplicate)
    XCTAssertNil(defaults.data(forKey: "VocabCapture.screenshotShortcut"))
  }

  func testPlainShiftOnlyAndReservedKeysRejected() {
    XCTAssertNil(CaptureShortcut.recorded(keyCode: 2, flags: []))
    XCTAssertNil(CaptureShortcut.recorded(keyCode: 2, flags: [.shift]))
    XCTAssertNil(CaptureShortcut.recorded(keyCode: UInt32(kVK_Escape), flags: [.option]))
    XCTAssertNil(CaptureShortcut.recorded(keyCode: UInt32(kVK_Return), flags: [.command]))
    XCTAssertNil(CaptureShortcut.recorded(keyCode: 65535, flags: [.option]))
  }

  func testPhysicalOptionKeyHasReadableTitle() {
    let shortcut = CaptureShortcut.recorded(keyCode: UInt32(kVK_ANSI_D), flags: [.option])
    XCTAssertEqual(shortcut?.title, "⌥D")
    XCTAssertEqual(shortcut?.modifiers, UInt32(optionKey))
    XCTAssertNil(
      CaptureShortcut.validationError(selection: .defaultSelection, screenshot: .simpleScreenshot))
  }
}
