import AppKit

typealias ScreenshotQuestionMeasuredAnswer = (
  String, ScreenshotQuestionContext, [ScreenshotQuestionTurn],
  @escaping @MainActor @Sendable (ScreenshotQuestionUsage) -> Void,
  @escaping @MainActor @Sendable (String) -> Void
) async throws -> String

typealias ScreenshotQuestionWebAnswer = (
  String, ScreenshotQuestionContext, [ScreenshotQuestionTurn], Bool,
  @escaping @MainActor @Sendable (ScreenshotQuestionUsage) -> Void,
  @escaping @MainActor @Sendable (ScreenshotQuestionSearchStage) -> Void,
  @escaping @MainActor @Sendable (String) -> Void
) async throws -> String

typealias MathQuestionSave =
  @MainActor @Sendable (MathQuestionSaveRequest) async throws -> MathQuestionRecord

@MainActor
final class ScreenshotQuestionPanel: ScreenshotPanel, NSWindowDelegate {
  private let source = NSTextField(wrappingLabelWithString: "")
  private let transcript = NSTextView()
  private let question = NSTextField()
  private let askButton = NSButton(title: "提问", target: nil, action: nil)
  private let stopButton = NSButton(title: "停止", target: nil, action: nil)
  private let imageCheckbox = NSButton(checkboxWithTitle: "参考原截图", target: nil, action: nil)
  private let status = NSTextField(wrappingLabelWithString: "输入问题，或点击快捷问题开始。")
  private let saveQuestionButton = NSButton(title: "保存题目", target: nil, action: nil)
  private let openQuestionButton = NSButton(title: "查看已保存题目", target: nil, action: nil)
  private let saveStatus = NSTextField(wrappingLabelWithString: "")
  private let saveQuestion: MathQuestionSave?
  private let onOpenQuestion: (@MainActor (String) -> Void)?
  private let solutionModel: (@MainActor () -> String)?
  private var originalImageData: Data?
  private var captureID = UUID().uuidString
  private var saveRevision = UUID()
  private var saveTask: Task<Void, Never>?
  private var persistenceFollowupScheduled = false
  private var completedSolutions: [MathQuestionSolution] = []
  private var persistedSolutionIDs: Set<String> = []
  private(set) var savedQuestionID: String?
  private(set) var isSavingQuestion = false
  private let suggestions = NSStackView()
  private let performanceLabel = NSTextField(wrappingLabelWithString: "")
  private let searchCheckbox = NSButton(checkboxWithTitle: "联网检索", target: nil, action: nil)
  private let webAnswer: ScreenshotQuestionWebAnswer?
  private let onSearchSettings: (() -> Void)?
  static let webSearchEnabledKey = "VocabCapture.questionWebSearchEnabled"
  private let measuredAnswer: ScreenshotQuestionMeasuredAnswer?
  private let quickPrompts: ScreenshotQuestionQuickPrompts
  private let interfaceDefaults: UserDefaults
  private let now: () -> TimeInterval
  private var quickPromptSettings: ScreenshotQuestionQuickPromptSettings?
  private var suggestionWidth: CGFloat = 0
  private var suggestionButtons: [NSButton] = []
  private(set) var zoomScale: CGFloat = 1
  private(set) var performance: ScreenshotQuestionPerformance?
  static let zoomKey = "VocabCapture.questionZoomScale"
  private let answer: ScreenshotQuestionAnswer
  private let sessionStore: ScreenshotQuestionSessionStore?
  private var sessionID: String?
  private var sessionAttachmentID: String?
  private var sessionPersistenceTask: Task<Void, Never>?
  private let onModelSettings: (() -> Void)?
  private let modelPreferences: ScreenshotQuestionPreferences?
  private let modelPicker = NSPopUpButton()
  private let sessionButton = NSButton(title: "问答记录", target: nil, action: nil)
  private let thinkingPicker = NSPopUpButton()
  private var context: ScreenshotQuestionContext
  private var answerTask: Task<Void, Never>?
  private var transcriptUpdateTask: Task<Void, Never>?
  private var performanceUpdateTask: Task<Void, Never>?
  private var revision = UUID()
  private var pendingQuestion: String?
  private var partialAnswer = ""
  private var pendingOutcome = ""
  private var isClosed = false
  private(set) var history: [ScreenshotQuestionTurn] = []
  private(set) var isAnswering = false

