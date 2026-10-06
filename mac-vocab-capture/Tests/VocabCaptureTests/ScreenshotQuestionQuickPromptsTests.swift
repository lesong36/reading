import Foundation
import XCTest

@testable import VocabCapture

final class ScreenshotQuestionQuickPromptsTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "VocabCapture.QuickPromptsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
    super.tearDown()
  }

  func testDefaultsDoNotWriteAndKeepExistingQuickQuestions() {
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    XCTAssertEqual(preferences.prompts.map(\.title), ["解释这段话", "分析句子结构", "总结要点"])
    XCTAssertEqual(preferences.prompts.map(\.prompt), preferences.prompts.map(\.title))
    XCTAssertNil(defaults.object(forKey: ScreenshotQuestionQuickPrompts.storageKey))
  }

  func testFiveTemplatesPersistWithSeparateTitleAndMultilinePrompt() throws {
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    let templates = (0..<5).map {
      ScreenshotQuestionQuickPrompt(id: "\($0)", title: "\($0)", prompt: "第一行\n第二行：\($0)")
    }
    try preferences.save(templates)
    let reopened = ScreenshotQuestionQuickPrompts(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    XCTAssertEqual(reopened.prompts, templates)
    XCTAssertEqual(reopened.prompts.last?.prompt, "第一行\n第二行：4")
  }

  func testEditingOnePreservesIDsOrderAndOtherPreferences() throws {
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    let original = preferences.prompts
    defaults.set("untouched", forKey: "VocabCapture.questionModelProfiles")
    var edited = original
    edited[1] = ScreenshotQuestionQuickPrompt(
      id: original[1].id, title: " 语法检查 ", prompt: "\n请逐句检查语法，解释介词后代词的宾格。 \n")
    try preferences.save(edited)
    XCTAssertEqual(preferences.prompts[0], original[0])
    XCTAssertEqual(preferences.prompts[2], original[2])
    XCTAssertEqual(preferences.prompts[1].id, original[1].id)
    XCTAssertEqual(preferences.prompts[1].title, "语法检查")
    XCTAssertEqual(preferences.prompts[1].prompt, "请逐句检查语法，解释介词后代词的宾格。")
    XCTAssertEqual(defaults.string(forKey: "VocabCapture.questionModelProfiles"), "untouched")
  }

  func testRemovingAllIsPersistedAcrossRestart() throws {
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    try preferences.save([])
    XCTAssertTrue(ScreenshotQuestionQuickPrompts(defaults: defaults).prompts.isEmpty)
  }

  func testValidationDoesNotReplaceSavedTemplates() throws {
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    try preferences.save(preferences.prompts)
    let data = defaults.data(forKey: ScreenshotQuestionQuickPrompts.storageKey)
    let invalid: [([ScreenshotQuestionQuickPrompt], ScreenshotQuestionQuickPromptsError)] = [
      ((0..<6).map { ScreenshotQuestionQuickPrompt(title: "\($0)", prompt: "问题") }, .tooMany),
      ([ScreenshotQuestionQuickPrompt(title: " ", prompt: "问题")], .missingTitle),
      ([ScreenshotQuestionQuickPrompt(title: "标题", prompt: "\n ")], .missingPrompt),
      (
        [ScreenshotQuestionQuickPrompt(title: String(repeating: "字", count: 21), prompt: "问题")],
        .invalidTitle
      ),
      ([ScreenshotQuestionQuickPrompt(title: "多\n行", prompt: "问题")], .invalidTitle),
      ([ScreenshotQuestionQuickPrompt(id: "", title: "标题", prompt: "问题")], .invalidID),
      (
        [
          ScreenshotQuestionQuickPrompt(id: "same", title: "标题", prompt: "问题"),
          ScreenshotQuestionQuickPrompt(id: "same", title: "另一个", prompt: "另一个问题"),
        ], .invalidID
      ),
    ]
    for (templates, expected) in invalid {
      XCTAssertThrowsError(try preferences.save(templates)) {
        XCTAssertEqual($0 as? ScreenshotQuestionQuickPromptsError, expected)
      }
      XCTAssertEqual(defaults.data(forKey: ScreenshotQuestionQuickPrompts.storageKey), data)
    }
  }

  func testCorruptDataShowsDefaultsWithoutOverwritingData() {
    let badData = Data("broken".utf8)
    defaults.set(badData, forKey: ScreenshotQuestionQuickPrompts.storageKey)
    let preferences = ScreenshotQuestionQuickPrompts(defaults: defaults)
    XCTAssertEqual(preferences.prompts, ScreenshotQuestionQuickPrompts.defaultPrompts)
    XCTAssertEqual(defaults.data(forKey: ScreenshotQuestionQuickPrompts.storageKey), badData)
  }
}
