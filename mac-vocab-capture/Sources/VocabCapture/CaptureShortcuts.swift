import AppKit
import Carbon.HIToolbox
import Foundation

struct CaptureShortcut: Codable, Equatable {
  let id: String
  let title: String
  let keyCode: UInt32
  let modifiers: UInt32

  static let defaultSelection = CaptureShortcut(
    id: "option-command-d", title: "⌥⌘D", keyCode: UInt32(kVK_ANSI_D),
    modifiers: UInt32(optionKey | cmdKey))
  static let defaultScreenshot = CaptureShortcut(
    id: "option-command-o", title: "⌥⌘O", keyCode: UInt32(kVK_ANSI_O),
    modifiers: UInt32(optionKey | cmdKey))
  static let defaultQuestionScreenshot = CaptureShortcut(
    id: "option-command-a", title: "⌥⌘A", keyCode: UInt32(kVK_ANSI_A),
    modifiers: UInt32(optionKey | cmdKey))
  static let questionScreenshotFallbacks = [
    defaultQuestionScreenshot,
    CaptureShortcut(
      id: "option-command-q", title: "⌥⌘Q", keyCode: UInt32(kVK_ANSI_Q),
      modifiers: UInt32(optionKey | cmdKey)),
    CaptureShortcut(
      id: "control-option-a", title: "⌃⌥A", keyCode: UInt32(kVK_ANSI_A),
      modifiers: UInt32(controlKey | optionKey)),
  ]
  static let simpleScreenshot = CaptureShortcut(
    id: "option-d", title: "⌥D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
  static let alternateScreenshot = CaptureShortcut(
    id: "control-option-s", title: "⌃⌥S", keyCode: UInt32(kVK_ANSI_S),
    modifiers: UInt32(controlKey | optionKey))
  static let selectionPresets = [
    defaultSelection,
    CaptureShortcut(
      id: "control-option-d", title: "⌃⌥D", keyCode: UInt32(kVK_ANSI_D),
      modifiers: UInt32(controlKey | optionKey)),
    CaptureShortcut(
      id: "control-option-w", title: "⌃⌥W", keyCode: UInt32(kVK_ANSI_W),
      modifiers: UInt32(controlKey | optionKey)),
  ]
  static let screenshotPresets = [simpleScreenshot, alternateScreenshot, defaultScreenshot]

  func matches(_ other: CaptureShortcut) -> Bool {
    keyCode == other.keyCode && modifiers == other.modifiers
  }

  var validationError: String? {
    let required = UInt32(cmdKey | optionKey | controlKey)
    let allowed = required | UInt32(shiftKey)
    guard modifiers & required != 0, modifiers & ~allowed == 0 else {
      return "快捷键至少需要包含 ⌘、⌥ 或 ⌃，不能只用普通键或 Shift。"
    }
    guard Self.keyTitles[keyCode] != nil else { return "请使用字母、数字、标点、空格、方向键或功能键。" }
    return nil
  }

  static func validationError(selection: CaptureShortcut, screenshot: CaptureShortcut) -> String? {
    if let error = selection.validationError { return "选词快捷键：" + error }
    if let error = screenshot.validationError { return "截图快捷键：" + error }
    if selection.matches(screenshot) { return "选词和截图需要使用不同的快捷键。" }
    return nil
  }

  static func validationError(
    selection: CaptureShortcut, screenshot: CaptureShortcut, questionScreenshot: CaptureShortcut
  ) -> String? {
    if let error = validationError(selection: selection, screenshot: screenshot) { return error }
    if let error = questionScreenshot.validationError { return "截图问一问快捷键：" + error }
    if questionScreenshot.matches(selection) || questionScreenshot.matches(screenshot) {
      return "截图问一问需要使用与选词、截图取词不同的快捷键。"
    }
    return nil
  }

  static func recorded(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> CaptureShortcut? {
    guard let key = keyTitles[keyCode] else { return nil }
    var modifiers: UInt32 = 0
    var prefix = ""
    for (flag, carbon, symbol) in [
      (NSEvent.ModifierFlags.control, UInt32(controlKey), "⌃"), (.option, UInt32(optionKey), "⌥"),
      (.shift, UInt32(shiftKey), "⇧"), (.command, UInt32(cmdKey), "⌘"),
    ] {
      if flags.contains(flag) {
        modifiers |= carbon
        prefix += symbol
      }
    }
    let shortcut = CaptureShortcut(
      id: "custom-\(keyCode)-\(modifiers)", title: prefix + key, keyCode: keyCode,
      modifiers: modifiers)
    return shortcut.validationError == nil ? shortcut : nil
  }

  // Physical key labels avoid Option-generated characters such as ∂ for Option-D.
  private static let keyTitles: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
    12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
    22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
    34: "I", 35: "P",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
    47: ".", 49: "空格", 50: "`",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
    106: "F16", 107: "F14",
    109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up", 118: "F4", 119: "End",
    120: "F2", 121: "Page Down", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑",
  ]
}

final class ShortcutPreferences {
  private let defaults: UserDefaults
  private let selectionKey = "VocabCapture.customShortcut"
  private let legacySelectionKey = "VocabCapture.shortcut"
  private let screenshotKey = "VocabCapture.screenshotShortcut"
  private let questionScreenshotKey = "VocabCapture.questionScreenshotShortcut"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var currentSelection: CaptureShortcut {
    if let shortcut = read(selectionKey) { return shortcut }
    let id = defaults.string(forKey: legacySelectionKey)
    return CaptureShortcut.selectionPresets.first { $0.id == id } ?? .defaultSelection
  }

