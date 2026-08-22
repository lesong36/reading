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
  private var ocrHotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var mouseEventTap: CFMachPort?
  private var mouseEventSource: CFRunLoopSource?
  private var recentEntriesPanel: NSPanel?
  private var screenshotProcess: Process?
  private var lastLeftMouseDown: CFAbsoluteTime?
  private var lastRightMouseDown: CFAbsoluteTime?
  private let configurationKey = "VocabCapture.aiConfiguration"
  private let shortcutKey = "VocabCapture.shortcut"
  private let customShortcutKey = "VocabCapture.customShortcut"
  private let mouseChordEnabledKey = "VocabCapture.mouseChordEnabled"
  private let lastSyncedAtKey = "VocabCapture.lastSyncedAt"
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
    let hint = menu.addItem(withTitle: "选中英文后：\(currentShortcut.title) 或鼠标左右键一起按", action: nil, keyEquivalent: "")
    hint.isEnabled = false
    menu.addItem(.separator())
    menu.addItem(withTitle: "拾取当前选词  \(currentShortcut.title)", action: #selector(captureSelectionAction), keyEquivalent: "")
    menu.addItem(withTitle: "截图 OCR 取词  ⌥⌘O", action: #selector(captureScreenTextAction), keyEquivalent: "")
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
        showFailure(
          title: "需要辅助功能权限",
          "请到“系统设置 → 隐私与安全性 → 辅助功能”，打开“拾词助手”的开关；然后退出并重新打开本应用。未授权时可先复制单词，再按 \(currentShortcut.title)。"
        )
        return
      }
      showFailure(
        title: "没有读到选词",
        "请先选中英文单词或短语。若该 App 不支持读取选区，可先复制单词后再按 \(currentShortcut.title)。"
      )
      return
    }
    capture(selection)
  }

  private func requestAccessibilityPermission() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  @objc private func captureScreenTextAction() {
    captureNativeRegion { [weak self] image in self?.recognizeOCRWord(image) }
  }

  private func captureNativeRegion(completion: @escaping (CGImage) -> Void) {
    guard screenshotProcess == nil else { return }
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-ocr-\(UUID().uuidString).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-o", "-t", "png", fileURL.path]
    process.terminationHandler = { [weak self] finished in
      defer { try? FileManager.default.removeItem(at: fileURL) }
      guard finished.terminationStatus == 0,
            let image = NSImage(contentsOf: fileURL),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        DispatchQueue.main.async { self?.screenshotProcess = nil }
        return
      }
      DispatchQueue.main.async {
        self?.screenshotProcess = nil
        completion(cgImage)
      }
    }
    do {
      try process.run()
      screenshotProcess = process
      setStatus("词 ···")
    } catch {
      showFailure(title: "无法启动截图", error.localizedDescription)
    }
  }

  private func recognizeOCRWord(_ image: CGImage) {
    setStatus("词 ···")
    Task {
      do {
        let recognizedText = try await OCRClient.recognize(image)
        guard let words = await MainActor.run(body: { self.chooseOCRWords(recognizedText) }) else {
          await MainActor.run { self.setStatus("词") }
          return
        }
        await MainActor.run { self.captureOCRWords(words, context: recognizedText) }
      } catch {
        await MainActor.run { self.showFailure(title: "OCR 识别失败", error.localizedDescription) }
      }
    }
  }

  private func chooseOCRWords(_ recognizedText: String) -> [String]? {
    let words = OCRWordPickerView.words(from: recognizedText)
    guard !words.isEmpty else {
      showFailure(title: "没有识别到英文单词", "请框选更清晰的英文段落后重试。")
      return nil
    }
    let alert = NSAlert()
    alert.messageText = "选择要加入的单词"
    alert.informativeText = "可一次勾选多个词；它们将共用这次截图识别出的段落语境。"
    let picker = OCRWordPickerView(words: words)
    alert.accessoryView = picker
    alert.addButton(withTitle: "翻译并加入")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    guard !picker.selectedWords.isEmpty else {
      showFailure(title: "还没有选择单词", "请勾选至少一个英文单词。")
      return nil
    }
    return picker.selectedWords
  }

  private func captureOCRWords(_ words: [String], context: String) {
    setStatus("词 ···")
    Task {
      var added: [VocabularyEntry] = []
      var failures = 0
      for word in words {
        do {
          let selection = SelectedText(word: word, context: context)
          let result = try await dictionary.lookup(selection, configuration: configuration)
          added.append(try await store.add(word: word, dictionary: result, context: context))
        } catch {
          failures += 1
        }
      }
      guard !added.isEmpty else {
        await MainActor.run { self.showFailure(title: "没有加入单词", "请检查 AI 服务设置后重试。") }
        return
      }
      let addedCount = added.count
      let failureCount = failures
      do {
        let result = try await syncVocabulary()
        await MainActor.run {
          let suffix = failureCount == 0 ? "" : "；\(failureCount) 个未完成"
          self.show("已同步到阅读达人", "已加入 \(addedCount) 个单词；本次新增/更新 \(result.uploadedCount) 个，云端共 \(result.totalCount) 个\(suffix)")
        }
      } catch SupabaseSyncError.notLoggedIn {
        await MainActor.run { self.show("已加入本机生词本", "已加入 \(addedCount) 个单词；登录后可同步到阅读达人") }
      } catch {
        await MainActor.run { self.show("已加入本机，云同步失败", error.localizedDescription) }
      }
    }
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
    setStatus("词 ···")
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
          self.showFailure(title: "查词失败", error.localizedDescription)
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

  private func showFailure(title: String = "没有加入生词本", _ message: String) {
    setStatus("词 !")
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
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
      let entries = Array((await store.all()).prefix(12))
      let isLoggedIn = await cloudSync.isLoggedIn()
      await MainActor.run {
        let alert = NSAlert()
        alert.messageText = "最近加入的单词"
        let list = entries.isEmpty
          ? "还没有加入任何单词。"
          : entries.map { "\($0.word) · \($0.meaning)" }.joined(separator: "\n")
        alert.informativeText = self.syncDescription(isLoggedIn: isLoggedIn) + "\n\n" + list
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
          await MainActor.run { self.showFailure(title: "同步失败", error.localizedDescription) }
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
        await MainActor.run { self.showFailure(title: "登录或同步失败", error.localizedDescription) }
      }
    }
  }

  private func syncVocabulary() async throws -> (uploadedCount: Int, totalCount: Int) {
    let local = await store.all()
    let result = try await cloudSync.sync(local: local)
    try await store.replace(with: result.vocabulary)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncedAtKey)
    return (result.uploadedCount, result.vocabulary.count)
  }

  private func syncDescription(isLoggedIn: Bool) -> String {
    guard isLoggedIn else { return "仅保存在本机 · 登录阅读达人后可同步" }
    guard UserDefaults.standard.object(forKey: lastSyncedAtKey) != nil else { return "已登录阅读达人 · 尚未手动同步" }
    let time = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastSyncedAtKey))
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "已同步阅读达人 · 上次同步 \(formatter.string(from: time))"
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
    InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
      let delegate = Unmanaged<AppDelegate>.fromOpaque(data!).takeUnretainedValue()
      var hotKeyID = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      hotKeyID.id == 2 ? delegate.captureScreenTextAction() : delegate.captureSelectionAction()
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
    if let ocrHotKeyRef {
      UnregisterEventHotKey(ocrHotKeyRef)
      self.ocrHotKeyRef = nil
    }
    let ocrID = EventHotKeyID(signature: OSType(0x56434150), id: 2)
    RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(optionKey | cmdKey), ocrID, GetApplicationEventTarget(), 0, &ocrHotKeyRef)
  }

  private func show(_ title: String, _ message: String) {
    let failures = ["失败", "未加入", "需要", "未找到"]
    setStatus(failures.contains(where: title.contains) ? "词 !" : "词 ✓")
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

  private func setStatus(_ value: String) {
    statusItem.button?.title = value
    guard value != "词" else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard self?.statusItem.button?.title == value else { return }
      self?.statusItem.button?.title = "词"
    }
  }

  func applicationWillTerminate(_ notification: Notification) { stopMouseChord() }
}

