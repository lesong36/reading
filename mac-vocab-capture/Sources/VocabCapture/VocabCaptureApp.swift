import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let shortcutPreferences: ShortcutPreferences
  private var shortcutSettings: CaptureShortcutSettings?
  private let store: VocabularyStore
  private let dictionary = DictionaryClient()
  private let screenshotQuestions = ScreenshotQuestionClient()
  private let questionPreferences: ScreenshotQuestionPreferences
  private var questionModelSettings: ScreenshotQuestionModelSettings?
  private let cloudSync: SupabaseVocabularySync
  private var isOpeningCloudSync = false
  private var statusItem: NSStatusItem!
  private(set) var pendingOpenURLs: [URL] = []
  private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
  private var hotKeyHandler: EventHandlerRef?
  private var mouseEventTap: CFMachPort?
  private var mouseEventSource: CFRunLoopSource?
  private var recentEntriesPanel: NSPanel?
  private var screenshotProcess: Process?
  private var screenshotTask: Task<Void, Never>?
  private(set) var ocrPanel: OCRLookupPanel?
  private(set) var directQuestionPanel: ScreenshotQuestionPanel?

  enum ScreenshotDestination { case word, question }
  private var selectionLookupTask: Task<Void, Never>?
  private var selectionPreview: DefinitionPreviewPanel?
  private var selectionLookupID = UUID()
  private var ocrSyncTask: Task<Void, Never>?
  private var ocrSyncPending = false
  private var lastLeftMouseDown: CFAbsoluteTime?
  private var lastRightMouseDown: CFAbsoluteTime?
  private var selectionDragStart: CGPoint?
  private var floatingSelectionPanel: NSPanel?
  private var floatingSelection: SelectedText?
  private let configurationKey = "VocabCapture.aiConfiguration"
  private let mouseChordEnabledKey = "VocabCapture.mouseChordEnabled"
  private let floatingButtonEnabledKey = "VocabCapture.floatingButtonEnabled"
  private let lastSyncedAtKey = "VocabCapture.lastSyncedAt"
  private let mouseChordInterval: CFAbsoluteTime = 0.22
  private let minimumSelectionDragDistance: CGFloat = 4

  init(
    cloudSync: SupabaseVocabularySync = SupabaseVocabularySync(),
    store: VocabularyStore = VocabularyStore(),
    shortcutPreferences: ShortcutPreferences = ShortcutPreferences(),
    questionPreferences: ScreenshotQuestionPreferences = ScreenshotQuestionPreferences()
  ) {
    self.shortcutPreferences = shortcutPreferences
    self.questionPreferences = questionPreferences
    self.cloudSync = cloudSync
    self.store = store
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
    installMouseChordIfNeeded()
    BrowserContextBridge.shared.start()
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
    let mouseChord = submenu.addItem(
      withTitle: "左右键同时按下取词", action: #selector(toggleMouseChord), keyEquivalent: "")
    mouseChord.target = self
    mouseChord.state = mouseChordEnabled ? .on : .off
    submenu.addItem(.separator())
    let shortcutItem = submenu.addItem(
      withTitle: "设置取词与截图快捷键…", action: #selector(openShortcutSettings), keyEquivalent: "")
    shortcutItem.target = self
    item.submenu = submenu
    return item
  }

  func makeModelSettingsMenu() -> NSMenuItem {
    let item = NSMenuItem(title: "模型与服务", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "模型与服务")
    let dictionary = submenu.addItem(
      withTitle: "取词释义模型…", action: #selector(openSettings), keyEquivalent: ",")
    dictionary.target = self
    submenu.addItem(makeQuestionModelSettingsItem())
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
    item.submenu = submenu
    return item
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
    guard screenshotProcess == nil else { return }
    screenshotTask?.cancel()
    let restore = hideScreenshotPanels()
    captureNativeRegion { [weak self] image in
      guard let self else { return }
      guard let image else {
        self.setStatus("词")
        restore()
        return
      }
      self.recognizeScreenshot(image, destination: destination, restore: restore)
    }
  }

  private func captureNativeRegion(completion: @escaping (CGImage?) -> Void) {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vocab-ocr-\(UUID().uuidString).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-o", "-t", "png", fileURL.path]
    process.terminationHandler = { [weak self] finished in
      defer { try? FileManager.default.removeItem(at: fileURL) }
      let image: CGImage?
      if finished.terminationStatus == 0, let captured = NSImage(contentsOf: fileURL) {
        image = captured.cgImage(forProposedRect: nil, context: nil, hints: nil)
      } else {
        image = nil
      }
      DispatchQueue.main.async {
        self?.screenshotProcess = nil
        completion(image)
      }
    }
    do {
      try process.run()
      screenshotProcess = process
      setStatus("词 ···")
    } catch {
      completion(nil)
      showFailure(title: "无法启动截图", error.localizedDescription)
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
        modelPreferences: questionPreferences, measuredAnswer: measuredScreenshotQuestion)
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

  @MainActor
  private func showOCRPanel(text: String, image: CGImage) {
    directQuestionPanel?.close()
    directQuestionPanel = nil
    ocrPanel?.close()
    let panel = OCRLookupPanel(
      text: text,
      lookup: { [weak self] selection, onMeaning in
        guard let self else { throw CancellationError() }
        return try await self.dictionary.lookup(
          selection, configuration: self.configuration, onMeaning: onMeaning)
      },
      save: { [weak self] selection, result in
        guard let self else { throw CancellationError() }
        _ = try await self.store.add(
          word: selection.word, dictionary: result, context: selection.context)
        self.queueOCRSync()
        return "“\(selection.word)”已保存到本机 · 可继续选词"
      }, imageData: questionImageData(image), ask: answerScreenshotQuestion,
      onQuestionSettings: { [weak self] in
        self?.openQuestionModelSettings()
      }, questionPreferences: questionPreferences, measuredAsk: measuredScreenshotQuestion)
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
    ocrSyncPending = true
    guard ocrSyncTask == nil else { return }
    ocrSyncTask = Task {
      while self.ocrSyncPending {
        self.ocrSyncPending = false
        do {
          _ = try await self.syncVocabulary()
          await MainActor.run { self.setStatus("词 ✓") }
        } catch SupabaseSyncError.notLoggedIn {
          // Local capture remains useful before the user signs in.
        } catch SupabaseSyncError.sessionExpired {
          await MainActor.run {
            self.show("已保存在本机，请重新登录", "阅读达人登录已失效。请从菜单选择“同步到阅读达人…”重新登录，生词会在登录后同步。")
          }
        } catch {
          await MainActor.run { self.show("已保存在本机，云同步失败", error.localizedDescription) }
        }
      }
      self.ocrSyncTask = nil
    }
  }

  @objc private func toggleMouseChord() {
    UserDefaults.standard.set(!mouseChordEnabled, forKey: mouseChordEnabledKey)
    if mouseChordEnabled || floatingButtonEnabled {
      installMouseChordIfNeeded()
    } else {
      stopMouseChord()
    }
    statusItem.menu = makeMenu()
  }

  @objc private func toggleFloatingButton() {
    UserDefaults.standard.set(!floatingButtonEnabled, forKey: floatingButtonEnabledKey)
    if floatingButtonEnabled || mouseChordEnabled {
      installMouseChordIfNeeded()
    } else {
      stopMouseChord()
    }
    if !floatingButtonEnabled { dismissFloatingSelectionButton() }
    statusItem.menu = makeMenu()
  }

  private var mouseChordEnabled: Bool {
    guard UserDefaults.standard.object(forKey: mouseChordEnabledKey) != nil else { return true }
    return UserDefaults.standard.bool(forKey: mouseChordEnabledKey)
  }

  private var floatingButtonEnabled: Bool {
    guard UserDefaults.standard.object(forKey: floatingButtonEnabledKey) != nil else { return true }
    return UserDefaults.standard.bool(forKey: floatingButtonEnabledKey)
  }

  private func installMouseChordIfNeeded() {
    guard mouseChordEnabled || floatingButtonEnabled, AXIsProcessTrusted(), mouseEventTap == nil
    else { return }
    let eventMask =
      (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
      | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      if let userInfo, type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown {
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
          delegate.handleMouseEvent(type, location: NSEvent.mouseLocation)
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
  }

  private func stopMouseChord() {
    guard let source = mouseEventSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    mouseEventTap = nil
    mouseEventSource = nil
    lastLeftMouseDown = nil
    lastRightMouseDown = nil
    selectionDragStart = nil
    dismissFloatingSelectionButton()
  }

  private func handleMouseEvent(_ type: CGEventType, location: CGPoint) {
    guard
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        != ProcessInfo.processInfo.processIdentifier
    else {
      selectionDragStart = nil
      lastLeftMouseDown = nil
      lastRightMouseDown = nil
      return
    }
    if type == .leftMouseDown {
      selectionDragStart = location
    } else if type == .leftMouseUp {
      defer { selectionDragStart = nil }
      guard floatingButtonEnabled,
        NSApp.modalWindow == nil,
        let start = selectionDragStart,
        hypot(location.x - start.x, location.y - start.y) >= minimumSelectionDragDistance
      else { return }
      // Safari commits a drag selection noticeably later than several native
      // editors. Retry briefly instead of assuming the AX selection is ready
      // on the first post-mouse-up turn.
      for delay in [0.12, 0.28, 0.52] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.showFloatingSelectionButtonIfNeeded()
        }
      }
      return
    }

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

  private func showFloatingSelectionButtonIfNeeded() {
    guard floatingButtonEnabled,
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        != ProcessInfo.processInfo.processIdentifier,
      NSApp.modalWindow == nil,
      floatingSelectionPanel == nil,
      let selection = SelectionReader.readFocusedSelection()
    else { return }
    floatingSelection = selection
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
      guard self?.floatingSelectionPanel === panel else { return }
      self?.dismissFloatingSelectionButton()
    }
  }

  @objc private func captureFloatingSelection() {
    guard let selection = floatingSelection else { return }
    dismissFloatingSelectionButton()
    capture(selection)
  }

  private func dismissFloatingSelectionButton(keepingSelection: Bool = false) {
    floatingSelectionPanel?.orderOut(nil)
    floatingSelectionPanel = nil
    if !keepingSelection { floatingSelection = nil }
  }

  private func capture(_ selection: SelectedText) {
    let captureStartedAt = Date()
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
        let contextualSelection = try contextualSelection(for: selection)
        let result = try await dictionary.lookup(
          contextualSelection, configuration: configuration,
          onMeaning: { [weak self, weak preview] meaning in
            guard let self, let preview, self.selectionLookupID == lookupID,
              !preview.isFinished
            else { return }
            preview.showMeaning(meaning)
            ContextDebugLog.write(
              "界面显示释义：\(Int(Date().timeIntervalSince(captureStartedAt) * 1000)) ms",
              word: contextualSelection.word)
          })
        try Task.checkCancellation()
        guard self.selectionLookupID == lookupID else { return }
        preview.showResult(result)
        guard await preview.waitForConfirmation() else { return }
        confirmed = true
        let entry = try await store.add(
          word: contextualSelection.word, dictionary: result, context: contextualSelection.context)
        ContextDebugLog.write("已写入本机生词本", word: entry.word)
        do {
          let result = try await self.syncVocabulary()
          ContextDebugLog.write("云同步完成：新增/更新 \(result.uploadedCount) 个", word: entry.word)
          await MainActor.run {
            self.show(
              "已同步到阅读达人",
              "\(entry.word) · \(entry.meaning)；本次新增/更新 \(result.uploadedCount) 个，云端共 \(result.totalCount) 个"
            )
          }
        } catch SupabaseSyncError.notLoggedIn {
          await MainActor.run {
            self.show("已加入本机生词本", "\(entry.word) · \(entry.meaning)；登录后可同步到阅读达人")
          }
        } catch SupabaseSyncError.sessionExpired {
          await MainActor.run {
            self.show("已加入本机，请重新登录", "阅读达人登录已失效。请从菜单选择“同步到阅读达人…”重新登录，生词会在登录后同步。")
          }
        } catch {
          await MainActor.run { self.show("已加入本机，云同步失败", error.localizedDescription) }
        }
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
      configuration = AIConfiguration(
        baseURL: base.stringValue, model: model.stringValue, apiKey: key.stringValue)
      if !questionPreferences.isEnabled {
        ocrPanel?.questionModelConfigurationChanged()
        directQuestionPanel?.modelConfigurationChanged()
      }
    } catch { show("无法保存 API Key", error.localizedDescription) }
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
          let result = try await syncVocabulary()
          self.show("同步完成", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个")
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
      let result = try await syncVocabulary()
      self.show("已登录并同步", "本次新增/更新 \(result.uploadedCount) 个单词；云端共 \(result.totalCount) 个")
    } catch {
      self.showFailure(title: "登录或同步失败", error.localizedDescription)
    }
  }

  private func syncVocabulary() async throws -> (uploadedCount: Int, totalCount: Int) {
    let local = await store.all()
    let result = try await cloudSync.sync(local: local)
    try await store.applySync(result.vocabulary, basedOn: local)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncedAtKey)
    return (result.uploadedCount, result.vocabulary.count)
  }

  private func syncDescription(isLoggedIn: Bool) -> String {
    guard isLoggedIn else { return "仅保存在本机 · 登录阅读达人后可同步" }
    guard UserDefaults.standard.object(forKey: lastSyncedAtKey) != nil else {
      return "已登录阅读达人 · 尚未手动同步"
    }
    let time = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastSyncedAtKey))
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "已同步阅读达人 · 上次同步 \(formatter.string(from: time))"
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
        AIConfiguration.self, from: UserDefaults.standard.data(forKey: configurationKey) ?? Data())
      return AIConfiguration(
        baseURL: saved?.baseURL ?? "", model: saved?.model ?? "", apiKey: KeychainStore.readAPIKey()
      )
    }
    set {
      let nonSecret = AIConfiguration(baseURL: newValue.baseURL, model: newValue.model, apiKey: "")
      UserDefaults.standard.set(try? JSONEncoder().encode(nonSecret), forKey: configurationKey)
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
      center.add(request)
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
    stopMouseChord()
    Task { await screenshotQuestions.shutdown() }
  }
}