  var currentScreenshot: CaptureShortcut {
    if let shortcut = read(screenshotKey), !shortcut.matches(currentSelection) { return shortcut }
    return [.defaultScreenshot, .simpleScreenshot, .alternateScreenshot].first {
      !$0.matches(currentSelection)
    } ?? .defaultScreenshot
  }

  var currentQuestionScreenshot: CaptureShortcut {
    questionShortcut(selection: currentSelection, screenshot: currentScreenshot)
  }

  private func questionShortcut(
    selection: CaptureShortcut, screenshot: CaptureShortcut
  ) -> CaptureShortcut {
    if let shortcut = read(questionScreenshotKey),
      !shortcut.matches(selection), !shortcut.matches(screenshot)
    {
      return shortcut
    }
    // Two existing shortcuts cannot exhaust all three fallback combinations.
    return CaptureShortcut.questionScreenshotFallbacks.first {
      !$0.matches(selection) && !$0.matches(screenshot)
    }!
  }

  func save(selection: CaptureShortcut, screenshot: CaptureShortcut) {
    save(
      selection: selection, screenshot: screenshot,
      questionScreenshot: questionShortcut(selection: selection, screenshot: screenshot))
  }

  func save(
    selection: CaptureShortcut, screenshot: CaptureShortcut, questionScreenshot: CaptureShortcut
  ) {
    guard
      CaptureShortcut.validationError(
        selection: selection, screenshot: screenshot, questionScreenshot: questionScreenshot)
        == nil,
      let selectionData = try? JSONEncoder().encode(selection),
      let screenshotData = try? JSONEncoder().encode(screenshot),
      let questionData = try? JSONEncoder().encode(questionScreenshot)
    else { return }
    defaults.set(selectionData, forKey: selectionKey)
    defaults.set(selection.id, forKey: legacySelectionKey)
    defaults.set(screenshotData, forKey: screenshotKey)
    defaults.set(questionData, forKey: questionScreenshotKey)
  }

