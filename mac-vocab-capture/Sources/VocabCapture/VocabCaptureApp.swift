import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
  fileprivate struct ShortcutDefinition: Codable {
    let id: String
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
  }

  private let shortcuts = [
    ShortcutDefinition(id: "option-command-d", title: "⌥⌘D（默认）", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | cmdKey)),
    ShortcutDefinition(id: "control-option-d", title: "⌃⌥D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)),
    ShortcutDefinition(id: "control-option-w", title: "⌃⌥W", keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey))
  ]
  private let store = VocabularyStore()
  private let dictionary = DictionaryClient()
  private let cloudSync = SupabaseVocabularySync()
  private var statusItem: NSStatusItem!
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var mouseEventTap: CFMachPort?
  private var mouseEventSource: CFRunLoopSource?
  private var lastLeftMouseDown: CFAbsoluteTime?
  private var lastRightMouseDown: CFAbsoluteTime?
  private let configurationKey = "VocabCapture.aiConfiguration"
  private let shortcutKey = "VocabCapture.shortcut"
  private let customShortcutKey = "VocabCapture.customShortcut"
  private let mouseChordEnabledKey = "VocabCapture.mouseChordEnabled"
  private let mouseChordInterval: CFAbsoluteTime = 0.22

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.servicesProvider = self
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "词"
    statusItem.menu = makeMenu()
    installHotKeyHandler()
    registerHotKey()
    installMouseChordIfNeeded()
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "拾取当前选词  \(currentShortcut.title)", action: #selector(captureSelectionAction), keyEquivalent: "")
    menu.addItem(withTitle: "查看最近加入的单词", action: #selector(showRecentEntries), keyEquivalent: "")
    menu.addItem(withTitle: "同步到阅读达人…", action: #selector(syncToReader), keyEquivalent: "")
    menu.addItem(.separator())
    let mouseChordItem = menu.addItem(withTitle: "鼠标左右键同时按下拾词", action: #selector(toggleMouseChord), keyEquivalent: "")
    mouseChordItem.state = mouseChordEnabled ? .on : .off
    menu.addItem(withTitle: "设置拾词快捷键…", action: #selector(openShortcutSettings), keyEquivalent: "")
    menu.addItem(withTitle: "AI 设置…", action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出拾词助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
  }

  @objc func captureSelectionAction() {
    let selection: SelectedText?
    if AXIsProcessTrusted() {
      selection = SelectionReader.read()
    } else {
      requestAccessibilityPermission()
      selection = SelectionReader.fromServicePasteboard(.general)
    }
    guard let selection else {
      if !AXIsProcessTrusted() {
        show("需要辅助功能权限", "请在系统设置中允许拾词助手读取当前选词。")
        showFailure("请到“系统设置 → 隐私与安全性 → 辅助功能”，打开“拾词助手”的开关；然后退出并重新打开本应用。未授权时可先复制单词，再按 ⌥⌘D。")
        return
      }
      show("未找到英文选词", "请先选择一个英文单词或短语。")
      showFailure("没有读取到当前选词。请确认先选中英文单词；若该 App 不支持读取选区，可先复制单词后再按 ⌥⌘D。")
      return
    }
    capture(selection)
  }

  private func requestAccessibilityPermission() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  @objc private func toggleMouseChord() {
    UserDefaults.standard.set(!mouseChordEnabled, forKey: mouseChordEnabledKey)
    if mouseChordEnabled {
      installMouseChordIfNeeded()
    } else {
      stopMouseChord()
    }
    statusItem.menu = makeMenu()
  }

  private var mouseChordEnabled: Bool {
    guard UserDefaults.standard.object(forKey: mouseChordEnabledKey) != nil else { return true }
    return UserDefaults.standard.bool(forKey: mouseChordEnabledKey)
  }

  private func installMouseChordIfNeeded() {
    guard mouseChordEnabled, AXIsProcessTrusted(), mouseEventTap == nil else { return }
    let eventMask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      if let userInfo, type == .leftMouseDown || type == .rightMouseDown {
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        delegate.handleMouseDown(type)
      }
      return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: eventMask,
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    mouseEventTap = tap
    mouseEventSource = source
  }

  private func stopMouseChord() {
    guard let source = mouseEventSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    mouseEventTap = nil
    mouseEventSource = nil
    lastLeftMouseDown = nil
    lastRightMouseDown = nil
  }

  private func handleMouseDown(_ type: CGEventType) {
    guard mouseChordEnabled, NSApp.modalWindow == nil else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if type == .leftMouseDown {
      lastLeftMouseDown = now
      guard let right = lastRightMouseDown, now - right <= mouseChordInterval else { return }
    } else {
      lastRightMouseDown = now
      guard let left = lastLeftMouseDown, now - left <= mouseChordInterval else { return }
    }
    lastLeftMouseDown = nil
    lastRightMouseDown = nil
    // The chord's first click can collapse a selection in the target app.
    // Read it before this passive event is delivered to that app.
    captureSelectionAction()
  }

  private func capture(_ selection: SelectedText) {
    Task {
      do {
        let result = try await dictionary.lookup(selection, configuration: configuration)
        let shouldAdd = await MainActor.run { self.confirmAdd(selection: selection, dictionary: result) }
        guard shouldAdd else {
          await MainActor.run { self.show("未加入生词本", "已取消：\(selection.word)") }
          return
        }
        let entry = try await store.add(word: selection.word, dictionary: result, context: selection.context)
        do {
          let result = try await self.syncVocabulary()
          await MainActor.run {
            self.show("已同步到阅读达人", "\(entry.word) · \(entry.meaning)；本次新增/更新 \(result.uploadedCount) 个，云端共 \(result.totalCount) 个")
          }
        } catch SupabaseSyncError.notLoggedIn {
          await MainActor.run { self.show("已加入本机生词本", "\(entry.word) · \(entry.meaning)；登录后可同步到阅读达人") }
        } catch {
          await MainActor.run { self.show("已加入本机，云同步失败", error.localizedDescription) }
        }
      } catch {
        await MainActor.run {
          self.show("查词失败", error.localizedDescription)
          self.showFailure(error.localizedDescription)
        }
      }
    }
  }

  private func confirmAdd(selection: SelectedText, dictionary: DictionaryResult) -> Bool {
    let alert = NSAlert()
    alert.messageText = "原句中的 “\(selection.word)”"
    let details = [
      "含义：\(dictionary.meaning)",
      dictionary.partOfSpeech.isEmpty ? nil : "词性：\(dictionary.partOfSpeech)",
      dictionary.pronunciation.isEmpty ? nil : "发音：\(dictionary.pronunciation)",
      dictionary.note.isEmpty ? nil : "说明：\(dictionary.note)",
      "原句：\(selection.context)"
    ].compactMap { $0 }.joined(separator: "\n")
    alert.informativeText = details
    alert.addButton(withTitle: "加入生词本")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func showFailure(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "没有加入生词本"
    alert.informativeText = message
    alert.addButton(withTitle: "知道了")
    alert.runModal()
  }

  /// Entry point advertised as a macOS Service in the app target's Info.plist.
  @objc func captureSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    guard let selection = SelectionReader.fromServicePasteboard(pasteboard) else {
      error.pointee = "请在支持服务菜单的 App 中选择英文单词或短语。"
      return
    }
    capture(selection)
  }

  @objc private func openSettings() {
    let alert = NSAlert()
    alert.messageText = "AI 服务设置"
    alert.informativeText = "填入 OpenAI 兼容接口。API Key 仅保存在本机 Keychain。"
    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 204))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    let base = NSTextField(string: configuration.baseURL)
    let model = NSTextField(string: configuration.model)
    let key = NSSecureTextField(string: configuration.apiKey)
    for (label, field) in [("Base URL", base), ("Model", model), ("API Key", key)] {
      stack.addArrangedSubview(NSTextField(labelWithString: label))
      field.widthAnchor.constraint(equalToConstant: 420).isActive = true
      field.heightAnchor.constraint(equalToConstant: 26).isActive = true
      stack.addArrangedSubview(field)
    }
    alert.accessoryView = stack
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try KeychainStore.saveAPIKey(key.stringValue)
      configuration = AIConfiguration(baseURL: base.stringValue, model: model.stringValue, apiKey: key.stringValue)
    } catch { show("无法保存 API Key", error.localizedDescription) }
  }

  @objc private func showRecentEntries() {
    Task {
      let entries = await store.all().prefix(10)
      let body = entries.isEmpty
        ? "还没有加入任何单词。"
        : entries.map { "\($0.word) · \($0.meaning)" }.joined(separator: "\n")
      await MainActor.run {
        let alert = NSAlert()
        alert.messageText = "最近加入的单词"
        alert.informativeText = body
        alert.addButton(withTitle: "关闭")
        alert.runModal()
      }
    }
  }

  @objc private func syncToReader() {
    Task {
      if await cloudSync.isLoggedIn() {
        do {
          let result = try await syncVocabulary()
          await MainActor.run { self.show("同步完成", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个") }
        } catch {
          await MainActor.run { self.showFailure("同步失败：\(error.localizedDescription)") }
        }
      } else {
        await MainActor.run { self.openSupabaseLogin() }
      }
    }
  }

  private func openSupabaseLogin() {
    let alert = NSAlert()
    alert.messageText = "登录阅读达人账号"
    alert.informativeText = "使用与阅读达人相同的邮箱和密码。密码不会保存在拾词助手中。"
    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 112))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    let email = NSTextField()
    let password = NSSecureTextField()
    for (label, field) in [("邮箱", email), ("密码", password)] {
      stack.addArrangedSubview(NSTextField(labelWithString: label))
      field.widthAnchor.constraint(equalToConstant: 380).isActive = true
      field.heightAnchor.constraint(equalToConstant: 26).isActive = true
      stack.addArrangedSubview(field)
    }
    alert.accessoryView = stack
    alert.addButton(withTitle: "登录并同步")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      do {
        _ = try await cloudSync.signIn(email: email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password: password.stringValue)
        let result = try await syncVocabulary()
        await MainActor.run { self.show("已登录并同步", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个") }
      } catch {
        await MainActor.run { self.showFailure("登录或同步失败：\(error.localizedDescription)") }
      }
    }
  }

  private func syncVocabulary() async throws -> (uploadedCount: Int, totalCount: Int) {
    let local = await store.all()
    let result = try await cloudSync.sync(local: local)
    try await store.replace(with: result.vocabulary)
    return (result.uploadedCount, result.vocabulary.count)
  }

  @objc private func openShortcutSettings() {
    let alert = NSAlert()
    alert.messageText = "设置拾词快捷键"
    alert.informativeText = "点下方输入框后，直接按下你希望使用的组合键。建议至少包含 ⌘、⌥ 或 ⌃。"
    let recorder = ShortcutRecorderView(initial: currentShortcut)
    alert.accessoryView = recorder
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    DispatchQueue.main.async { alert.window.makeFirstResponder(recorder) }
    let response = alert.runModal()
    defer { registerHotKey() }
    guard response == .alertFirstButtonReturn, let selected = recorder.shortcut else { return }
    UserDefaults.standard.set(try? JSONEncoder().encode(selected), forKey: customShortcutKey)
    statusItem.menu = makeMenu()
  }

  private var configuration: AIConfiguration {
    get {
      let saved = try? JSONDecoder().decode(AIConfiguration.self, from: UserDefaults.standard.data(forKey: configurationKey) ?? Data())
      return AIConfiguration(baseURL: saved?.baseURL ?? "", model: saved?.model ?? "", apiKey: KeychainStore.readAPIKey())
    }
    set {
      let nonSecret = AIConfiguration(baseURL: newValue.baseURL, model: newValue.model, apiKey: "")
      UserDefaults.standard.set(try? JSONEncoder().encode(nonSecret), forKey: configurationKey)
    }
  }

  private var currentShortcut: ShortcutDefinition {
    if let data = UserDefaults.standard.data(forKey: customShortcutKey),
       let custom = try? JSONDecoder().decode(ShortcutDefinition.self, from: data) {
      return custom
    }
    let savedID = UserDefaults.standard.string(forKey: shortcutKey)
    return shortcuts.first(where: { $0.id == savedID }) ?? shortcuts[0]
  }

  private func installHotKeyHandler() {
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
      let delegate = Unmanaged<AppDelegate>.fromOpaque(data!).takeUnretainedValue()
      delegate.captureSelectionAction()
      return noErr
    }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
  }

  private func registerHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    let shortcut = currentShortcut
    let id = EventHotKeyID(signature: OSType(0x56434150), id: 1)
    RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  private func show(_ title: String, _ message: String) {
    let failures = ["失败", "未加入", "需要", "未找到"]
    statusItem.button?.title = failures.contains(where: title.contains) ? "词 !" : "词 ✓"
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.statusItem.button?.title = "词" }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = message
      let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
      center.add(request)
    }
  }

  func applicationWillTerminate(_ notification: Notification) { stopMouseChord() }
}

