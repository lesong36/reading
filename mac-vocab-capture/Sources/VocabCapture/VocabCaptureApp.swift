import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
  private struct ShortcutDefinition {
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
  private let configurationKey = "VocabCapture.aiConfiguration"
  private let shortcutKey = "VocabCapture.shortcut"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.servicesProvider = self
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "词"
    statusItem.menu = makeMenu()
    installHotKeyHandler()
    registerHotKey()
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "拾取当前选词  \(currentShortcut.title)", action: #selector(captureSelectionAction), keyEquivalent: "")
    menu.addItem(withTitle: "查看最近加入的单词", action: #selector(showRecentEntries), keyEquivalent: "")
    menu.addItem(withTitle: "同步到阅读达人…", action: #selector(syncToReader), keyEquivalent: "")
    menu.addItem(.separator())
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
          let total = try await self.syncVocabulary()
          await MainActor.run { self.show("已同步到阅读达人", "\(entry.word) · \(entry.meaning)；共 \(total) 个生词") }
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
          let total = try await syncVocabulary()
          await MainActor.run { self.show("已同步到阅读达人", "云端共有 \(total) 个生词") }
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
        let total = try await syncVocabulary()
        await MainActor.run { self.show("已登录并同步", "阅读达人云端共有 \(total) 个生词") }
      } catch {
        await MainActor.run { self.showFailure("登录或同步失败：\(error.localizedDescription)") }
      }
    }
  }

  private func syncVocabulary() async throws -> Int {
    let local = await store.all()
    let merged = try await cloudSync.sync(local: local)
    try await store.replace(with: merged)
    return merged.count
  }

  @objc private func openShortcutSettings() {
    let alert = NSAlert()
    alert.messageText = "设置拾词快捷键"
    alert.informativeText = "选中英文单词后，按此组合键进行语境查词。"
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 230, height: 28), pullsDown: false)
    picker.addItems(withTitles: shortcuts.map(\.title))
    picker.selectItem(at: shortcuts.firstIndex(where: { $0.id == currentShortcut.id }) ?? 0)
    alert.accessoryView = picker
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn,
          let selected = shortcuts[safe: picker.indexOfSelectedItem] else { return }
    UserDefaults.standard.set(selected.id, forKey: shortcutKey)
    registerHotKey()
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
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    let shortcut = currentShortcut
    let id = EventHotKeyID(signature: OSType(0x56434150), id: 1)
    RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  private func show(_ title: String, _ message: String) {
    statusItem.button?.title = title == "已按原句翻译并加入" ? "词 ✓" : "词 !"
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
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