  private func read(_ key: String) -> CaptureShortcut? {
    guard let data = defaults.data(forKey: key),
      let shortcut = try? JSONDecoder().decode(CaptureShortcut.self, from: data),
      shortcut.validationError == nil
    else { return nil }
    return shortcut
  }
}

@MainActor
final class CaptureShortcutSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 470, height: 420), styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
  private let selectionRecorder: CaptureShortcutRecorder
  private let screenshotRecorder: CaptureShortcutRecorder
  private let questionScreenshotRecorder: CaptureShortcutRecorder
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private var validateAndSave: ((CaptureShortcut, CaptureShortcut, CaptureShortcut) -> String?)?
  private var onClose: (() -> Void)?
  private var onRecordingChange: (Bool) -> Void = { _ in }
  var isRecording: Bool {
    [selectionRecorder, screenshotRecorder, questionScreenshotRecorder].contains { $0.window?.firstResponder === $0 }
  }
  private var isEmbedded = false
  private var savedShortcuts: (CaptureShortcut, CaptureShortcut, CaptureShortcut)
  private let cancelButton = NSButton()
  private let saveButton = NSButton()
  private let instructions = NSTextField(wrappingLabelWithString: "点按快捷键输入框，再按新的组合键。按 Esc 取消，按回车保存。")
  private let formView = NSView()

  init(
    selection: CaptureShortcut, screenshot: CaptureShortcut,
    questionScreenshot: CaptureShortcut = .defaultQuestionScreenshot
  ) {
    savedShortcuts = (selection, screenshot, questionScreenshot)
    selectionRecorder = CaptureShortcutRecorder(initial: selection)
    screenshotRecorder = CaptureShortcutRecorder(initial: screenshot)
    questionScreenshotRecorder = CaptureShortcutRecorder(initial: questionScreenshot)
    super.init()
    panel.title = "拾词快捷键"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self
    panel.contentView = formView
    instructions.font = .systemFont(ofSize: 12)
    instructions.textColor = .secondaryLabelColor
    var rows: [NSView] = []
    for (label, recorder) in [
      ("选中文字查词", selectionRecorder), ("截图取词", screenshotRecorder),
      ("截图问一问", questionScreenshotRecorder),
    ] {
      rows.append(SettingsForm.row(label, control: recorder))
      recorder.setAccessibilityLabel(label)
      recorder.heightAnchor.constraint(equalToConstant: 32).isActive = true
      recorder.onFocusChange = { [weak self] in self?.onRecordingChange($0) }
      recorder.onCancel = { [weak self] in self?.cancel(nil) }
      recorder.onSave = { [weak self] in self?.save(nil) }
      recorder.onError = { [weak self] message in self?.setStatus(message, error: true) }
      recorder.onChange = { [weak self] in self?.setStatus("") }
    }
    let presets = NSStackView()
    presets.spacing = 8
    for (index, shortcut) in CaptureShortcut.screenshotPresets.enumerated() {
      let button = NSButton(title: shortcut.title, target: self, action: #selector(selectPreset(_:)))
      button.bezelStyle = .rounded
      button.tag = index
      presets.addArrangedSubview(button)
    }
    presets.addArrangedSubview(NSView())
    rows.append(SettingsForm.row("截图推荐", control: presets))
    errorLabel.font = .systemFont(ofSize: 12)
    errorLabel.isHidden = true
    errorLabel.textColor = .secondaryLabelColor
    errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
    cancelButton.title = "取消"
    cancelButton.target = self
    cancelButton.action = #selector(cancel(_:))
    cancelButton.keyEquivalent = "\u{1b}"
    let restoreButton = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefaults(_:)))
    saveButton.title = "保存"
    saveButton.target = self
    saveButton.action = #selector(save(_:))
    saveButton.keyEquivalent = "\r"
    let stack = SettingsForm.column([
      instructions, SettingsForm.group(rows), errorLabel,
      SettingsForm.actions([restoreButton, cancelButton, saveButton]),
    ], spacing: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    formView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: formView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: formView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: formView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: formView.bottomAnchor, constant: -20),
    ])
  }

  /// Reuses the existing editor and validation without letting it close its settings host.
  func makeEmbeddedView(
    validateAndSave: @escaping (CaptureShortcut, CaptureShortcut, CaptureShortcut) -> String?,
    onRecordingChange: @escaping (Bool) -> Void = { _ in }
  ) -> NSView {
    isEmbedded = true
    self.onRecordingChange = onRecordingChange
    self.validateAndSave = validateAndSave
    cancelButton.title = "还原更改"
    instructions.stringValue = "点按快捷键输入框，再按新的组合键。按 Esc 还原更改，按回车保存。"
    // Embedded shortcuts only handle Return/Esc while the recorder has focus.
    cancelButton.keyEquivalent = ""
    saveButton.keyEquivalent = ""
    panel.contentView = NSView()
    return formView
  }

  private func setStatus(_ message: String, error: Bool = false) {
    errorLabel.stringValue = message
    errorLabel.isHidden = message.isEmpty
    errorLabel.textColor = error ? .systemRed : .secondaryLabelColor
  }

  func present(
    validateAndSave: @escaping (CaptureShortcut, CaptureShortcut, CaptureShortcut) -> String?,
    onClose: @escaping () -> Void = {}
  ) {
    self.validateAndSave = validateAndSave
    self.onClose = onClose
    show()
  }

  func show() {
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(screenshotRecorder)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancel(nil)
    return false
  }

  @objc private func selectPreset(_ sender: NSButton) {
    screenshotRecorder.shortcut = CaptureShortcut.screenshotPresets[sender.tag]
    setStatus("")
  }

  @objc private func restoreDefaults(_ sender: Any?) {
    selectionRecorder.shortcut = .defaultSelection
    screenshotRecorder.shortcut = .defaultScreenshot
    questionScreenshotRecorder.shortcut = .defaultQuestionScreenshot
    setStatus("")
  }

  @objc private func cancel(_ sender: Any?) {
    guard isEmbedded else { dismiss(); return }
    selectionRecorder.shortcut = savedShortcuts.0
    screenshotRecorder.shortcut = savedShortcuts.1
    questionScreenshotRecorder.shortcut = savedShortcuts.2
    setStatus("")
  }

  private func dismiss() {
    panel.close()
    validateAndSave = nil
    let completion = onClose
    onClose = nil
    completion?()
  }

  @objc private func save(_ sender: Any?) {
    let selection = selectionRecorder.shortcut
    let screenshot = screenshotRecorder.shortcut
    let questionScreenshot = questionScreenshotRecorder.shortcut
    if let error = CaptureShortcut.validationError(
      selection: selection, screenshot: screenshot, questionScreenshot: questionScreenshot)
      ?? validateAndSave?(selection, screenshot, questionScreenshot)
    {
      setStatus(error, error: true)
      return
    }
    savedShortcuts = (selection, screenshot, questionScreenshot)
    if isEmbedded {
      setStatus("快捷键已保存。")
    } else {
      dismiss()
    }
  }
}