  init(
    context: ScreenshotQuestionContext, answer: @escaping ScreenshotQuestionAnswer,
    onModelSettings: (() -> Void)? = nil,
    modelPreferences: ScreenshotQuestionPreferences? = nil,
    measuredAnswer: ScreenshotQuestionMeasuredAnswer? = nil,
    quickPrompts: ScreenshotQuestionQuickPrompts = ScreenshotQuestionQuickPrompts(),
    interfaceDefaults: UserDefaults = .standard,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    webAnswer: ScreenshotQuestionWebAnswer? = nil,
    onSearchSettings: (() -> Void)? = nil,
    originalImageData: Data? = nil,
    saveQuestion: MathQuestionSave? = nil,
    onOpenQuestion: (@MainActor (String) -> Void)? = nil,
    solutionModel: (@MainActor () -> String)? = nil
    , sessionStore: ScreenshotQuestionSessionStore? = nil
  ) {
    self.originalImageData = originalImageData
    self.saveQuestion = saveQuestion
    self.onOpenQuestion = onOpenQuestion
    self.solutionModel = solutionModel
    self.webAnswer = webAnswer
    self.onSearchSettings = onSearchSettings
    self.measuredAnswer = measuredAnswer
    self.quickPrompts = quickPrompts
    self.interfaceDefaults = interfaceDefaults
    self.now = now
    let storedZoom = interfaceDefaults.double(forKey: Self.zoomKey)
    self.zoomScale =
      storedZoom.isFinite && storedZoom >= 0.75 && storedZoom <= 1.5 ? CGFloat(storedZoom) : 1
    self.context = context
    self.answer = answer
    self.sessionStore = sessionStore
    self.onModelSettings = onModelSettings
    self.modelPreferences = modelPreferences
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    title = "截图问一问"
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    minSize = NSSize(width: 600, height: 580)
    delegate = self
    buildContent()
    refreshSource()
    applyZoom()
    center()
  }

  func present() {
    isClosed = false
    refreshModels()
    refreshSuggestions()
    refreshSaveControls()
    bringToFront()
    persistCurrentCaptureIfNeeded()
    updateTranscriptWidth()
    makeFirstResponder(question)
  }

  func windowDidResize(_ notification: Notification) { updateTranscriptWidth() }

  func modelConfigurationChanged() {
    refreshModels()
    clearConversation()
    status.stringValue = "问答模型设置已更新，已开始新对话。"
  }

  private func updateTranscriptWidth() {
    contentView?.layoutSubtreeIfNeeded()
    guard let scroll = transcript.enclosingScrollView, scroll.contentSize.width > 0 else { return }
    refreshSuggestionsIfNeeded()
    let width = scroll.contentSize.width
    transcript.setFrameSize(NSSize(width: width, height: transcript.frame.height))
    transcript.textContainer?.containerSize = NSSize(
      width: max(1, width - 2 * transcript.textContainerInset.width),
      height: CGFloat.greatestFiniteMagnitude)
  }

  func updateContext(
    _ newContext: ScreenshotQuestionContext, originalImageData newOriginal: Data? = nil
  ) {
    let changedImage =
      newContext.imageData != context.imageData
      || (newOriginal != nil && newOriginal != originalImageData)
    if changedImage {
      preservePendingCapturePersistence()
      persistenceFollowupScheduled = false
      saveRevision = UUID()
      captureID = UUID().uuidString
      originalImageData = newOriginal
      saveTask = nil  // Explicit saves for the previous capture continue independently.
      isSavingQuestion = false
      savedQuestionID = nil
      completedSolutions.removeAll()
      persistedSolutionIDs.removeAll()
      saveStatus.stringValue = ""
    } else if let newOriginal {
      originalImageData = newOriginal
    }
    refreshSaveControls()
    guard
      newContext.text != context.text || newContext.selectedWord != context.selectedWord
        || changedImage
    else { return }
    cancelAnswer()
    context = newContext
    if sessionStore == nil {
      history.removeAll()
    } else {
      persistCurrentCaptureIfNeeded()
    }
    pendingQuestion = nil
    partialAnswer = ""
    pendingOutcome = ""
    transcript.string = ""
    performance = nil
    refreshPerformance()
    refreshSource()
    status.stringValue = "截图或选词已改变，已开始新的对话。"
  }

  func windowWillClose(_ notification: Notification) {
    preservePendingCapturePersistence()
    isClosed = true
    saveRevision = UUID()
    isSavingQuestion = false
    saveTask = nil
    cancelAnswer()
    sessionPersistenceTask?.cancel()
    quickPromptSettings?.panel.close()
    quickPromptSettings = nil
  }

  private func persistCurrentCaptureIfNeeded() {
    guard let sessionStore, let originalImageData else { return }
    sessionPersistenceTask?.cancel()
    let sessionID = self.sessionID
    let attachmentID = self.sessionAttachmentID
    let context = self.context
    sessionPersistenceTask = Task { [weak self] in
      do {
        let id: String
        if let sessionID {
          id = sessionID
        } else {
          let session = try await sessionStore.create(title: "截图问答")
          id = session.id
          await MainActor.run { self?.sessionID = id }
        }
        let attachment = try await sessionStore.appendAttachment(
          id: id, attachmentID: attachmentID ?? UUID().uuidString,
          imageData: originalImageData, ocrText: context.text)
        await MainActor.run {
          self?.sessionID = id
          self?.sessionAttachmentID = attachment.attachments.last?.id
        }
      } catch {
        // A failed local archive must not interrupt the live question flow.
      }
    }
  }