private final class ShortcutRecorderView: NSView {
  private let valueLabel = NSTextField(labelWithString: "")
  private(set) var shortcut: AppDelegate.ShortcutDefinition?

  init(initial: AppDelegate.ShortcutDefinition) {
    shortcut = initial
    super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 42))
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.separatorColor.cgColor
    valueLabel.frame = bounds.insetBy(dx: 12, dy: 9)
    valueLabel.font = .systemFont(ofSize: 16, weight: .medium)
    addSubview(valueLabel)
    updateLabel()
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool {
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    return true
  }
  override func resignFirstResponder() -> Bool {
    layer?.borderColor = NSColor.separatorColor.cgColor
    return true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(NSEvent.ModifierFlags.deviceIndependentFlagsMask)
    let carbonModifiers = (flags.contains(NSEvent.ModifierFlags.command) ? UInt32(cmdKey) : 0)
      | (flags.contains(NSEvent.ModifierFlags.option) ? UInt32(optionKey) : 0)
      | (flags.contains(NSEvent.ModifierFlags.control) ? UInt32(controlKey) : 0)
      | (flags.contains(NSEvent.ModifierFlags.shift) ? UInt32(shiftKey) : 0)
    guard carbonModifiers != 0,
          let character = event.charactersIgnoringModifiers?.uppercased(), !character.isEmpty else {
      NSSound.beep()
      return
    }
    let title = (flags.contains(NSEvent.ModifierFlags.control) ? "⌃" : "")
      + (flags.contains(NSEvent.ModifierFlags.option) ? "⌥" : "")
      + (flags.contains(NSEvent.ModifierFlags.shift) ? "⇧" : "")
      + (flags.contains(NSEvent.ModifierFlags.command) ? "⌘" : "")
      + character
    shortcut = AppDelegate.ShortcutDefinition(
      id: "custom-\(event.keyCode)-\(carbonModifiers)",
      title: title,
      keyCode: UInt32(event.keyCode),
      modifiers: carbonModifiers
    )
    updateLabel()
  }

  private func updateLabel() { valueLabel.stringValue = shortcut?.title ?? "按下新的组合键" }
}
