import AppKit
import XCTest

@testable import VocabCapture

@MainActor
final class ApplicationEditingMenuTests: XCTestCase {
  func testStandardShortcutsUseResponderChainAndKeepRedoDistinct() throws {
    _ = NSApplication.shared
    let menu = ApplicationEditingMenu.make()
    let editing = try XCTUnwrap(menu.items.first { $0.title == "编辑" }?.submenu)
    for (title, shortcut, action) in [
      ("撤销", "z", "undo:"), ("剪切", "x", "cut:"), ("复制", "c", "copy:"),
      ("粘贴", "v", "paste:"), ("全选", "a", "selectAll:"),
    ] {
      let item = try XCTUnwrap(editing.items.first { $0.title == title })
      XCTAssertEqual(item.keyEquivalent, shortcut)
      XCTAssertEqual(item.keyEquivalentModifierMask, .command)
      XCTAssertEqual(item.action, Selector(action))
      XCTAssertNil(item.target)
    }
    let redo = try XCTUnwrap(editing.items.first { $0.title == "重做" })
    XCTAssertEqual(redo.action, Selector(("redo:")))
    XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
  }

  func testCommandShortcutsReachResponderChain() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let previousResponder = NSApp.nextResponder
    let editor = RecordingEditor()
    let menu = ApplicationEditingMenu.make()
    NSApp.nextResponder = editor
    NSApp.mainMenu = menu
    defer {
      NSApp.mainMenu = previousMenu
      NSApp.nextResponder = previousResponder
    }
    XCTAssertTrue(
      NSApp.target(forAction: #selector(NSText.paste(_:))) as? RecordingEditor === editor)
    for key in ["v", "c", "x", "a"] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero,
          modifierFlags: .command, timestamp: 0, windowNumber: 0,
          context: nil, characters: key, charactersIgnoringModifiers: key,
          isARepeat: false, keyCode: 0))
      XCTAssertTrue(menu.performKeyEquivalent(with: event), "Shortcut \(key) was not handled")
    }
    for _ in 0..<100 where editor.received.count < 4 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(editor.received, ["paste", "copy", "cut", "selectAll"])
  }

  func testOrdinaryTypingDoesNotInvokeEditingAction() throws {
    _ = NSApplication.shared
    let menu = ApplicationEditingMenu.make()
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    XCTAssertFalse(menu.performKeyEquivalent(with: event))
  }
}

@MainActor
private final class RecordingEditor: NSResponder, NSMenuItemValidation {
  var received: [String] = []
  @objc func paste(_ sender: Any?) { received.append("paste") }
  @objc func copy(_ sender: Any?) { received.append("copy") }
  @objc func cut(_ sender: Any?) { received.append("cut") }
  override func selectAll(_ sender: Any?) { received.append("selectAll") }
  func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