  override func cancelOperation(_ sender: Any?) { close() }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      close()
      return
    }
    super.keyDown(with: event)
  }

  private func buildContent() {
    let root = NSView()
    contentView = root
    let heading = NSTextField(labelWithString: "围绕截图提问")
    heading.font = .systemFont(ofSize: 17, weight: .semibold)
    let modelSettings = NSButton(title: "模型设置…", target: self, action: #selector(openModelSettings))
    modelSettings.bezelStyle = .rounded
    modelSettings.controlSize = .small
    modelSettings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    modelSettings.imagePosition = .imageOnly
    modelSettings.setAccessibilityLabel("模型设置")
    modelSettings.toolTip = "打开模型设置"
    modelSettings.isHidden = onModelSettings == nil
    sessionButton.target = self
    sessionButton.action = #selector(openSessionMenu)
    sessionButton.bezelStyle = .rounded
    sessionButton.controlSize = .small
    sessionButton.setAccessibilityLabel("问答记录")
    sessionButton.isHidden = sessionStore == nil
    let headingRow = NSStackView(views: [heading, NSView(), sessionButton, modelSettings])
    headingRow.orientation = .horizontal
    headingRow.spacing = 10
    modelPicker.target = self
    modelPicker.action = #selector(selectModel)
    modelPicker.setAccessibilityLabel("问答模型")
    modelPicker.isHidden = modelPreferences == nil
    refreshModels()
    thinkingPicker.setAccessibilityLabel("问答思考强度")
    thinkingPicker.toolTip = ScreenshotQuestionThinking.help
    thinkingPicker.target = self
    thinkingPicker.action = #selector(selectThinking)
    thinkingPicker.isHidden = modelPreferences == nil
    for thinking in ScreenshotQuestionThinking.allCases {
      let item = NSMenuItem(title: thinking.title, action: nil, keyEquivalent: "")
      item.representedObject = thinking.rawValue
      thinkingPicker.menu?.addItem(item)
    }
    refreshThinking()
    let modelRow = NSStackView(views: [modelPicker, thinkingPicker])
    modelRow.spacing = 10
    modelRow.orientation = .horizontal
    modelRow.distribution = .fillEqually
    modelRow.isHidden = modelPreferences == nil
    modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
    modelPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    thinkingPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    modelPicker.cell?.lineBreakMode = .byTruncatingMiddle
    thinkingPicker.cell?.lineBreakMode = .byTruncatingTail
    source.font = .systemFont(ofSize: 13)
    source.textColor = .secondaryLabelColor
    source.maximumNumberOfLines = 3
    source.lineBreakMode = .byWordWrapping
    source.setAccessibilityLabel("提问所参考的原文")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    transcript.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
    transcript.font = .systemFont(ofSize: 16)
    transcript.textColor = .labelColor
    transcript.isEditable = false
    transcript.isSelectable = true
    transcript.isRichText = true
    transcript.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: 1]
    transcript.isHorizontallyResizable = false
    transcript.isVerticallyResizable = true
    transcript.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    transcript.autoresizingMask = [.width]
    transcript.textContainerInset = NSSize(width: 14, height: 12)
    transcript.textContainer?.widthTracksTextView = true
    transcript.textContainer?.heightTracksTextView = false
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    transcript.defaultParagraphStyle = paragraph
    transcript.setAccessibilityLabel("截图问答记录")
    scroll.documentView = transcript
    question.placeholderString = "例如：这个短语在这里是什么意思？"
    question.bezelStyle = .roundedBezel
    question.setAccessibilityLabel("提问内容")
    question.target = self
    question.action = #selector(ask)
    question.font = .systemFont(ofSize: 16)
    askButton.target = self
    askButton.action = #selector(ask)
    askButton.bezelStyle = .rounded
    askButton.controlSize = .large
    // Return belongs to the question field, never to the OCR vocabulary save action.
    askButton.keyEquivalent = ""
    stopButton.target = self
    stopButton.action = #selector(stop)
    stopButton.isEnabled = false
    let clearButton = NSButton(title: "清空对话", target: self, action: #selector(clearConversation))
    for button in [stopButton, clearButton] {
      button.bezelStyle = .rounded
      button.controlSize = .small
    }
    imageCheckbox.target = self
    imageCheckbox.action = #selector(imagePreferenceChanged)
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.maximumNumberOfLines = 2
    suggestions.orientation = .vertical
    suggestions.alignment = .leading
    suggestions.spacing = 6
    performanceLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    performanceLabel.textColor = .secondaryLabelColor
    performanceLabel.maximumNumberOfLines = 2
    performanceLabel.setAccessibilityLabel("回答性能")
    performanceLabel.toolTip =
      "首字 / TTFT：点击提问到首个可见文字（含引擎启动和网络等待）。平均 TPS：服务返回的输出 token 数 ÷ 总耗时，包含等待；输出 token 可能含思考。服务未返回用量时显示 —，不以字符数代替。⌘+ / ⌘− 缩放阅读文字，⌘0 恢复。"
    searchCheckbox.target = self
    searchCheckbox.action = #selector(searchPreferenceChanged)
    searchCheckbox.state = interfaceDefaults.bool(forKey: Self.webSearchEnabledKey) ? .on : .off
    searchCheckbox.setAccessibilityLabel("联网检索")
    searchCheckbox.toolTip = "使用 Tavily 搜索网页，并将检索资料交给所选模型回答。"
    let searchSettings = NSButton(
      title: "检索设置…", target: self, action: #selector(openSearchSettings))
    searchSettings.bezelStyle = .rounded
    searchSettings.controlSize = .small
    searchSettings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    searchSettings.imagePosition = .imageOnly
    searchSettings.setAccessibilityLabel("联网检索设置")
    searchSettings.toolTip = "打开联网检索设置"
    searchSettings.isHidden = onSearchSettings == nil
    let searchControls = NSStackView(views: [searchCheckbox, searchSettings])
    searchControls.orientation = .horizontal
    searchControls.spacing = 10
    searchControls.isHidden = webAnswer == nil
    let input = NSStackView(views: [question, askButton])
    imageCheckbox.controlSize = .small
    searchCheckbox.controlSize = .small
    let controls = NSStackView(views: [
      imageCheckbox, searchControls, NSView(), stopButton, clearButton,
    ])
    for row in [input, controls] {
      row.orientation = .horizontal
      row.spacing = 10
    }
    saveQuestionButton.target = self
    saveQuestionButton.action = #selector(saveCapturedQuestion)
    saveQuestionButton.bezelStyle = .rounded
    saveQuestionButton.setAccessibilityLabel("保存题目原图")
    saveQuestionButton.toolTip = "保存原始截图；无需等待解题。AI 回答单独记录，尚未核实。"
    openQuestionButton.target = self
    openQuestionButton.action = #selector(openSavedQuestion)
    openQuestionButton.bezelStyle = .rounded
    saveStatus.font = .systemFont(ofSize: 12)
    saveStatus.textColor = .secondaryLabelColor
    saveStatus.maximumNumberOfLines = 2
    saveStatus.setAccessibilityLabel("题目保存状态")
    let saveRow = NSStackView(views: [
      saveQuestionButton, openQuestionButton, NSView(),
    ])
    saveRow.orientation = .horizontal
    saveRow.spacing = 10
    saveRow.isHidden = saveQuestion == nil
    saveStatus.isHidden = saveQuestion == nil
    refreshSaveControls()
    let column = NSStackView(views: [
      headingRow, modelRow, source, scroll, suggestions, input, controls, status, performanceLabel,
      saveRow, saveStatus,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 10
    column.setCustomSpacing(16, after: source)
    column.setCustomSpacing(14, after: scroll)
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
      question.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
    ])
    for view in [
      headingRow, modelRow, source, scroll, suggestions, input, status, performanceLabel, controls,
      saveRow, saveStatus,
    ] {
      view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    question.setContentHuggingPriority(.defaultLow, for: .horizontal)
    refreshSuggestions()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command), flags.intersection([.option, .control]).isEmpty {
      switch event.charactersIgnoringModifiers {
      case "+", "=":
        zoomIn(nil)
        return true
      case "-":
        zoomOut(nil)
        return true
      case "0":
        resetZoom(nil)
        return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  @objc func zoomIn(_ sender: Any?) { setZoom(zoomScale + 0.1) }
  @objc func zoomOut(_ sender: Any?) { setZoom(zoomScale - 0.1) }
  @objc func resetZoom(_ sender: Any?) { setZoom(1) }

  private func setZoom(_ scale: CGFloat) {
    zoomScale = min(1.5, max(0.75, scale))
    interfaceDefaults.set(Double(zoomScale), forKey: Self.zoomKey)
    applyZoom()
  }

  private func applyZoom() {
    source.font = .systemFont(ofSize: 13 * zoomScale)
    question.font = .systemFont(ofSize: 16 * zoomScale)
    transcript.font = .systemFont(ofSize: 16 * zoomScale)
    if let editor = question.currentEditor() { editor.font = question.font }
    if let storage = transcript.textStorage, storage.length > 0 {
      storage.addAttribute(
        .font, value: NSFont.systemFont(ofSize: 16 * zoomScale),
        range: NSRange(location: 0, length: storage.length))
    }
    updateTranscriptWidth()
    updateMinimumHeight()
    refreshPerformance()
  }

  private func refreshPerformance() {
    let zoom = "缩放 \(Int((zoomScale * 100).rounded()))%"
    guard let performance else {
      performanceLabel.stringValue = "首字 — · 平均 TPS — · 总耗时 — · " + zoom
      return
    }
    let end = performance.completedAt ?? now()
    let elapsed = max(0, end - performance.startedAt)
    let latency =
      performance.firstTextAt.map { String(format: "%.2f s", max(0, $0 - performance.startedAt)) }
      ?? "—"
    let rate =
      performance.usage?.outputTokens.flatMap { tokens -> String? in
        guard elapsed > 0 else { return nil }
        return String(format: "%.1f", Double(tokens) / elapsed)
      } ?? "—"
    let tokens = performance.usage?.outputTokens.map { " · 输出 \($0) tokens" } ?? ""
    performanceLabel.stringValue =
      "首字 \(latency) · 平均 TPS \(rate) · 总耗时 \(String(format: "%.2f s", elapsed))\(tokens) · \(zoom)"
  }

  private func refreshSuggestionsIfNeeded() {
    let width = suggestions.bounds.width
    if abs(width - suggestionWidth) > 1 { refreshSuggestions() }
  }

  func refreshSuggestions() {
    suggestionWidth = suggestions.bounds.width
    for view in suggestions.arrangedSubviews {
      suggestions.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    suggestionButtons = quickPrompts.prompts.map { prompt in
      let button = NSButton(title: prompt.title, target: self, action: #selector(askSuggestion(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(prompt.id)
      button.toolTip = prompt.prompt
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.isEnabled = !isAnswering
      return button
    }
    let edit = NSButton(title: "编辑快捷问题…", target: self, action: #selector(editQuickPrompts))
    edit.bezelStyle = .rounded
    edit.controlSize = .small
    let available = max(1, suggestionWidth > 0 ? suggestionWidth : 616)
    var row = NSStackView()
    row.spacing = 8
    var used: CGFloat = 0
    for button in suggestionButtons + [edit] {
      // Rounded AppKit buttons draw beyond their alignment rectangle.
      let width = button.intrinsicContentSize.width + 16
      if used > 0 && used + 8 + width > available {
        suggestions.addArrangedSubview(row)
        row = NSStackView()
        row.spacing = 8
        used = 0
      }
      row.addArrangedSubview(button)
      used += (used > 0 ? 8 : 0) + width
    }
    suggestions.addArrangedSubview(row)
    updateMinimumHeight()
  }

  private func updateMinimumHeight() {
    let extraRows = max(0, suggestions.arrangedSubviews.count - 1)
    let required =
      580 + (saveQuestion == nil ? 0 : 64) + CGFloat(extraRows) * 28 + max(0, zoomScale - 1) * 80
    minSize = NSSize(width: 600, height: required)
    if frame.height < required {
      var expanded = frame
      expanded.origin.y -= required - expanded.height
      expanded.size.height = required
      setFrame(expanded, display: true)
    }
  }

  @objc private func editQuickPrompts() {
    if let quickPromptSettings {
      quickPromptSettings.present()
      return
    }
    let editor = ScreenshotQuestionQuickPromptSettings(preferences: quickPrompts) { [weak self] in
      self?.refreshSuggestions()
    }
    quickPromptSettings = editor
    editor.present()
  }

  private func refreshModels() {
    guard let modelPreferences else { return }
    refreshThinking()
    modelPicker.removeAllItems()
    modelPicker.addItem(withTitle: "沿用取词模型")
    for profile in modelPreferences.profiles {
      let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
      item.representedObject = profile.id
      modelPicker.menu?.addItem(item)
    }
    if let id = modelPreferences.selectedProfileID {
      if let item = modelPicker.itemArray.first(where: { $0.representedObject as? String == id }) {
        modelPicker.select(item)
      } else {
        modelPicker.addItem(withTitle: "模型配置不可用，请打开模型设置")
        modelPicker.lastItem?.representedObject = id
        modelPicker.select(modelPicker.lastItem)
      }
    } else {
      modelPicker.selectItem(at: 0)
    }
  }

  private func refreshThinking() {
    let value = modelPreferences?.selectedThinking ?? .off
    thinkingPicker.select(
      thinkingPicker.itemArray.first { $0.representedObject as? String == value.rawValue })
  }

  @objc private func selectThinking() {
    guard let modelPreferences,
      let raw = thinkingPicker.selectedItem?.representedObject as? String,
      let value = ScreenshotQuestionThinking(rawValue: raw)
    else { return }
    selectModel()
    guard value != modelPreferences.selectedThinking else { return }
    modelPreferences.setThinking(value)
    modelConfigurationChanged()
    status.stringValue = "已更新思考强度，开始新对话。"
  }

  /// OCR line endings describe the screenshot's physical lines, not paragraph layout.
  /// Reflow only the preview; keep the original context byte-for-byte for the model.
  static func sourcePreview(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  @objc private func selectModel() {
    guard let modelPreferences else { return }
    let id = modelPicker.selectedItem?.representedObject as? String
    guard id != modelPreferences.selectedProfileID else { return }
    modelPreferences.selectProfile(id)
    modelConfigurationChanged()
    status.stringValue = "已切换模型，开始新对话。"
  }

  private func refreshSource() {
    let selected = context.selectedWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
    source.stringValue =
      (selected.isEmpty ? "" : "选中：\(selected)\n")
      + (text.isEmpty ? "没有识别到文字，将参考原截图。" : Self.sourcePreview(text))
    imageCheckbox.isHidden = context.imageData == nil
    imageCheckbox.state = text.isEmpty && context.imageData != nil ? .on : .off
    imageCheckbox.isEnabled = !text.isEmpty
  }

  @objc private func openSessionMenu() {
    guard let sessionStore else { return }
    let menu = NSMenu()
    let newItem = NSMenuItem(title: "新建问答会话", action: #selector(newSession), keyEquivalent: "")
    newItem.target = self
    menu.addItem(newItem)
    menu.addItem(.separator())
    Task { [weak self] in
      guard let self else { return }
      let sessions = (try? await sessionStore.list()) ?? []
      await MainActor.run {
        for session in sessions.prefix(12) {
          let item = NSMenuItem(title: session.title, action: #selector(self.restoreSession(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = session.id
          item.state = session.id == self.sessionID ? .on : .off
          menu.addItem(item)
        }
        if sessions.isEmpty {
          let empty = menu.addItem(withTitle: "暂无已保存会话", action: nil, keyEquivalent: "")
          empty.isEnabled = false
        }
        let point = NSPoint(x: 0, y: self.sessionButton.bounds.height)
        menu.popUp(positioning: nil, at: point, in: self.sessionButton)
      }
    }
  }

  @objc private func newSession() {
    sessionID = nil
    sessionAttachmentID = nil
    history.removeAll()
    transcript.string = ""
    status.stringValue = "已新建问答会话。"
  }

  @objc private func restoreSession(_ sender: NSMenuItem) {
    guard let sessionStore, let id = sender.representedObject as? String else { return }
    Task { [weak self] in
      do {
        let session = try await sessionStore.session(id: id)
        guard let attachment = session.attachments.last else { return }
        let image = try await sessionStore.attachmentData(sessionID: id, attachmentID: attachment.id)
        await MainActor.run {
          guard let self else { return }
          self.sessionID = id
          self.sessionAttachmentID = attachment.id
          self.originalImageData = image
          self.context = ScreenshotQuestionContext(
            text: attachment.ocrText, selectedWord: nil, imageData: image)
          self.history = session.turns.map {
            ScreenshotQuestionTurn(question: $0.question, answer: $0.answer)
          }
          self.refreshSource()
          self.renderTranscript()
          self.status.stringValue = "已恢复“(session.title)”；可以继续追问或追加截图。"
        }
      } catch {
        await MainActor.run { self?.status.stringValue = "恢复会话失败：(error.localizedDescription)" }
      }
    }
  }

  @objc private func askSuggestion(_ sender: NSButton) {
    guard !isAnswering else { return }
    guard let id = sender.identifier?.rawValue,
      let prompt = quickPrompts.prompts.first(where: { $0.id == id })
    else { return }
    if context.imageData != nil && (prompt.id == "solve" || prompt.title == "解题") {
      imageCheckbox.state = .on
    }
    question.stringValue = prompt.prompt
    ask()
  }

  @objc private func ask() {
    // Native popup selection can become visible before its action is delivered.
    selectModel()
    selectThinking()
    let submitted = question.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !submitted.isEmpty, !isAnswering, !isClosed else { return }
    guard
      !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || context.imageData != nil
    else {
      status.stringValue = "当前截图没有可提问的内容，请重新截图。"
      return
    }
    let snapshot = ScreenshotQuestionContext(
      text: context.text, selectedWord: context.selectedWord,
      imageData: imageCheckbox.state == .on ? context.imageData : nil)
    let searchEnabled = webAnswer != nil && searchCheckbox.state == .on
    let previous = history
    let modelSnapshot = solutionModel?() ?? "未知模型"
    let requestID = UUID()
    revision = requestID
    pendingQuestion = submitted
    partialAnswer = ""
    pendingOutcome = ""
    question.stringValue = ""
    isAnswering = true
    performance = ScreenshotQuestionPerformance(startedAt: now())
    refreshPerformance()
    for button in suggestionButtons { button.isEnabled = false }
    performanceUpdateTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        guard let self, self.isAnswering, self.revision == requestID, !self.isClosed else { return }
        self.refreshPerformance()
      }
    }
    askButton.isEnabled = false
    stopButton.isEnabled = true
    status.stringValue = "正在回答… 可以先输入下一条问题。"
    renderTranscript()
    answerTask = Task { [weak self] in
      guard let self, self.revision == requestID, !self.isClosed, !Task.isCancelled else { return }
      do {
        let onPartial: @MainActor @Sendable (String) -> Void = { [weak self] partial in
          guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
            return
          }
          let firstText =
            self.performance?.firstTextAt == nil
            && !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          if firstText {
            self.performance?.firstTextAt = self.now()
            self.refreshPerformance()
          }
          self.partialAnswer = partial
          if firstText {
            self.renderTranscript()
          } else {
            self.scheduleTranscriptUpdate()
          }
        }
        let result: String
        let onUsage: @MainActor @Sendable (ScreenshotQuestionUsage) -> Void = { [weak self] usage in
          guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
            return
          }
          self.performance?.usage = usage
          self.refreshPerformance()
        }
        if let webAnswer = self.webAnswer {
          result = try await webAnswer(
            submitted, snapshot, previous, searchEnabled, onUsage,
            { [weak self] stage in
              guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
                return
              }
              self.status.stringValue = stage.title
            }, onPartial)
        } else if let measuredAnswer = self.measuredAnswer {
          result = try await measuredAnswer(
            submitted, snapshot, previous,
            { [weak self] usage in
              guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
                return
              }
              self.performance?.usage = usage
              self.refreshPerformance()
            }, onPartial)
        } else {
          result = try await self.answer(submitted, snapshot, previous, onPartial)
        }
        guard self.revision == requestID, !self.isClosed, !Task.isCancelled else { return }
        self.history.append(ScreenshotQuestionTurn(question: submitted, answer: result))
        if let sessionStore, let sessionID = self.sessionID {
          let attachmentIDs = self.sessionAttachmentID.map { [$0] } ?? []
          _ = try? await sessionStore.appendTurn(
            id: sessionID, question: submitted, answer: result, model: modelSnapshot,
            attachmentIDs: attachmentIDs)
        }
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.completedSolutions.append(
            MathQuestionSolution(
              id: requestID.uuidString, question: submitted, answer: result,
              model: modelSnapshot, createdAt: Date()))
        }
        self.pendingQuestion = nil
        self.partialAnswer = ""
        self.renderTranscript()
        self.finishAnswer(status: "回答完成，可继续追问。")
        self.refreshSaveControls()
        if self.savedQuestionID != nil { self.saveCapturedQuestion() }
      } catch {
        guard self.revision == requestID, !self.isClosed, !Task.isCancelled else { return }
        self.pendingOutcome = "回答失败，以上内容尚未完成。"
        self.restoreQuestionIfEmpty()
        self.renderTranscript()
        self.finishAnswer(status: "回答失败：\(error.localizedDescription) 可重新提问。")
      }
    }
  }

  private func refreshSaveControls() {
    saveQuestionButton.isHidden = saveQuestion == nil
    saveQuestionButton.isEnabled =
      saveQuestion != nil && originalImageData != nil && !isSavingQuestion
    saveQuestionButton.title =
      isSavingQuestion ? "正在保存…" : (savedQuestionID == nil ? "保存题目" : "已保存题目")
    openQuestionButton.isHidden = savedQuestionID == nil || onOpenQuestion == nil
    if saveQuestion != nil && originalImageData == nil {
      saveStatus.stringValue = "缺少原始截图，请重新截图后保存。"
    }
  }

  @objc private func openSavedQuestion() {
    guard let savedQuestionID else { return }
    onOpenQuestion?(savedQuestionID)
  }

  /// Explicitly saved captures must retain already-completed answers even after their UI goes away.
  /// Capture the request now: the next screenshot must never become part of this follow-up.
  private func preservePendingCapturePersistence() {
    guard !persistenceFollowupScheduled, isSavingQuestion, let previousSave = saveTask,
      let saveQuestion, let originalImageData,
      completedSolutions.contains(where: { !persistedSolutionIDs.contains($0.id) })
    else { return }
    persistenceFollowupScheduled = true
    let request = MathQuestionSaveRequest(
      captureID: captureID, imageData: originalImageData, ocrText: context.text,
      solutions: completedSolutions)
    Task {
      await previousSave.value
      // This task intentionally survives window closure; the immutable capture is the save target.
      do {
        _ = try await saveQuestion(request)
      } catch {
        // The source window has gone away; retain a local diagnostic without logging its contents.
        NSLog("题目完整回答追加保存失败：%@", error.localizedDescription)
      }
    }
  }

  @objc private func saveCapturedQuestion() {
    guard !isClosed, !isSavingQuestion, let saveQuestion, let originalImageData else { return }
    let pending = completedSolutions.filter { !persistedSolutionIDs.contains($0.id) }
    if savedQuestionID != nil && pending.isEmpty { return }
    let request = MathQuestionSaveRequest(
      captureID: captureID, imageData: originalImageData, ocrText: context.text,
      solutions: completedSolutions)
    let generation = saveRevision
    persistenceFollowupScheduled = false
    isSavingQuestion = true
    saveStatus.stringValue = savedQuestionID == nil ? "正在保存题目原图…" : "正在追加完整回答…"
    refreshSaveControls()
    saveTask = Task { [weak self] in
      do {
        let record = try await saveQuestion(request)
        guard let self, self.saveRevision == generation, !self.isClosed else { return }
        self.savedQuestionID = record.id
        self.persistedSolutionIDs.formUnion(request.solutions.map(\.id))
        self.isSavingQuestion = false
        self.saveTask = nil
        self.saveStatus.stringValue =
          self.completedSolutions.isEmpty
          ? "题目已保存 · 暂无解题过程"
          : "题目已保存 · AI 回答已附存，尚未核实"
        self.refreshSaveControls()
        // A completed answer may arrive while the original image is being persisted.
        if self.completedSolutions.contains(where: { !self.persistedSolutionIDs.contains($0.id) }) {
          self.saveCapturedQuestion()
        }
      } catch {
        guard let self, self.saveRevision == generation, !self.isClosed else { return }
        self.isSavingQuestion = false
        self.saveTask = nil
        self.saveStatus.stringValue = "保存失败：\(error.localizedDescription) · 可点击重试"
        self.saveQuestionButton.title = "重试保存题目"
        self.refreshSaveControls()
        self.saveQuestionButton.title = "重试保存题目"
      }
    }
  }

  private func scheduleTranscriptUpdate() {
    guard transcriptUpdateTask == nil else { return }
    let requestID = revision
    transcriptUpdateTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
      guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else { return }
      self.transcriptUpdateTask = nil
      self.renderTranscript()
    }
  }

  private func renderTranscript() {
    transcriptUpdateTask?.cancel()
    transcriptUpdateTask = nil
    var parts = history.map { "你：\($0.question)\n\n回答：\($0.answer)" }
    if let pendingQuestion {
      let answerText =
        partialAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? (pendingOutcome.isEmpty ? "正在思考…" : "没有生成完整回答。") : partialAnswer
      parts.append(
        "你：\(pendingQuestion)\n\n回答：\(answerText)"
          + (pendingOutcome.isEmpty ? "" : "\n\n[\(pendingOutcome)]"))
    }
    updateTranscriptWidth()
    let rendered = NSMutableAttributedString(
      string: parts.joined(separator: "\n\n──────────\n\n"),
      attributes: [
        .font: NSFont.systemFont(ofSize: 16 * zoomScale), .foregroundColor: NSColor.labelColor,
        .paragraphStyle: transcript.defaultParagraphStyle ?? NSParagraphStyle.default,
      ])
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let range = NSRange(location: 0, length: rendered.length)
      detector.enumerateMatches(in: rendered.string, range: range) { match, _, _ in
        guard let match, let url = match.url,
          ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        rendered.addAttribute(.link, value: url, range: match.range)
      }
    }
    transcript.textStorage?.setAttributedString(rendered)
    transcript.scrollToEndOfDocument(nil)
  }

  private func finishAnswer(status message: String) {
    if isAnswering { performance?.completedAt = now() }
    answerTask = nil
    performanceUpdateTask?.cancel()
    performanceUpdateTask = nil
    isAnswering = false
    for button in suggestionButtons { button.isEnabled = true }
    refreshPerformance()
    askButton.isEnabled = true
    stopButton.isEnabled = false
    status.stringValue = message
  }

  private func cancelAnswer() {
    revision = UUID()
    answerTask?.cancel()
    if isAnswering {
      pendingOutcome = "已停止，以上内容尚未完成。"
      restoreQuestionIfEmpty()
      renderTranscript()
    }
    finishAnswer(status: "已停止回答，可以继续提问。")
  }

  private func restoreQuestionIfEmpty() {
    if question.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let pendingQuestion
    {
      question.stringValue = pendingQuestion
    }
  }

  @objc private func stop() { cancelAnswer() }

  func searchConfigurationChanged() {
    clearConversation()
    status.stringValue = "检索设置已更新，已开始新对话。"
  }

  @objc private func searchPreferenceChanged() {
    interfaceDefaults.set(searchCheckbox.state == .on, forKey: Self.webSearchEnabledKey)
    clearConversation()
    status.stringValue = searchCheckbox.state == .on ? "新对话将联网检索，并显示来源链接。" : "新对话将直接使用模型回答。"
  }

  @objc private func openSearchSettings() { onSearchSettings?() }

  @objc private func openModelSettings() { onModelSettings?() }

  @objc private func clearConversation() {
    cancelAnswer()
    history.removeAll()
    pendingQuestion = nil
    partialAnswer = ""
    pendingOutcome = ""
    transcript.string = ""
    performance = nil
    refreshPerformance()
    status.stringValue = "已清空对话，可以重新提问。"
  }

  @objc private func imagePreferenceChanged() {
    clearConversation()
    status.stringValue = imageCheckbox.state == .on ? "新对话将同时参考原截图。" : "新对话将参考识别文字。"
  }
}