private final class OCRWordPickerView: NSView {
  private var buttons: [NSButton] = []
  var selectedWords: [String] { buttons.filter { $0.state == .on }.map(\.title) }

  init(words: [String]) {
    let columns = 3
    let rowHeight: CGFloat = 28
    let rows = Int(ceil(Double(words.count) / Double(columns)))
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: CGFloat(rows) * rowHeight))
    for (index, word) in words.enumerated() {
      let column = index % columns
      let row = index / columns
      let button = NSButton(checkboxWithTitle: word, target: nil, action: nil)
      button.frame = NSRect(x: CGFloat(column) * 130, y: CGFloat(rows - row - 1) * rowHeight, width: 126, height: rowHeight)
      button.font = .systemFont(ofSize: 13)
      addSubview(button)
      buttons.append(button)
    }
  }

  required init?(coder: NSCoder) { nil }

  static func words(from text: String) -> [String] {
    let range = NSRange(text.startIndex..., in: text)
    guard let expression = try? NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)?") else { return [] }
    var seen = Set<String>()
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      let word = String(text[range])
      guard word.count > 1, seen.insert(word.lowercased()).inserted else { return nil }
      return word
    }.prefix(42).map { $0 }
  }
}

private final class RecentVocabularyViewController: NSViewController {
  private let entries: [VocabularyEntry]
  private let syncDescription: String