private final class CaptureShortcutRecorder: NSView {
  var shortcut: CaptureShortcut {
    didSet {
      needsDisplay = true
      setAccessibilityValue(shortcut.title)
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }
  var onFocusChange: ((Bool) -> Void)?
  var onSave: (() -> Void)?
  var onCancel: (() -> Void)?
  var onError: ((String) -> Void)?
  var onChange: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }

  init(initial: CaptureShortcut) {
    shortcut = initial
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.textField)
    setAccessibilityValue(initial.title)
  }
  required init?(coder: NSCoder) { nil }
  override func accessibilityPerformPress() -> Bool {
    window?.makeFirstResponder(self) ?? false
  }
  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    onFocusChange?(true)
    return true
  }
  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    onFocusChange?(false)
    return true
  }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      onCancel?()
      return
    }
    if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
      onSave?()
      return
    }
    if event.keyCode == UInt16(kVK_Tab) {
      super.keyDown(with: event)
      return
    }
    guard
      let recorded = CaptureShortcut.recorded(
        keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
    else {
      onError?("请按包含 ⌘、⌥ 或 ⌃ 的组合键。Esc 和回车用于取消和保存。")
      return
    }
    shortcut = recorded
    onChange?()
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return false }
    keyDown(with: event)
    return true
  }
  override func draw(_ dirtyRect: NSRect) {
    let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    NSColor.controlBackgroundColor.setFill()
    box.fill()
    (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor)
      .setStroke()
    box.lineWidth = 2
    box.stroke()
    let label = shortcut.title as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor,
    ]
    let size = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: 12, y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }
}