final class DefinitionPreviewPanel: NSPanel, NSWindowDelegate {
  var onDecision: ((Bool) -> Void)?
  var isFinished: Bool { decision != nil }
  private var decision: Bool?
  private var confirmation: CheckedContinuation<Bool, Never>?
  private var ready = false
  private var metadataLabel: NSTextField!
  private var meaningField: NSTextField!
  private var noteField: NSTextField!
  private var addButton: NSButton!

  init(selection: SelectedText) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    title = "语境释义"
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    delegate = self

    let background = NSVisualEffectView()
    background.material = .underWindowBackground
    background.blendingMode = .behindWindow
    background.state = .active
    contentView = background

    let eyebrow = label(
      "语境释义", font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
    let word = label(
      selection.word, font: .systemFont(ofSize: 27, weight: .bold), color: .labelColor)
    metadataLabel = label(
      "正在查询…", font: .systemFont(ofSize: 14, weight: .medium), color: .systemIndigo)
    let meaningLabel = label(
      "原句中的含义", font: .systemFont(ofSize: 12, weight: .semibold), color: .tertiaryLabelColor)
    let meaning = label(
      "等待语境释义…", font: .systemFont(ofSize: 20, weight: .semibold), color: .labelColor)
    meaningField = meaning
    noteField = label("", font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
    noteField.isHidden = true
    let sourceTitle = label(
      "原句语境", font: .systemFont(ofSize: 12, weight: .semibold), color: .tertiaryLabelColor)
    let source = sourceView(selection.context)

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 9
    let summaryViews: [NSView] = [eyebrow, word, metadataLabel, divider(), meaningLabel, meaning]
    for view in summaryViews {
      content.addArrangedSubview(view)
    }
    content.setCustomSpacing(12, after: meaning)
    content.addArrangedSubview(noteField)
    content.setCustomSpacing(16, after: noteField)
    content.addArrangedSubview(sourceTitle)
    content.addArrangedSubview(source)

    let cancel = NSButton(title: "稍后再说", target: self, action: #selector(cancel))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"
    let add = NSButton(title: "加入生词本", target: self, action: #selector(confirm))
    addButton = add
    add.isEnabled = false
    add.bezelStyle = .rounded
    add.keyEquivalent = "\r"
    add.controlSize = .large
    add.contentTintColor = .controlAccentColor
    let footer = NSStackView(views: [cancel, NSView(), add])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.distribution = .fill
    footer.spacing = 12
    cancel.widthAnchor.constraint(equalToConstant: 112).isActive = true
    add.widthAnchor.constraint(equalToConstant: 136).isActive = true

    for view in [content, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(view)
    }
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
      content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 30),
      content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -30),
      source.widthAnchor.constraint(equalTo: content.widthAnchor),
      footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -24),
      footer.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 20),
    ])
  }

  func present() {
    guard !isFinished else { return }
    center()
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func showMeaning(_ meaning: String) {
    guard !isFinished, !ready else { return }
    meaningField.stringValue = meaning
    metadataLabel.stringValue = "正在补全词性与音标…"
  }

  func showResult(_ result: DictionaryResult) {
    guard !isFinished else { return }
    meaningField.stringValue = result.meaning
    metadataLabel.stringValue = [result.partOfSpeech, result.pronunciation]
      .filter { !$0.isEmpty }.joined(separator: "   ")
    noteField.stringValue = result.note
    noteField.isHidden = result.note.isEmpty
    ready = true
    addButton.isEnabled = true
  }

  func waitForConfirmation() async -> Bool {
    if let decision { return decision }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if let decision {
          continuation.resume(returning: decision)
        } else if Task.isCancelled {
          dismiss()
          continuation.resume(returning: false)
        } else {
          confirmation = continuation
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.dismiss() }
    }
  }

  @objc private func confirm() {
    guard ready else { return }
    finish(true)
  }

  @objc private func cancel() { dismiss() }

  override func cancelOperation(_ sender: Any?) { dismiss() }

  func dismiss() { finish(false) }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    dismiss()
    return false
  }

  private func finish(_ accepted: Bool) {
    guard !isFinished else { return }
    decision = accepted
    addButton.isEnabled = false
    orderOut(nil)
    let completion = confirmation
    confirmation = nil
    let callback = onDecision
    onDecision = nil
    callback?(accepted)
    completion?.resume(returning: accepted)
  }

  private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = font
    field.textColor = color
    field.maximumNumberOfLines = 0
    return field
  }

  private func divider() -> NSBox {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 460).isActive = true
    return line
  }

  private func sourceView(_ text: String) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.wantsLayer = true
    scroll.layer?.cornerRadius = 10
    scroll.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 128))
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textColor = .secondaryLabelColor
    view.font = .systemFont(ofSize: 15)
    view.textContainerInset = NSSize(width: 14, height: 12)
    view.textContainer?.widthTracksTextView = true
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.autoresizingMask = [.width]
    view.string = text
    scroll.documentView = view
    scroll.heightAnchor.constraint(equalToConstant: 128).isActive = true
    return scroll
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

    let title = makeLabel(
      "最近加入", font: .systemFont(ofSize: 22, weight: .semibold), color: .labelColor)
    let subtitle = makeLabel(
      syncDescription, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder

    let list = RecentVocabularyListView(entries: entries, width: 508)
    list.autoresizingMask = [.width]
    scroll.documentView = list

    for view in [title, subtitle, scroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
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
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
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
      drawText(
        "还没有加入单词。选中英文后，按快捷键或鼠标左右键一起按即可开始。",
        in: NSRect(x: 18, y: 28, width: bounds.width - 36, height: 54),
        font: .systemFont(ofSize: 15), color: .secondaryLabelColor)
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
    let wordHeight = drawText(
      entry.word, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 32),
      font: .systemFont(ofSize: 25, weight: .semibold), color: .labelColor)
    y += wordHeight + 4
    let detail = [entry.partOfSpeech, entry.pronunciation].filter { !$0.isEmpty }.joined(
      separator: " · ")
    if !detail.isEmpty {
      let detailHeight = drawText(
        detail, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 22),
        font: .systemFont(ofSize: 13, weight: .medium), color: .systemIndigo)
      y += detailHeight + 10
    } else {
      y += 8
    }
    let meaningHeight = drawText(
      entry.meaning, in: NSRect(x: inset.minX, y: y, width: inset.width, height: 46),
      font: .systemFont(ofSize: 17, weight: .medium), color: .labelColor)
    y += meaningHeight + 16
    let contextLabel = drawText(
      "来自文章语境", in: NSRect(x: inset.minX, y: y, width: inset.width, height: 18),
      font: .systemFont(ofSize: 12, weight: .semibold), color: .tertiaryLabelColor)
    y += contextLabel + 5
    let sentence =
      entry.sourceContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? entry.exampleSentence : entry.sourceContext
    let sentenceText = sentence.isEmpty ? "未读取到完整原句" : sentence
    let sentenceHeight = drawText(
      sentenceText, in: NSRect(x: inset.minX, y: y, width: inset.width, height: rect.maxY - y - 34),
      font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
    y += sentenceHeight + 14
    drawText(
      "加入于 \(formattedDate(entry))",
      in: NSRect(x: inset.minX, y: y, width: inset.width, height: 18),
      font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
  }

  private func cardHeight(for entry: VocabularyEntry, width: CGFloat) -> CGFloat {
    let textWidth = width - 40
    let detail = [entry.partOfSpeech, entry.pronunciation].filter { !$0.isEmpty }.joined(
      separator: " · ")
    let sentence =
      entry.sourceContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? entry.exampleSentence : entry.sourceContext
    return 36
      + measuredHeight(
        entry.word, width: textWidth, font: .systemFont(ofSize: 25, weight: .semibold))
      + (detail.isEmpty ? 8 : 27)
      + measuredHeight(
        entry.meaning, width: textWidth, font: .systemFont(ofSize: 17, weight: .medium))
      + 34
      + measuredHeight(
        sentence.isEmpty ? "未读取到完整原句" : sentence, width: textWidth, font: .systemFont(ofSize: 14))
      + 32
  }

  @discardableResult
  private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) -> CGFloat {
    let height = measuredHeight(text, width: rect.width, font: font)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    NSAttributedString(string: text, attributes: attributes).draw(
      with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    return height
  }

  private func measuredHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let size = NSAttributedString(string: text, attributes: attributes).boundingRect(
      with: NSSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).size
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