  init(entries: [VocabularyEntry], syncDescription: String) {
    self.entries = entries
    self.syncDescription = syncDescription
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    let title = makeLabel("最近加入", font: .systemFont(ofSize: 22, weight: .semibold), color: .labelColor)
    let subtitle = makeLabel(syncDescription, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder

    let list = RecentVocabularyListView(entries: entries, width: 508)
    list.autoresizingMask = [.width]
    scroll.documentView = list

    for view in [title, subtitle, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
    ])
    view = root
  }

  private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = color
    label.maximumNumberOfLines = 0
    return label
  }

}

private final class RecentVocabularyListView: NSView {
  private let entries: [VocabularyEntry]
  private var cards: [(entry: VocabularyEntry, rect: NSRect)] = []
  private var layoutWidth: CGFloat = 0

  override var isFlipped: Bool { true }

  init(entries: [VocabularyEntry], width: CGFloat) {
    self.entries = entries
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    rebuildLayout(width: width)
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    if abs(bounds.width - layoutWidth) > 1 { rebuildLayout(width: bounds.width) }
  }

  private func rebuildLayout(width: CGFloat) {
    layoutWidth = max(width, 280)
    let cardWidth = layoutWidth - 4
    var y: CGFloat = 2
    cards = entries.map { entry in
      let height = cardHeight(for: entry, width: cardWidth)
      defer { y += height + 12 }
      return (entry, NSRect(x: 2, y: y, width: cardWidth, height: height))
    }
    if entries.isEmpty { y += 110 }
    setFrameSize(NSSize(width: layoutWidth, height: max(y, 1)))
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if entries.isEmpty {
      drawText("还没有加入单词。选中英文后，按快捷键或鼠标左右键一起按即可开始。", in: NSRect(x: 18, y: 28, width: bounds.width - 36, height: 54), font: .systemFont(ofSize: 15), color: .secondaryLabelColor)
      return
    }
    for card in cards where dirtyRect.intersects(card.rect) { drawCard(card.entry, in: card.rect) }
  }

  private func drawCard(_ entry: VocabularyEntry, in rect: NSRect) {
    let background = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
    NSColor.controlBackgroundColor.setFill()
    background.fill()
    NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
    background.lineWidth = 1
    background.stroke()

    let inset = rect.insetBy(dx: 20, dy: 18)
    var y = inset.minY
    let wordHeight = drawText(entry.word, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 32), font: .systemFont(ofSize: 25, weight: .semibold), color: .labelColor)
    y += wordHeight + 4
    let detail = [entry.partOfSpeech, entry.pronunciation].filter { !$0.isEmpty }.joined(separator: " · ")
    if !detail.isEmpty {
      let detailHeight = drawText(detail, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 22), font: .systemFont(ofSize: 13, weight: .medium), color: .systemIndigo)
      y += detailHeight + 10
    } else { y += 8 }
    let meaningHeight = drawText(entry.meaning, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 46), font: .systemFont(ofSize: 17, weight: .medium), color: .labelColor)
    y += meaningHeight + 16
    let contextLabel = drawText("来自文章语境", in: NSRect(x: inset.minX, y: y, width: inset.width, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .tertiaryLabelColor)
    y += contextLabel + 5
    let sentence = entry.sourceContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.exampleSentence : entry.sourceContext
    let sentenceText = sentence.isEmpty ? "未读取到完整原句" : sentence
    let sentenceHeight = drawText(sentenceText, in: NSRect(x: inset.minX, y: y, width: inset.width, height: rect.maxY - y - 34), font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
    y += sentenceHeight + 14
    drawText("加入于 \(formattedDate(entry))", in: NSRect(x: inset.minX, y: y, width: inset.width, height: 18), font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
  }

  private func cardHeight(for entry: VocabularyEntry, width: CGFloat) -> CGFloat {
    let textWidth = width - 40
    let detail = [entry.partOfSpeech, entry.pronunciation].filter { !$0.isEmpty }.joined(separator: " · ")
    let sentence = entry.sourceContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.exampleSentence : entry.sourceContext
    return 36
      + measuredHeight(entry.word, width: textWidth, font: .systemFont(ofSize: 25, weight: .semibold))
      + (detail.isEmpty ? 8 : 27)
      + measuredHeight(entry.meaning, width: textWidth, font: .systemFont(ofSize: 17, weight: .medium))
      + 34
      + measuredHeight(sentence.isEmpty ? "未读取到完整原句" : sentence, width: textWidth, font: .systemFont(ofSize: 14))
      + 32
  }

  @discardableResult
  private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) -> CGFloat {
    let height = measuredHeight(text, width: rect.width, font: font)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    NSAttributedString(string: text, attributes: attributes).draw(with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return height
  }

  private func measuredHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let size = NSAttributedString(string: text, attributes: attributes).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    return ceil(size.height)
  }

  private func formattedDate(_ entry: VocabularyEntry) -> String {
    if let date = ISO8601DateFormatter().date(from: entry.addedAt) {
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      formatter.timeStyle = .short
      return formatter.string(from: date)
    }
    return entry.addedAt.isEmpty ? "刚刚" : entry.addedAt
  }
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
