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
    XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
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

  func testOldTwoShortcutConfigurationAddsDerivedQuestionWithoutWriting() throws {
    let selectionData = try JSONEncoder().encode(CaptureShortcut.selectionPresets[1])
    let screenshotData = try JSONEncoder().encode(CaptureShortcut.simpleScreenshot)
    defaults.set(selectionData, forKey: "VocabCapture.customShortcut")
    defaults.set(screenshotData, forKey: "VocabCapture.screenshotShortcut")
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentSelection, CaptureShortcut.selectionPresets[1])
    XCTAssertEqual(preferences.currentScreenshot, .simpleScreenshot)
    XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
    XCTAssertEqual(defaults.data(forKey: "VocabCapture.customShortcut"), selectionData)
    XCTAssertEqual(defaults.data(forKey: "VocabCapture.screenshotShortcut"), screenshotData)
    XCTAssertNil(defaults.object(forKey: "VocabCapture.questionScreenshotShortcut"))
    XCTAssertNil(defaults.object(forKey: "VocabCapture.shortcut"))
  }

  func testDerivedQuestionDefaultAvoidsEitherExistingShortcut() throws {
    for (selection, screenshot) in [
      (CaptureShortcut.defaultQuestionScreenshot, CaptureShortcut.defaultScreenshot),
      (CaptureShortcut.defaultSelection, CaptureShortcut.defaultQuestionScreenshot),
      (CaptureShortcut.defaultQuestionScreenshot, CaptureShortcut.questionScreenshotFallbacks[1]),
    ] {
      defaults.set(try JSONEncoder().encode(selection), forKey: "VocabCapture.customShortcut")
      defaults.set(try JSONEncoder().encode(screenshot), forKey: "VocabCapture.screenshotShortcut")
      let question = ShortcutPreferences(defaults: defaults).currentQuestionScreenshot
      XCTAssertFalse(question.matches(selection))
      XCTAssertFalse(question.matches(screenshot))
      XCTAssertNil(defaults.object(forKey: "VocabCapture.questionScreenshotShortcut"))
      if screenshot == CaptureShortcut.questionScreenshotFallbacks[1] {
        XCTAssertEqual(question, CaptureShortcut.questionScreenshotFallbacks[2])
      }
    }
  }

  func testThreeWayValidationRejectsEveryPairAndUnsafeQuestion() {
    XCTAssertNil(
      CaptureShortcut.validationError(
        selection: .defaultSelection, screenshot: .defaultScreenshot,
        questionScreenshot: .defaultQuestionScreenshot))
    XCTAssertNotNil(
      CaptureShortcut.validationError(
        selection: .defaultSelection, screenshot: .defaultSelection,
        questionScreenshot: .defaultQuestionScreenshot))
    for duplicate in [CaptureShortcut.defaultSelection, .defaultScreenshot] {
      XCTAssertNotNil(
        CaptureShortcut.validationError(
          selection: .defaultSelection, screenshot: .defaultScreenshot,
          questionScreenshot: duplicate))
    }
    let unsafe = CaptureShortcut(id: "unsafe", title: "A", keyCode: 0, modifiers: 0)
    XCTAssertNotNil(
      CaptureShortcut.validationError(
        selection: .defaultSelection, screenshot: .defaultScreenshot, questionScreenshot: unsafe))
  }

  func testThreeShortcutsPersistAcrossRestart() {
    let question = CaptureShortcut.questionScreenshotFallbacks[2]
    ShortcutPreferences(defaults: defaults).save(
      selection: .defaultSelection, screenshot: .simpleScreenshot, questionScreenshot: question)
    let reloaded = ShortcutPreferences(defaults: UserDefaults(suiteName: suite)!)
    XCTAssertEqual(reloaded.currentSelection, .defaultSelection)
    XCTAssertEqual(reloaded.currentScreenshot, .simpleScreenshot)
    XCTAssertEqual(reloaded.currentQuestionScreenshot, question)
  }

  func testInvalidThreeShortcutSaveDoesNotMutateExistingValues() {
    let preferences = ShortcutPreferences(defaults: defaults)
    preferences.save(
      selection: .defaultSelection, screenshot: .defaultScreenshot,
      questionScreenshot: .defaultQuestionScreenshot)
    let keys = [
      "VocabCapture.customShortcut", "VocabCapture.screenshotShortcut",
      "VocabCapture.questionScreenshotShortcut",
    ]
    let before = keys.map { defaults.data(forKey: $0) }
    preferences.save(
      selection: .selectionPresets[1], screenshot: .simpleScreenshot,
      questionScreenshot: .simpleScreenshot)
    XCTAssertEqual(keys.map { defaults.data(forKey: $0) }, before)
    XCTAssertEqual(
      defaults.string(forKey: "VocabCapture.shortcut"), CaptureShortcut.defaultSelection.id)
  }

  func testInvalidOrConflictingStoredQuestionUsesSafeDerivedDefault() throws {
    for data in [Data("broken".utf8), try JSONEncoder().encode(CaptureShortcut.defaultSelection)] {
      defaults.set(data, forKey: "VocabCapture.questionScreenshotShortcut")
      let preferences = ShortcutPreferences(defaults: defaults)
      XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
      XCTAssertEqual(defaults.data(forKey: "VocabCapture.questionScreenshotShortcut"), data)
    }
  }

  func testTwoShortcutSavePreservesExistingQuestionWhenStillDistinct() {
    let preferences = ShortcutPreferences(defaults: defaults)
    let question = CaptureShortcut.questionScreenshotFallbacks[2]
    preferences.save(
      selection: .defaultSelection, screenshot: .defaultScreenshot, questionScreenshot: question)
    preferences.save(selection: .defaultSelection, screenshot: .simpleScreenshot)
    XCTAssertEqual(preferences.currentQuestionScreenshot, question)
  }
}
