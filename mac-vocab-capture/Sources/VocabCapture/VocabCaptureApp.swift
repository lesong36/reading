import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let shortcutPreferences: ShortcutPreferences
  private var shortcutSettings: CaptureShortcutSettings?
  private let store: VocabularyStore
  private let dictionary: DictionaryClient
  private let defaults: UserDefaults
  private let readDictionaryKey: () -> String
  private let saveDictionaryKey: (String) throws -> Void
  private let browserBridge: BrowserContextBridge
  private let regionCapture: ScreenshotRegionCapture
  private let screenshotQuestions = ScreenshotQuestionClient()
  private let questionPreferences: ScreenshotQuestionPreferences
  private let searchPreferences: ScreenshotQuestionWebSearchPreferences
  private var webSearchSettings: ScreenshotQuestionWebSearchSettings?
  private var questionModelSettings: ScreenshotQuestionModelSettings?
  private let cloudSync: SupabaseVocabularySync
  private var isOpeningCloudSync = false
  private var statusItem: NSStatusItem!
  private(set) var pendingOpenURLs: [URL] = []
  private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
  private var hotKeyHandler: EventHandlerRef?
  private var mouseEventTap: CFMachPort?
  private var mouseEventSource: CFRunLoopSource?
  private var screenshotTask: Task<Void, Never>?
  private(set) var ocrPanel: OCRLookupPanel?
  private(set) var directQuestionPanel: ScreenshotQuestionPanel?

  enum ScreenshotDestination { case word, question }
  private var selectionLookupTask: Task<Void, Never>?
  private(set) var selectionPreview: DefinitionPreviewPanel?
  private var selectionLookupID = UUID()
  private var selectionReadTask: Task<Void, Never>?
  private var selectionReadID = UUID()
  private(set) var floatingReadTask: Task<Void, Never>?
  private(set) var floatingState = SelectionCaptureState()
  private var accountCaptureGeneration = UUID()
  private var displayedUserID: String?
  private var conflictingWordKeys: [String] = []
  private var syncStatusText = "本机词库 · 状态正在检查"
  private lazy var syncCoordinator = VocabularySyncCoordinator(
    store: store,
    currentUserID: { [cloudSync] in await cloudSync.currentUserID() },
    synchronize: { [cloudSync] batch in try await cloudSync.sync(batch: batch) },
    onStatus: { [weak self] status in self?.updateSyncStatus(status) })
  private var selectionDragStart: CGPoint?
  private var selectionDragProcessIdentifier: pid_t?
  private var applicationActivationObserver: NSObjectProtocol?
  private(set) var floatingSelectionPanel: NSPanel?
  private let configurationKey = "VocabCapture.aiConfiguration"
  private let floatingButtonEnabledKey = "VocabCapture.floatingButtonEnabled"
  private let minimumSelectionDragDistance: CGFloat = 4

  init(
    cloudSync: SupabaseVocabularySync = SupabaseVocabularySync(),
    store: VocabularyStore = VocabularyStore(),
    shortcutPreferences: ShortcutPreferences = ShortcutPreferences(),
    questionPreferences: ScreenshotQuestionPreferences = ScreenshotQuestionPreferences(),
    searchPreferences: ScreenshotQuestionWebSearchPreferences =
      ScreenshotQuestionWebSearchPreferences(),
    dictionary: DictionaryClient = DictionaryClient(),
    defaults: UserDefaults = .standard,
    readDictionaryKey: @escaping () -> String = { KeychainStore.readAPIKey() },
    saveDictionaryKey: @escaping (String) throws -> Void = { try KeychainStore.saveAPIKey($0) },
    browserBridge: BrowserContextBridge = .shared,
    regionCapture: ScreenshotRegionCapture? = nil
  ) {
    self.shortcutPreferences = shortcutPreferences
    self.questionPreferences = questionPreferences
    self.searchPreferences = searchPreferences
    self.cloudSync = cloudSync
    self.store = store
    self.dictionary = dictionary
    self.defaults = defaults
    self.readDictionaryKey = readDictionaryKey
    self.saveDictionaryKey = saveDictionaryKey
    self.browserBridge = browserBridge
    self.regionCapture = regionCapture ?? ScreenshotRegionCapture()
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    questionPreferences.prepareDefaultModel()
    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = ApplicationEditingMenu.make()
    NSApp.mainMenu?.addItem(makeModelSettingsMenu())
    NSApp.servicesProvider = self
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "词"
    statusItem.menu = makeMenu()
    installHotKeyHandler()
    registerHotKey()
    Task { await screenshotQuestions.warmUp() }
    installSelectionMonitorIfNeeded()
    browserBridge.start()
    Task { await syncCoordinator.start() }
    let urls = pendingOpenURLs
    pendingOpenURLs.removeAll()
    application(NSApp, open: urls)
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    // LaunchServices can deliver URLs before the status menu has been created.
    guard statusItem != nil else {
      pendingOpenURLs.append(contentsOf: urls)
      return
    }
    for url in urls {
      guard url.scheme == "vocabcapture", url.host == "capture",
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let word = components.queryItems?.first(where: { $0.name == "word" })?.value,
        let context = components.queryItems?.first(where: { $0.name == "context" })?.value,
        browserBridge.isAuthorizedCapture(token: components.queryItems?.first(where: { $0.name == "token" })?.value),
        let selection = SelectionReader.fromBrowserExtension(word: word, context: context)
      else { continue }
      ContextDebugLog.write("浏览器扩展提供的原句", word: selection.word, context: selection.context)
      capture(selection)
    }
  }

  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    let hint = menu.addItem(withTitle: "拾词助手 · 查词与截图问答", action: nil, keyEquivalent: "")
    hint.isEnabled = false
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "查选中词    \(currentShortcut.title)", action: #selector(captureSelectionAction),
      keyEquivalent: ""
    ).target = self
    menu.addItem(
      withTitle: "截图取词    \(currentScreenshotShortcut.title)",
      action: #selector(captureScreenTextAction), keyEquivalent: ""
    ).target = self
    menu.addItem(makeScreenshotQuestionItem())
    menu.addItem(.separator())
    menu.addItem(withTitle: "最近加入的单词", action: #selector(showRecentEntries), keyEquivalent: "")
      .target = self
    let syncItem = menu.addItem(
      withTitle: "同步到阅读达人…", action: #selector(syncToReader), keyEquivalent: "")
    syncItem.target = self
    menu.addItem(.separator())
    menu.addItem(makeAccountAndStorageMenu())
    menu.addItem(makeCaptureMethodMenu())
    menu.addItem(makeModelSettingsMenu())
    menu.addItem(makeSupportMenu())
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "退出拾词助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
  }

  func makeScreenshotQuestionItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "截图问一问    \(currentQuestionScreenshotShortcut.title)",
      action: #selector(captureScreenQuestionAction), keyEquivalent: "")
    item.target = self
    return item
  }

  func makeCaptureMethodMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "快捷键与取词", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "快捷键与取词")
    let floating = submenu.addItem(
      withTitle: "拖选后显示“拾词”按钮", action: #selector(toggleFloatingButton), keyEquivalent: "")
    floating.target = self
    floating.state = floatingButtonEnabled ? .on : .off
    submenu.addItem(.separator())
    let shortcutItem = submenu.addItem(
      withTitle: "设置取词与截图快捷键…", action: #selector(openShortcutSettings), keyEquivalent: "")
    shortcutItem.target = self
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "配对浏览器扩展…", action: #selector(pairBrowserExtension), keyEquivalent: "").target = self
    submenu.addItem(withTitle: "撤销浏览器配对", action: #selector(revokeBrowserPairing), keyEquivalent: "").target = self
    item.submenu = submenu
    return item
  }

  private func makeAccountAndStorageMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "账号与本机词库", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: item.title)
    let status = submenu.addItem(withTitle: syncStatusText, action: nil, keyEquivalent: "")
    status.isEnabled = false
    submenu.addItem(.separator())
    for (title, action) in [
      ("查看同步与词库状态…", #selector(showStorageStatus)),
      ("处理同步冲突…", #selector(resolveSyncConflicts)),
      ("绑定未归属词库到当前账号…", #selector(bindUnassignedWords)),
      ("登录或切换账号…", #selector(switchReaderAccount)),
      ("退出阅读达人账号", #selector(signOutReader)),
      ("导出本机词库原件…", #selector(exportStoreOriginal)),
      ("导出未归属词库原件…", #selector(exportUnassignedStoreOriginal)),
      ("从本机备份恢复…", #selector(restoreStoreBackup)),
    ] {
      submenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    item.submenu = submenu
    return item
  }

  private func updateSyncStatus(_ status: VocabularySyncStatus) {
    if displayedUserID != status.userID {
      displayedUserID = status.userID
      accountCaptureGeneration = UUID()
      selectionLookupTask?.cancel()
      selectionPreview?.dismiss()
      ocrPanel?.close(); ocrPanel = nil
    }
    conflictingWordKeys = status.conflictingWordKeys
    let account = status.userID.map { "账号 \($0.prefix(8))" } ?? "未登录"
    syncStatusText = "\(account) · 待同步 \(status.pendingCount) · \(status.message)"
    statusItem?.menu = makeMenu()
  }

  @objc private func showStorageStatus() {
    Task {
      let status = await store.status()
      let alert = NSAlert()
      alert.messageText = "本机词库与同步状态"
      alert.informativeText = syncStatusText
        + "\n未归属词条：\(status.unassignedCount)\n可用备份：\(status.backupURLs.count)"
        + (status.issue.map { "\n\($0)" } ?? "")
      alert.addButton(withTitle: "关闭")
      alert.runModal()
    }
  }

  @objc private func resolveSyncConflicts() {
    Task { await resolveSyncConflicts(wordKeys: conflictingWordKeys) }
  }

  private func resolveSyncConflicts(wordKeys: [String]) async {
    guard !wordKeys.isEmpty else {
      showFailure(title: "没有待处理的词条冲突", "可先手动同步获取最新状态。并发版本竞争可直接再次同步。")
      return
    }
    let alert = NSAlert()
    alert.messageText = "处理 \(wordKeys.count) 个词条冲突"
    alert.informativeText = "这些词在云端已被修改或删除。本机原件会先保存为独立快照。\n采用云端会放弃这些词的待上传改动；采用本机会明确重新提交，已删除的词将恢复。其他待同步词不受影响。"
    alert.addButton(withTitle: "采用云端")
    alert.addButton(withTitle: "采用本机并重新提交")
    alert.addButton(withTitle: "取消")
    let response = alert.runModal()
    guard response != .alertThirdButtonReturn else { return }
    do {
      try await syncCoordinator.resolveConflicts(wordKeys: wordKeys,
        strategy: response == .alertFirstButtonReturn ? .adoptCloud : .resubmitLocal)
      _ = try await syncVocabulary()
      show("冲突已处理", "本机冲突前的词库快照已保留，新的同步状态已确认。")
    } catch { showFailure(title: "冲突处理失败", error.localizedDescription) }
  }

  @objc private func bindUnassignedWords() {
    Task { await bindUnassignedWordsIfRequested() }
  }

  private func bindUnassignedWordsIfRequested() async {
    guard let userID = await cloudSync.currentUserID() else {
      showFailure(title: "请先登录", "未登录词库会继续保存在本机。登录后可明确选择绑定到该账号。")
      return
    }
    do {
      try await syncCoordinator.prepareAccount()
      let status = await store.status()
      guard status.unassignedCount > 0 else { return }
      let alert = NSAlert()
      alert.messageText = "确认本机词库归属"
      alert.informativeText = "本机有 \(status.unassignedCount) 个未归属词条，可能来自旧账号。\n绑定后会加入当前账号 \(userID.prefix(8)) 的待同步队列。原文件保留备份；不会自动搬运其他账号词库。"
      alert.addButton(withTitle: "绑定到当前账号")
      alert.addButton(withTitle: "仅同步账号词库")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      guard await cloudSync.currentUserID() == userID else { throw SupabaseSyncError.accountChanged }
      try await store.adoptUnassignedEntries(into: userID)
      await syncCoordinator.queue()
    } catch { showFailure(title: "词库绑定失败", error.localizedDescription) }
  }

  @objc private func switchReaderAccount() { Task { await openSupabaseLogin() } }

  @objc private func signOutReader() {
    Task {
      do {
        try await cloudSync.signOut()
        accountCaptureGeneration = UUID()
        try await syncCoordinator.accountChanged()
        show("已退出账号", "该账号的本机词库与待同步内容已保留。未登录时的新收藏保存在独立收集箱。")
      } catch { showFailure(title: "退出失败", error.localizedDescription) }
    }
  }

  @objc private func exportStoreOriginal() { exportStore(unassigned: false) }
  @objc private func exportUnassignedStoreOriginal() { exportStore(unassigned: true) }
  private func exportStore(unassigned: Bool) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = unassigned ? "未归属词库原件.json" : "本机词库原件.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        if unassigned { try await store.exportUnassignedOriginal(to: url) }
        else { try await store.exportOriginal(to: url) }
        show("词库已导出", "原文件已保留，可在本机核对或恢复。")
      } catch { showFailure(title: "导出失败", error.localizedDescription) }
    }
  }

  @objc private func restoreStoreBackup() {
    Task {
      let status = await store.status()
      guard let backup = status.backupURLs.first,
        let number = Int(backup.pathExtension.replacingOccurrences(of: "backup", with: ""))
      else { showFailure(title: "没有可用备份", "可以先导出原文件保全数据。没有有效备份时不能自动重建词库。"); return }
      let alert = NSAlert()
      alert.messageText = "从最近备份恢复词库？"
      alert.informativeText = "当前原文件会另存保留。恢复后的待同步状态仍按账号隔离，未归属旧库不会自动上传。"
      alert.addButton(withTitle: "保留原件并恢复")
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      do {
        try await store.restoreBackup(number: number)
        await syncCoordinator.queue()
        show("词库已恢复", "当前原文件已另存，恢复内容已重新载入。")
      } catch { showFailure(title: "恢复失败", error.localizedDescription) }
    }
  }

  @objc private func pairBrowserExtension() {
    let alert = NSAlert()
    alert.messageText = "配对浏览器扩展"
    alert.informativeText = "复制配对码后，在拾词助手浏览器扩展的弹出菜单中填写并点击配对。配对码只用于本机扩展；撤销配对后需重新配对。"
    alert.addButton(withTitle: "复制配对码")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(browserBridge.pairingToken, forType: .string)
  }

  @objc private func revokeBrowserPairing() {
    browserBridge.rotatePairingToken()
    show("浏览器配对已撤销", "旧配对码和选区缓存已失效。可从“快捷键与取词”重新配对。")
  }

  @objc private func enableContextDiagnostics() {
    ContextDebugLog.enableRawDiagnostics(for: 600)
    show("原文诊断已开启10分钟", "这段时间会记录取词原句供本机诊断。可从“帮助与诊断”随时关闭并清除。")
  }

  @objc private func clearContextDiagnostics() {
    ContextDebugLog.disableRawDiagnostics()
    ContextDebugLog.clear()
    show("原文诊断已关闭", "本机上下文调试日志已清除，恢复仅记录耗时与字数。")
  }

  func makeModelSettingsMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "模型与服务", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "模型与服务")
    let dictionary = submenu.addItem(
      withTitle: "取词释义模型…", action: #selector(openSettings), keyEquivalent: ",")
    dictionary.target = self
    submenu.addItem(makeQuestionModelSettingsItem())
    let search = submenu.addItem(
      withTitle: "联网检索设置…", action: #selector(openWebSearchSettings), keyEquivalent: "")
    search.target = self
    item.submenu = submenu
    return item
  }

  func makeQuestionModelSettingsItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "问一问模型设置…", action: #selector(openQuestionModelSettings), keyEquivalent: "")
    item.target = self
    return item
  }

  private func makeSupportMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "帮助与诊断", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "帮助与诊断")
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    let versionItem = submenu.addItem(
      withTitle: "拾词助手 版本 \(version)", action: nil, keyEquivalent: "")
    versionItem.isEnabled = false
    submenu.addItem(.separator())
    submenu.addItem(
      withTitle: "打开上下文调试日志", action: #selector(openContextDebugLog), keyEquivalent: ""
    ).target = self
    submenu.addItem(withTitle: "开启原文诊断（10分钟）", action: #selector(enableContextDiagnostics), keyEquivalent: "").target = self
    submenu.addItem(withTitle: "关闭原文诊断并清除日志", action: #selector(clearContextDiagnostics), keyEquivalent: "").target = self
    item.submenu = submenu
    return item
  }

  @objc func captureSelectionAction() {
    readSelection(allowClipboard: true)
  }

  private func readSelection(allowClipboard: Bool) {
    selectionReadTask?.cancel()
    selectionLookupTask?.cancel()
    selectionLookupID = UUID()
    selectionPreview?.dismiss()
    selectionPreview = nil
    let readID = UUID()
    selectionReadID = readID
    selectionReadTask = Task {
      let selection: SelectedText?
      if AXIsProcessTrusted() {
        selection = allowClipboard ? await SelectionReader.readAsync(browserBridge: browserBridge) : await SelectionReader.readFocusedSelectionAsync(browserBridge: browserBridge)
      } else {
        requestAccessibilityPermission()
        selection = allowClipboard ? SelectionReader.fromServicePasteboard(.general) : nil
      }
      guard !Task.isCancelled, selectionReadID == readID else { return }
      guard let selection else {
        let message = AXIsProcessTrusted()
          ? "请先选中英文单词或短语。若该 App 不支持读取选区，可复制包含原句的内容，或使用截图取词。"
          : "请在系统设置 → 隐私与安全性 → 辅助功能允许拾词助手。也可先复制包含原句的内容或使用截图取词。"
        showFailure(title: AXIsProcessTrusted() ? "没有读到选词" : "需要辅助功能权限", message)
        return
      }
      capture(selection)
    }
  }

  private func requestAccessibilityPermission() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  @objc private func captureScreenTextAction() {
    DispatchQueue.main.async { self.beginScreenshotCapture(destination: .word) }
  }

  @objc private func captureScreenQuestionAction() {
    DispatchQueue.main.async { self.beginScreenshotCapture(destination: .question) }
  }

  @MainActor
  func hideScreenshotPanels() -> () -> Void {
    let restoreOCR = ocrPanel?.hideForScreenshot()
    let panel = directQuestionPanel
    let wasVisible = panel?.isVisible == true
    panel?.orderOut(nil)
    return {
      restoreOCR?()
      if wasVisible { panel?.present() }
    }
  }

  @MainActor
  private func beginScreenshotCapture(destination: ScreenshotDestination) {
    guard !regionCapture.isRunning else { return }
    screenshotTask?.cancel()
    let restore = hideScreenshotPanels()
    setStatus("词 ···")
    regionCapture.capture { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let image):
        guard let image else { self.setStatus("词"); restore(); return }
        self.recognizeScreenshot(image, destination: destination, restore: restore)
      case .failure(let error):
        self.setStatus("词"); restore()
        self.showFailure(title: "截图失败", error.localizedDescription)
      }
    }
  }

  private func recognizeScreenshot(
    _ image: CGImage, destination: ScreenshotDestination, restore: @escaping () -> Void
  ) {
    setStatus("词 ···")
    screenshotTask = Task {
      do {
        let text = try await OCRClient.recognize(image)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.showScreenshot(text: text, image: image, destination: destination)
        }
      } catch OCRCaptureError.noTextFound {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.showScreenshot(text: "", image: image, destination: destination)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.setStatus("词")
          restore()
          self.showFailure(title: "OCR 识别失败", error.localizedDescription)
        }
      }
    }
  }

  @MainActor
  func showScreenshot(text: String, image: CGImage, destination: ScreenshotDestination) {
    switch destination {
    case .word:
      showOCRPanel(text: text, image: image)
    case .question:
      ocrPanel?.close()
      ocrPanel = nil
      directQuestionPanel?.close()
      let panel = ScreenshotQuestionPanel(
        context: ScreenshotQuestionContext(
          text: text, selectedWord: nil, imageData: questionImageData(image)),
        answer: answerScreenshotQuestion,
        onModelSettings: { [weak self] in self?.openQuestionModelSettings() },
        modelPreferences: questionPreferences, measuredAnswer: measuredScreenshotQuestion,
        webAnswer: webScreenshotQuestion,
        onSearchSettings: { [weak self] in self?.openWebSearchSettings() })
      directQuestionPanel = panel
      panel.present()
      setStatus("词")
    }
  }

  private var answerScreenshotQuestion: ScreenshotQuestionAnswer {
    { [weak self] question, context, history, partial in
      guard let self else { throw CancellationError() }
      return try await self.screenshotQuestions.answer(
        question: question, context: context, history: history,
        configuration: self.questionPreferences.configuration(fallingBackTo: self.configuration),
        api: self.questionPreferences.selectedAPI,
        thinking: self.questionPreferences.selectedThinking,
        directConnection: self.questionPreferences.selectedDirectConnection, onPartial: partial)
    }
  }

  private var measuredScreenshotQuestion: ScreenshotQuestionMeasuredAnswer {
    { [weak self] question, context, history, usage, partial in
      guard let self else { throw CancellationError() }
      return try await self.screenshotQuestions.answer(
        question: question, context: context, history: history,
        configuration: self.questionPreferences.configuration(fallingBackTo: self.configuration),
        api: self.questionPreferences.selectedAPI,
        thinking: self.questionPreferences.selectedThinking,
        directConnection: self.questionPreferences.selectedDirectConnection, onUsage: usage,
        onPartial: partial)
    }
  }

  private var webScreenshotQuestion: ScreenshotQuestionWebAnswer {
    { [weak self] question, context, history, enabled, usage, progress, partial in
      guard let self else { throw CancellationError() }
      let search = enabled ? try self.searchPreferences.configuration() : nil
      return try await self.screenshotQuestions.answer(
        question: question, context: context, history: history,
        configuration: self.questionPreferences.configuration(fallingBackTo: self.configuration),
        api: self.questionPreferences.selectedAPI,
        thinking: self.questionPreferences.selectedThinking,
        directConnection: self.questionPreferences.selectedDirectConnection, webSearch: search,
        onUsage: usage, onProgress: progress, onPartial: partial)
    }
  }

  @MainActor
  private func showOCRPanel(text: String, image: CGImage) {
    directQuestionPanel?.close()
    directQuestionPanel = nil
    ocrPanel?.close()
    let ownerGeneration = accountCaptureGeneration
    let writeScope = Task {
      try await syncCoordinator.prepareAccount()
      return await store.writeScope()
    }
    let panel = OCRLookupPanel(
      text: text,
      lookup: { [weak self] selection, onMeaning in
        guard let self else { throw CancellationError() }
        return try await self.dictionary.lookup(
          selection, configuration: self.configuration, onMeaning: onMeaning)
      },
      save: { [weak self] selection, result in
        guard let self, self.accountCaptureGeneration == ownerGeneration else { throw CancellationError() }
        let scope = try await writeScope.value
        try await self.syncCoordinator.prepareAccount()
        guard self.accountCaptureGeneration == ownerGeneration else { throw CancellationError() }
        _ = try await self.store.add(
          word: selection.word, dictionary: result, context: selection.context, scope: scope)
        self.queueOCRSync()
        return "“\(selection.word)”已保存到本机 · 可继续选词"
      }, imageData: questionImageData(image), ask: answerScreenshotQuestion,
      onQuestionSettings: { [weak self] in
        self?.openQuestionModelSettings()
      }, questionPreferences: questionPreferences, measuredAsk: measuredScreenshotQuestion,
      webAsk: webScreenshotQuestion,
      onSearchSettings: { [weak self] in self?.openWebSearchSettings() })
    panel.onRetake = { [weak self] in self?.captureScreenTextAction() }
    ocrPanel = panel
    panel.present()
    setStatus("词")
  }

  private func questionImageData(_ image: CGImage) -> Data? {
    let scale = min(1, 1_600 / CGFloat(max(image.width, image.height)))
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
  }

  @MainActor
  private func queueOCRSync() {
    Task { await syncCoordinator.queue() }
  }

  @objc private func toggleFloatingButton() {
    defaults.set(!floatingButtonEnabled, forKey: floatingButtonEnabledKey)
    if floatingButtonEnabled {
      installSelectionMonitorIfNeeded()
    } else {
      stopSelectionMonitor()
    }
    if !floatingButtonEnabled { dismissFloatingSelectionButton() }
    statusItem.menu = makeMenu()
  }

  private var floatingButtonEnabled: Bool {
    guard defaults.object(forKey: floatingButtonEnabledKey) != nil else { return true }
    return defaults.bool(forKey: floatingButtonEnabledKey)
  }

  private func installSelectionMonitorIfNeeded() {
    guard floatingButtonEnabled, AXIsProcessTrusted(), mouseEventTap == nil
    else { return }
    let eventMask =
      (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
      | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      if let userInfo, type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .keyDown {
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        // Use AppKit screen coordinates before queued handling can observe a moved pointer.
        let location = NSEvent.mouseLocation
        let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.async {
          delegate.handleMouseEvent(type, location: location,
            frontmostProcessIdentifier: processIdentifier)
        }
      }
      return Unmanaged.passUnretained(event)
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    mouseEventTap = tap
    mouseEventSource = source
    applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.selectionDragStart = nil
        self.selectionDragProcessIdentifier = nil
        self.floatingReadTask?.cancel()
        self.dismissFloatingSelectionButton()
      }
    }
  }

  private func stopSelectionMonitor() {
    if let source = mouseEventSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let observer = applicationActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    applicationActivationObserver = nil
    mouseEventTap = nil
    mouseEventSource = nil
    selectionDragStart = nil
    selectionDragProcessIdentifier = nil
    floatingReadTask?.cancel()
    floatingState.invalidate()
    dismissFloatingSelectionButton()
  }

  func handleMouseEvent(
    _ type: CGEventType, location: CGPoint,
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
  ) {
    if type == .keyDown {
      selectionDragStart = nil
      selectionDragProcessIdentifier = nil
      floatingReadTask?.cancel()
      dismissFloatingSelectionButton()
      return
    }
    // The nonactivating panel keeps the source app frontmost. Its button must retain
    // the accepted selection until its own mouse-up action consumes it.
    if let panel = floatingSelectionPanel, panel.isVisible, panel.frame.contains(location) {
      selectionDragStart = nil
      selectionDragProcessIdentifier = nil
      floatingReadTask?.cancel()
      return
    }
    guard frontmostProcessIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      selectionDragStart = nil
      selectionDragProcessIdentifier = nil
      floatingReadTask?.cancel()
      dismissFloatingSelectionButton()
      return
    }
    if type == .rightMouseDown {
      selectionDragStart = nil
      selectionDragProcessIdentifier = nil
      floatingReadTask?.cancel()
      dismissFloatingSelectionButton()
      return
    }
    if type == .leftMouseDown {
      floatingState.invalidate()
      floatingReadTask?.cancel()
      dismissFloatingSelectionButton()
      selectionDragStart = location
      selectionDragProcessIdentifier = frontmostProcessIdentifier
    } else if type == .leftMouseUp {
      defer { selectionDragStart = nil; selectionDragProcessIdentifier = nil }
      guard floatingButtonEnabled,
        let processIdentifier = selectionDragProcessIdentifier,
        processIdentifier == frontmostProcessIdentifier,
        NSApp.modalWindow == nil,
        let start = selectionDragStart,
        hypot(location.x - start.x, location.y - start.y) >= minimumSelectionDragDistance
      else { return }
      let revision = floatingState.revision
      floatingReadTask?.cancel()
      floatingReadTask = Task {
        for wait in [120_000_000, 160_000_000, 240_000_000] {
          do { try await Task.sleep(nanoseconds: UInt64(wait)) } catch { return }
          guard !Task.isCancelled, floatingState.revision == revision,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return }
          let selection = await SelectionReader.readFocusedSelectionAsync(browserBridge: browserBridge)
          guard !Task.isCancelled, floatingState.revision == revision,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return }
          if let selection { showFloatingSelectionButtonIfNeeded(selection: selection, revision: revision,
            frontmostProcessIdentifier: processIdentifier) }
        }
      }
      return
    }
  }

  func showFloatingSelectionButtonIfNeeded(
    selection: SelectedText, revision: UUID,
    frontmostProcessIdentifier: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
  ) {
    guard floatingState.revision == revision, floatingButtonEnabled,
      frontmostProcessIdentifier != ProcessInfo.processInfo.processIdentifier,
      NSApp.modalWindow == nil
    else { return }
    if floatingState.selection?.word == selection.word, floatingState.selection?.context == selection.context,
      floatingSelectionPanel != nil { return }
    guard floatingState.accept(selection, revision: revision) else { return }
    dismissFloatingSelectionButton(keepingSelection: true)

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 72, height: 32),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .ignoresCycle]
    panel.isReleasedWhenClosed = false

    let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
    background.autoresizingMask = [.width, .height]
    background.material = .menu
    background.blendingMode = .withinWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 16
    background.layer?.masksToBounds = true
    let button = NSButton(title: "拾词", target: self, action: #selector(captureFloatingSelection))
    button.bezelStyle = .texturedRounded
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.frame = background.bounds.insetBy(dx: 4, dy: 3)
    button.autoresizingMask = [.width, .height]
    background.addSubview(button)
    panel.contentView = background

    let pointer = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { $0.visibleFrame.contains(pointer) }) ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? .zero
    let origin = CGPoint(
      x: min(max(pointer.x + 12, visibleFrame.minX + 8), visibleFrame.maxX - 80),
      y: min(max(pointer.y - 42, visibleFrame.minY + 8), visibleFrame.maxY - 40)
    )
    panel.setFrameOrigin(origin)
    panel.orderFrontRegardless()
    floatingSelectionPanel = panel
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak panel] in
      guard let self, let panel, self.floatingSelectionPanel === panel else { return }
      self.dismissFloatingSelectionButton()
    }
  }

  @objc private func captureFloatingSelection() {
    guard let selection = floatingState.consume() else { return }
    floatingReadTask?.cancel()
    dismissFloatingSelectionButton()
    capture(selection)
  }

  private func dismissFloatingSelectionButton(keepingSelection: Bool = false) {
    floatingSelectionPanel?.orderOut(nil)
    floatingSelectionPanel = nil
    if !keepingSelection { floatingState.invalidate() }
  }

  private func capture(_ selection: SelectedText) {
    let captureStartedAt = ProcessInfo.processInfo.systemUptime
    let ownerGeneration = accountCaptureGeneration
    selectionLookupTask?.cancel()
    selectionPreview?.dismiss()
    let lookupID = UUID()
    selectionLookupID = lookupID
    setStatus("词 ···")
    let preview = DefinitionPreviewPanel(selection: selection)
    selectionPreview = preview
    preview.onDecision = { [weak self] accepted in
      guard let self, self.selectionLookupID == lookupID else { return }
      if !accepted { self.selectionLookupTask?.cancel() }
      self.selectionLookupTask = nil
      self.selectionPreview = nil
      self.setStatus("词")
    }
    preview.present()
    selectionLookupTask = Task { @MainActor [preview, self] in
      var confirmed = false
      do {
        try await syncCoordinator.prepareAccount()
        let writeScope = await store.writeScope()
        let contextualSelection = try contextualSelection(for: selection)
        let result = try await dictionary.lookup(
          contextualSelection, configuration: configuration,
          onMeaning: { [weak self, weak preview] meaning in
            guard let self, let preview, self.selectionLookupID == lookupID,
              !preview.isFinished
            else { return }
            preview.showMeaning(meaning)
            ContextDebugLog.write(
              "界面显示释义：\(Int((ProcessInfo.processInfo.systemUptime - captureStartedAt) * 1000)) ms",
              word: contextualSelection.word)
          }, onPerformance: { [weak self, weak preview] performance in
            guard let self, self.selectionLookupID == lookupID else { return }
            preview?.showPerformance(performance)
          })
        try Task.checkCancellation()
        guard self.selectionLookupID == lookupID else { return }
        preview.showResult(result)
        guard await preview.waitForConfirmation() else { return }
        confirmed = true
        try await syncCoordinator.prepareAccount()
        guard accountCaptureGeneration == ownerGeneration else { throw SupabaseSyncError.accountChanged }
        let entry = try await store.add(
          word: contextualSelection.word, dictionary: result, context: contextualSelection.context,
          scope: writeScope)
        ContextDebugLog.write("已写入本机生词本", word: entry.word)
        await syncCoordinator.queue()
        let pending = await store.pendingCount()
        self.show("已加入本机生词本", "\(entry.word) · \(entry.meaning)；待同步 \(pending) 项。可从菜单查看同步状态。")
      } catch {
        guard confirmed || (!Task.isCancelled && self.selectionLookupID == lookupID) else { return }
        preview.dismiss()
        self.showFailure(title: "查词失败", error.localizedDescription)
      }
    }
  }

  private func contextualSelection(for selection: SelectedText) throws -> SelectedText {
    let context = selection.context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard context.caseInsensitiveCompare(selection.word) == .orderedSame else {
      ContextDebugLog.write("准备查询：已取得完整语境", word: selection.word, context: context)
      return selection
    }
    ContextDebugLog.write("查词取消：没有取得完整原句", word: selection.word, context: context)
    throw VocabularyError.missingSentenceContext
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
  @objc func captureSelection(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    guard let selection = SelectionReader.fromServicePasteboard(pasteboard) else {
      error.pointee = "请在支持服务菜单的 App 中选择英文单词或短语。"
      return
    }
    capture(selection)
  }

  @MainActor @objc private func openSettings() {
    let alert = NSAlert()
    alert.messageText = "取词释义模型设置"
    alert.informativeText = "使用 OpenAI 兼容接口。Key仅存本机Keychain；自建服务可使用HTTP。思考设置只作用于取词释义。"
    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    let saved = configuration
    let base = NSTextField(string: saved.baseURL)
    let model = NSTextField(string: saved.model)
    let key = NSSecureTextField(string: saved.apiKey)
    for (label, field) in [("Base URL", base), ("Model", model), ("API Key", key)] {
      stack.addArrangedSubview(NSTextField(labelWithString: label))
      field.widthAnchor.constraint(equalToConstant: 420).isActive = true
      field.heightAnchor.constraint(equalToConstant: 26).isActive = true
      stack.addArrangedSubview(field)
    }
    stack.addArrangedSubview(NSTextField(labelWithString: "取词思考强度"))
    let thinking = NSPopUpButton()
    for option in ScreenshotQuestionThinking.allCases { thinking.addItem(withTitle: option.title) }
    thinking.selectItem(at: ScreenshotQuestionThinking.allCases.firstIndex(of: saved.thinking) ?? 1)
    stack.addArrangedSubview(thinking)
    stack.addArrangedSubview(NSTextField(labelWithString: "取词服务类型"))
    let backend = NSPopUpButton()
    for option in DictionaryBackend.allCases { backend.addItem(withTitle: option.title) }
    backend.selectItem(at: DictionaryBackend.allCases.firstIndex(of: saved.backend) ?? 0)
    stack.addArrangedSubview(backend)
    let help = NSTextField(wrappingLabelWithString: "支持的服务默认关闭／最少思考。本地 llama.cpp 请明确选择服务类型；它支持思考开关，强度档位使用输出预算，不能保证远端思考强度。其他未知兼容服务保留默认。")
    help.font = .systemFont(ofSize: 11)
    help.textColor = .secondaryLabelColor
    help.widthAnchor.constraint(equalToConstant: 420).isActive = true
    stack.addArrangedSubview(help)
    alert.accessoryView = stack
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "测试连接")
    Task {
      while true {
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }
        do {
          let candidate = try DictionaryRequestPolicy.normalized(AIConfiguration(
            baseURL: base.stringValue, model: model.stringValue, apiKey: key.stringValue,
            thinking: ScreenshotQuestionThinking.allCases[max(0, thinking.indexOfSelectedItem)],
            backend: DictionaryBackend.allCases[max(0, backend.indexOfSelectedItem)]))
          if response == .alertThirdButtonReturn {
            let tester = DictionaryClient(cacheLimit: 0)
            _ = try await tester.lookup(SelectedText(word: "curious", context: "A curious reader asks a question."),
              configuration: candidate, onPerformance: { [weak settingsAlert = alert] performance in
                settingsAlert?.informativeText = "连接测试通过 · \(performance.summary)\n配置尚未保存。"
              })
            continue
          }
          // Validate before touching Keychain. If update fails the old configuration remains usable.
          _ = try DictionaryRequestPolicy.request(selection: SelectedText(word: "test", context: "This is a test."), configuration: candidate)
          try saveDictionaryKey(candidate.apiKey)
          configuration = candidate
          if !questionPreferences.isEnabled {
            ocrPanel?.questionModelConfigurationChanged()
            directQuestionPanel?.modelConfigurationChanged()
          }
          return
        } catch { alert.informativeText = error.localizedDescription + "\n原配置未改动。" }
      }
    }
  }

  @MainActor @objc func openQuestionModelSettings() {
    if let questionModelSettings {
      questionModelSettings.show()
      return
    }
    let settings = ScreenshotQuestionModelSettings(
      preferences: questionPreferences, dictionaryModel: configuration.model)
    questionModelSettings = settings
    settings.present(
      onChange: { [weak self] in
        self?.ocrPanel?.questionModelConfigurationChanged()
        self?.directQuestionPanel?.modelConfigurationChanged()
      }, onClose: { [weak self] in self?.questionModelSettings = nil })
  }

  @MainActor @objc func openWebSearchSettings() {
    if let webSearchSettings {
      webSearchSettings.show()
      return
    }
    let settings = ScreenshotQuestionWebSearchSettings(preferences: searchPreferences)
    webSearchSettings = settings
    settings.present(
      onChange: { [weak self] in
        self?.directQuestionPanel?.searchConfigurationChanged()
        self?.ocrPanel?.questionSearchConfigurationChanged()
      }, onClose: { [weak self] in self?.webSearchSettings = nil })
  }

  @objc private func showRecentEntries() {
    Task {
      let entries = Array((await store.all()).prefix(12))
      let isLoggedIn = await cloudSync.isLoggedIn()
      await MainActor.run {
        let alert = NSAlert()
        alert.messageText = "最近加入的单词"
        let list =
          entries.isEmpty
          ? "还没有加入任何单词。"
          : entries.map { "\($0.word) · \($0.meaning)" }.joined(separator: "\n")
        alert.informativeText = self.syncDescription(isLoggedIn: isLoggedIn) + "\n\n" + list
        alert.addButton(withTitle: "关闭")
        alert.runModal()
      }
    }
  }

  @objc private func openContextDebugLog() {
    ContextDebugLog.open()
  }

  @objc private func syncToReader() {
    guard !isOpeningCloudSync else { return }
    isOpeningCloudSync = true
    Task { @MainActor in
      defer { isOpeningCloudSync = false }
      if await cloudSync.isLoggedIn() {
        do {
          try await syncCoordinator.prepareAccount()
          if await store.status().unassignedCount > 0 { await bindUnassignedWordsIfRequested() }
          let result = try await syncVocabulary()
          self.show("同步完成", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个")
        } catch SupabaseSyncError.conflict(let keys) {
          await resolveSyncConflicts(wordKeys: keys)
        } catch SupabaseSyncError.sessionExpired {
          await openSupabaseLogin(sessionExpired: true)
        } catch SupabaseSyncError.notLoggedIn {
          await openSupabaseLogin()
        } catch {
          self.showFailure(title: "同步失败", error.localizedDescription)
        }
      } else {
        await openSupabaseLogin()
      }
    }
  }

  @MainActor
  func makeSupabaseLoginAlert(sessionExpired: Bool = false) -> (
    alert: NSAlert, email: NSTextField, password: NSSecureTextField
  ) {
    let alert = NSAlert()
    alert.messageText = sessionExpired ? "请重新登录阅读达人" : "登录阅读达人账号"
    alert.informativeText =
      (sessionExpired ? "原登录已失效，本机生词已保留，重新登录后会同步。\n" : "")
      + "使用与阅读达人相同的邮箱和密码。密码不会保存在拾词助手中。"
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
    return (alert, email, password)
  }

  @MainActor
  private func openSupabaseLogin(sessionExpired: Bool = false) async {
    let (alert, email, password) = makeSupabaseLoginAlert(sessionExpired: sessionExpired)
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      _ = try await cloudSync.signIn(
        email: email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
        password: password.stringValue)
      accountCaptureGeneration = UUID()
      try await syncCoordinator.accountChanged()
      if await store.status().unassignedCount > 0 { await bindUnassignedWordsIfRequested() }
      let result = try await syncVocabulary()
      self.show("已登录并同步", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个")
    } catch {
      self.showFailure(title: "登录或同步失败", error.localizedDescription)
    }
  }

  private func syncVocabulary() async throws -> VocabularySyncSummary {
    try await syncCoordinator.sync()
  }

  private func syncDescription(isLoggedIn: Bool) -> String {
    isLoggedIn ? syncStatusText : "未登录 · 仅保存在本机，绑定账号后可同步"
  }

  @objc private func openShortcutSettings() {
    // Let the status menu finish tracking before activating a keyboard window.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let settings = self.shortcutSettings {
        settings.show()
        return
      }
      let settings = CaptureShortcutSettings(
        selection: self.currentShortcut, screenshot: self.currentScreenshotShortcut,
        questionScreenshot: self.currentQuestionScreenshotShortcut)
      self.shortcutSettings = settings
      // Pause capture hotkeys so the recorder receives existing combinations.
      self.unregisterHotKeys()
      settings.present(
        validateAndSave: { [weak self] selection, screenshot, questionScreenshot in
          guard let self else { return "应用已关闭。" }
          if let error = self.installHotKeys(
            selection: selection, screenshot: screenshot, questionScreenshot: questionScreenshot)
          {
            return error
          }
          self.shortcutPreferences.save(
            selection: selection, screenshot: screenshot, questionScreenshot: questionScreenshot)
          self.statusItem.menu = self.makeMenu()
          return nil
        },
        onClose: { [weak self] in
          guard let self else { return }
          if self.hotKeyRefs.count != 3 { self.registerHotKey() }
          self.shortcutSettings = nil
        })
    }
  }

  private var configuration: AIConfiguration {
    get {
      let saved = try? JSONDecoder().decode(
        AIConfiguration.self, from: defaults.data(forKey: configurationKey) ?? Data())
      return AIConfiguration(
        baseURL: saved?.baseURL ?? "", model: saved?.model ?? "", apiKey: readDictionaryKey(),
        thinking: saved?.thinking ?? .off, backend: saved?.backend ?? .openAICompatible
      )
    }
    set {
      let nonSecret = AIConfiguration(baseURL: newValue.baseURL, model: newValue.model, apiKey: "", thinking: newValue.thinking, backend: newValue.backend)
      defaults.set(try? JSONEncoder().encode(nonSecret), forKey: configurationKey)
    }
  }

  private var currentShortcut: CaptureShortcut { shortcutPreferences.currentSelection }
  private var currentScreenshotShortcut: CaptureShortcut { shortcutPreferences.currentScreenshot }

  private var currentQuestionScreenshotShortcut: CaptureShortcut {
    shortcutPreferences.currentQuestionScreenshot
  }

  private func installHotKeyHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, data in
        let delegate = Unmanaged<AppDelegate>.fromOpaque(data!).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        switch hotKeyID.id {
        case 1: delegate.captureSelectionAction()
        case 2: delegate.captureScreenTextAction()
        case 3: delegate.captureScreenQuestionAction()
        default: break
        }
        return noErr
      }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
  }

  private func unregisterHotKeys() {
    for reference in hotKeyRefs.values { UnregisterEventHotKey(reference) }
    hotKeyRefs.removeAll()
  }

  private func installHotKeys(
    selection: CaptureShortcut, screenshot: CaptureShortcut,
    questionScreenshot: CaptureShortcut, allowPartial: Bool = false
  ) -> String? {
    if let error = CaptureShortcut.validationError(
      selection: selection, screenshot: screenshot, questionScreenshot: questionScreenshot
    ) {
      return error
    }
    unregisterHotKeys()
    let bindings: [(UInt32, String, CaptureShortcut)] = [
      (1, "选词", selection), (2, "截图取词", screenshot), (3, "截图问一问", questionScreenshot),
    ]
    var failures: [String] = []
    for (id, name, shortcut) in bindings {
      var reference: EventHotKeyRef?
      let hotKeyID = EventHotKeyID(signature: OSType(0x5643_4150), id: id)
      let status = RegisterEventHotKey(
        shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
      if status == noErr, let reference {
        hotKeyRefs[id] = reference
      } else {
        failures.append("\(name)快捷键 \(shortcut.title) 无法启用，可能已被其他应用占用（\(status)）。请换一个组合键。")
        if !allowPartial {
          unregisterHotKeys()
          return failures.last
        }
      }
    }
    return failures.isEmpty ? nil : failures.joined(separator: "\n")
  }

  private func registerHotKey() {
    if let error = installHotKeys(
      selection: currentShortcut, screenshot: currentScreenshotShortcut,
      questionScreenshot: currentQuestionScreenshotShortcut, allowPartial: true
    ) {
      showFailure(title: "部分快捷键未启用", error + " 也可从菜单栏使用，并在“快捷键与取词”中重新设置。")
    }
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
      let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil)
      UNUserNotificationCenter.current().add(request)
    }
  }

  private func setStatus(_ value: String) {
    guard let statusItem else { return }
    statusItem.button?.title = value
    guard value != "词" else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard self?.statusItem?.button?.title == value else { return }
      self?.statusItem?.button?.title = "词"
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopSelectionMonitor()
    selectionReadTask?.cancel()
    floatingReadTask?.cancel()
    selectionLookupTask?.cancel()
    screenshotTask?.cancel()
    Task { await screenshotQuestions.shutdown(); await syncCoordinator.stop() }
  }
}
