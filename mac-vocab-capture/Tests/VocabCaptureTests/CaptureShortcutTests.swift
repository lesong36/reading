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

  func testDefaultsPreserveScreenshotShortcuts() {
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentScreenshot, .defaultScreenshot)
    XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
  }

  func testLegacySelectionCannotOverrideEitherScreenshotAndIsNotRewritten() throws {
    for oldSelection in [CaptureShortcut.simpleScreenshot, .defaultQuestionScreenshot] {
      let legacyData = try JSONEncoder().encode(oldSelection)
      defaults.set(legacyData, forKey: "VocabCapture.customShortcut")
      defaults.set("control-option-w", forKey: "VocabCapture.shortcut")
      let question = CaptureShortcut.defaultQuestionScreenshot
      ShortcutPreferences(defaults: defaults).save(screenshot: .simpleScreenshot, questionScreenshot: question)
      let reloaded = ShortcutPreferences(defaults: defaults)
      XCTAssertEqual(reloaded.currentScreenshot, .simpleScreenshot)
      XCTAssertEqual(reloaded.currentQuestionScreenshot, question)
      XCTAssertEqual(defaults.data(forKey: "VocabCapture.customShortcut"), legacyData)
      XCTAssertEqual(defaults.string(forKey: "VocabCapture.shortcut"), "control-option-w")
    }
  }

  func testSavePersistsOnlyScreenshotPreferencesAcrossRestart() {
    let question = CaptureShortcut.questionScreenshotFallbacks[2]
    ShortcutPreferences(defaults: defaults).save(screenshot: .simpleScreenshot, questionScreenshot: question)
    let reloaded = ShortcutPreferences(defaults: UserDefaults(suiteName: suite)!)
    XCTAssertEqual(reloaded.currentScreenshot, .simpleScreenshot)
    XCTAssertEqual(reloaded.currentQuestionScreenshot, question)
    XCTAssertNil(defaults.object(forKey: "VocabCapture.customShortcut"))
    XCTAssertNil(defaults.object(forKey: "VocabCapture.shortcut"))
  }

  func testMalformedAndUnsafePreferencesFallBack() throws {
    let unsafe = CaptureShortcut(id: "unsafe", title: "D", keyCode: 2, modifiers: 0)
    for data in [Data("broken".utf8), try JSONEncoder().encode(unsafe)] {
      defaults.set(data, forKey: "VocabCapture.screenshotShortcut")
      let preferences = ShortcutPreferences(defaults: defaults)
      XCTAssertEqual(preferences.currentScreenshot, .defaultScreenshot)
      XCTAssertEqual(defaults.data(forKey: "VocabCapture.screenshotShortcut"), data)
    }
  }

  func testDuplicateCombinationRejectsDifferentLabels() {
    let duplicate = CaptureShortcut(
      id: "other", title: "different label", keyCode: CaptureShortcut.defaultScreenshot.keyCode,
      modifiers: CaptureShortcut.defaultScreenshot.modifiers)
    XCTAssertNotNil(CaptureShortcut.validationError(screenshot: .defaultScreenshot, questionScreenshot: duplicate))
    ShortcutPreferences(defaults: defaults).save(screenshot: .defaultScreenshot, questionScreenshot: duplicate)
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
    XCTAssertNil(CaptureShortcut.validationError(screenshot: .simpleScreenshot, questionScreenshot: .defaultQuestionScreenshot))
  }

  func testOldScreenshotConfigurationAddsQuestionWithoutWriting() throws {
    let screenshotData = try JSONEncoder().encode(CaptureShortcut.simpleScreenshot)
    defaults.set(screenshotData, forKey: "VocabCapture.screenshotShortcut")
    let preferences = ShortcutPreferences(defaults: defaults)
    XCTAssertEqual(preferences.currentScreenshot, .simpleScreenshot)
    XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
    XCTAssertEqual(defaults.data(forKey: "VocabCapture.screenshotShortcut"), screenshotData)
    XCTAssertNil(defaults.object(forKey: "VocabCapture.questionScreenshotShortcut"))
  }

  func testDerivedQuestionAvoidsScreenshotWithoutWriting() throws {
    for screenshot in CaptureShortcut.questionScreenshotFallbacks {
      defaults.set(try JSONEncoder().encode(screenshot), forKey: "VocabCapture.screenshotShortcut")
      let question = ShortcutPreferences(defaults: defaults).currentQuestionScreenshot
      XCTAssertFalse(question.matches(screenshot))
      XCTAssertNil(defaults.object(forKey: "VocabCapture.questionScreenshotShortcut"))
    }
  }

  func testValidationRejectsUnsafeScreenshotOrQuestion() {
    let unsafe = CaptureShortcut(id: "unsafe", title: "A", keyCode: 0, modifiers: 0)
    XCTAssertNotNil(CaptureShortcut.validationError(screenshot: unsafe, questionScreenshot: .defaultQuestionScreenshot))
    XCTAssertNotNil(CaptureShortcut.validationError(screenshot: .defaultScreenshot, questionScreenshot: unsafe))
  }

  func testInvalidSaveDoesNotMutateExistingValues() {
    let preferences = ShortcutPreferences(defaults: defaults)
    preferences.save(screenshot: .defaultScreenshot, questionScreenshot: .defaultQuestionScreenshot)
    let keys = ["VocabCapture.screenshotShortcut", "VocabCapture.questionScreenshotShortcut"]
    let before = keys.map { defaults.data(forKey: $0) }
    preferences.save(screenshot: .simpleScreenshot, questionScreenshot: .simpleScreenshot)
    XCTAssertEqual(keys.map { defaults.data(forKey: $0) }, before)
  }

  func testInvalidOrConflictingStoredQuestionUsesSafeDefaultWithoutWriting() throws {
    for data in [Data("broken".utf8), try JSONEncoder().encode(CaptureShortcut.defaultScreenshot)] {
      defaults.set(data, forKey: "VocabCapture.questionScreenshotShortcut")
      let preferences = ShortcutPreferences(defaults: defaults)
      XCTAssertEqual(preferences.currentQuestionScreenshot, .defaultQuestionScreenshot)
      XCTAssertEqual(defaults.data(forKey: "VocabCapture.questionScreenshotShortcut"), data)
    }
  }
}
