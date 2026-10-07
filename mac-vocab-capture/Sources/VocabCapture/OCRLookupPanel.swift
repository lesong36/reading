import AppKit

@MainActor
final class OCRLookupPanel: ScreenshotPanel, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
  private let original = OCRTextView()
  private let targetWord = NSTextField()
  private let meaning = NSTextField(wrappingLabelWithString: "")
  private let metadata = NSTextField(wrappingLabelWithString: "")
  private let sentence = NSTextField(wrappingLabelWithString: "")
  private let feedback = NSTextField(wrappingLabelWithString: "点选上方单词，即可查看语境释义。")
  private let spinner = NSProgressIndicator()
  private let editButton = NSButton(title: "修正原文", target: nil, action: nil)
  private let saveButton = NSButton(title: "加入生词本 ↵", target: nil, action: nil)
  private let retryButton = NSButton(title: "重新查询", target: nil, action: nil)
  private var selectionRange: NSRange?
  private var lookupTask: Task<Void, Never>?
  private var savedRevision: UUID?
  private var canSave: Bool { !isSaving && savedRevision != revision && result != nil && resultSelection != nil }
  private var saveTask: Task<Void, Never>?
  private var revision = UUID()
  private var result: DictionaryResult?
  private var resultSelection: SelectedText?
  private var pendingSelection: SelectedText?
  private var isSaving = false
  private var isChangingSelection = false
  private let lookup:
    (SelectedText, @escaping @MainActor @Sendable (String) -> Void) async throws -> DictionaryResult
  private let save: (SelectedText, DictionaryResult) async throws -> String
  private let measuredAsk: ScreenshotQuestionMeasuredAnswer?
  private let webAsk: ScreenshotQuestionWebAnswer?
  private let onSearchSettings: (() -> Void)?
  private let ask: ScreenshotQuestionAnswer?
  private let screenshotImageData: Data?
  private let onQuestionSettings: (() -> Void)?
  private let questionPreferences: ScreenshotQuestionPreferences?
  private var questionPanel: ScreenshotQuestionPanel?
  var onRetake: (() -> Void)?

  init(
    text: String,
    lookup:
      @escaping (SelectedText, @escaping @MainActor @Sendable (String) -> Void) async throws ->
      DictionaryResult,
    save: @escaping (SelectedText, DictionaryResult) async throws -> String,
    imageData: Data? = nil,
    ask: ScreenshotQuestionAnswer? = nil,
    onQuestionSettings: (() -> Void)? = nil,
    questionPreferences: ScreenshotQuestionPreferences? = nil,
    measuredAsk: ScreenshotQuestionMeasuredAnswer? = nil,
    webAsk: ScreenshotQuestionWebAnswer? = nil,
    onSearchSettings: (() -> Void)? = nil
  ) {
    self.lookup = lookup
    self.save = save
    self.screenshotImageData = imageData
    self.measuredAsk = measuredAsk
    self.webAsk = webAsk
    self.onSearchSettings = onSearchSettings
    self.ask = ask
    self.onQuestionSettings = onQuestionSettings
    self.questionPreferences = questionPreferences
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    title = "截图取词"
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    minSize = NSSize(width: 540, height: 620)
    delegate = self
    buildContent(text: text)
    center()
  }

  func present() {
    bringToFront()
    makeFirstResponder(original)
  }

  func windowWillClose(_ notification: Notification) {
    revision = UUID()
    lookupTask?.cancel()
    questionPanel?.close()
    questionPanel = nil
    // An explicitly requested save finishes even if the user closes the window.
  }

  override func cancelOperation(_ sender: Any?) { close() }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      close()
      return
    }
    if event.keyCode == 36 || event.keyCode == 76, !original.isEditable {
      commitTargetWord()
      return
    }
    super.keyDown(with: event)
  }

  private func buildContent(text: String) {
    let root = NSView()
    contentView = root
    let heading = label("在原文中取词", size: 22, weight: .semibold)
    let hint = label("单击选词 · 拖动选词组 · 回车保存 · Esc 关闭", size: 13, color: .secondaryLabelColor)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    original.string = text
    original.font = .systemFont(ofSize: 18)
    original.textColor = .labelColor
    original.isEditable = false
    original.isSelectable = true
    original.isRichText = false
    original.isHorizontallyResizable = false
    original.isVerticallyResizable = true
    original.autoresizingMask = [.width]
    original.textContainerInset = NSSize(width: 14, height: 12)
    original.textContainer?.widthTracksTextView = true
    original.delegate = self
    scroll.documentView = original
    targetWord.placeholderString = "点击原文选词；也可在这里修正选词"
    targetWord.font = .systemFont(ofSize: 21, weight: .semibold)
    targetWord.delegate = self
    targetWord.target = self
    targetWord.action = #selector(commitTargetWord)
    targetWord.setAccessibilityLabel("目标单词或词组")
    original.setAccessibilityLabel("识别原文")
    meaning.font = .systemFont(ofSize: 23, weight: .medium)
    metadata.font = .systemFont(ofSize: 13)
    metadata.textColor = .secondaryLabelColor
    sentence.font = .systemFont(ofSize: 14)
    sentence.textColor = .secondaryLabelColor
    sentence.maximumNumberOfLines = 4
    feedback.font = .systemFont(ofSize: 13)
    feedback.textColor = .secondaryLabelColor
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    editButton.target = self
    editButton.action = #selector(toggleEditing)
    retryButton.target = self
    retryButton.action = #selector(queryCorrectedWord)
    retryButton.isHidden = true
    saveButton.target = self
    saveButton.action = #selector(saveWord)
    saveButton.keyEquivalent = "\r"
    saveButton.isEnabled = false
    saveButton.bezelStyle = .rounded
    saveButton.controlSize = .large
    let retake = NSButton(title: "重新截图", target: self, action: #selector(retakeScreenshot))
    let done = NSButton(title: "完成", target: self, action: #selector(finish))
    done.keyEquivalent = "\u{1b}"
    let headerRow = NSStackView(views: [
      label("识别原文", size: 12, color: .secondaryLabelColor), NSView(), editButton,
    ])
    let statusRow = NSStackView(views: [spinner, feedback])
    let askButton = NSButton(title: "问一问…", target: self, action: #selector(openQuestions))
    askButton.isHidden = ask == nil
    let footer = NSStackView(views: [retake, done, askButton, NSView(), saveButton])
    for row in [headerRow, statusRow, footer] {
      row.orientation = .horizontal
      row.spacing = 10
    }
    let column = NSStackView(views: [
      heading, hint, headerRow, scroll, targetWord,
      metadata, meaning, label("原句语境", size: 12, color: .tertiaryLabelColor),
      sentence, retryButton, NSView(), statusRow, footer,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
      scroll.heightAnchor.constraint(equalToConstant: 200),
    ])
    for item in [headerRow, scroll, targetWord, metadata, meaning, sentence, statusRow, footer] {
      item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    original.onCommitSelection = { [weak self] in self?.readSelection() }
    original.onConfirm = { [weak self] in self?.commitTargetWord() }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      feedback.stringValue = "未识别到文字，点击“问一问”可根据截图提问。"
    }
  }

  private func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor
  ) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    return label
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard !original.isTrackingMouse else { return }
    readSelection()
  }

  private func readSelection() {
    guard !original.isEditable, !isChangingSelection,
      let range = OCRSelection(text: original.string).snappedRange(original.selectedRange()),
      let selection = OCRSelection(text: original.string).selection(in: range)
    else { return }
    if selectionRange == range, targetWord.stringValue == selection.word { return }
    selectionRange = range
    isChangingSelection = true
    original.setSelectedRange(range)
    isChangingSelection = false
    targetWord.stringValue = selection.word
    beginLookup()
  }

  func controlTextDidChange(_ notification: Notification) {
    invalidateResult()
    updateQuestions()
    feedback.stringValue = "选词已修改，按回车或点击“重新查询”。"
    retryButton.isHidden = false
  }

  func textDidChange(_ notification: Notification) {
    invalidateResult()
    updateQuestions()
  }

  private func invalidateResult() {
    revision = UUID()
    lookupTask?.cancel()
    pendingSelection = nil
    result = nil
    resultSelection = nil
    saveButton.isEnabled = false
    meaning.stringValue = ""
    metadata.stringValue = ""
    spinner.stopAnimation(nil)
  }

  @objc private func toggleEditing() {
    guard !isSaving else { return }
    invalidateResult()
    original.isEditable.toggle()
    editButton.title = original.isEditable ? "完成修正" : "修正原文"
    if original.isEditable {
      feedback.stringValue = "直接修改识别原文，完成后重新点选目标词。"
      makeFirstResponder(original)
    } else {
      selectionRange = nil
      targetWord.stringValue = ""
      sentence.stringValue = ""
      feedback.stringValue = "原文已修正，请重新点选单词。"
      original.setSelectedRange(NSRange(location: 0, length: 0))
    }
    updateQuestions()
  }

  @objc private func queryCorrectedWord() { beginLookup() }

  @objc private func commitTargetWord() {
    if result != nil { saveWord() } else { beginLookup() }
  }

  private func beginLookup() {
    guard !original.isEditable, !isSaving else { return }
    let word = targetWord.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty, word.rangeOfCharacter(from: .letters) != nil,
      let range = selectionRange,
      let selected = OCRSelection(text: original.string).selection(in: range)
    else {
      feedback.stringValue = "请先在原文中选词。"
      return
    }
    let selection = SelectedText(word: word, context: selected.context)
    updateQuestions()
    if pendingSelection?.word == selection.word, pendingSelection?.context == selection.context {
      return
    }
    invalidateResult()
    pendingSelection = selection
    let startedAt = Date()
    let token = revision
    sentence.stringValue = selection.context
    feedback.stringValue = "正在查询“\(word)”…"
    retryButton.isHidden = true
    spinner.startAnimation(nil)
    lookupTask = Task { [weak self] in
      guard let self else { return }
      do {
        let value = try await self.lookup(selection) { [weak self] preview in
          guard let self, self.revision == token else { return }
          self.meaning.stringValue = preview
          self.feedback.stringValue = "释义已显示，正在补充词性与音标…"
          ContextDebugLog.write(
            "界面显示释义：\(Int(Date().timeIntervalSince(startedAt) * 1_000)) ms", word: selection.word)
        }
        guard !Task.isCancelled, self.revision == token else { return }
        self.pendingSelection = nil
        self.result = value
        self.resultSelection = selection
        self.meaning.stringValue = value.meaning
        self.metadata.stringValue = [value.partOfSpeech, value.pronunciation, value.note].filter {
          !$0.isEmpty
        }.joined(separator: " · ")
        self.feedback.stringValue = "回车加入生词本，或继续点选其他单词。"
        self.saveButton.isEnabled = true
        self.spinner.stopAnimation(nil)
      } catch {
        guard !Task.isCancelled, self.revision == token else { return }
        self.pendingSelection = nil
        self.meaning.stringValue = ""
        self.spinner.stopAnimation(nil)
        self.feedback.stringValue = "查询失败：\(error.localizedDescription)"
        self.retryButton.isHidden = false
      }
    }
  }

  @objc private func saveWord() {
    guard canSave, let result, let selection = resultSelection else { return }
    isSaving = true
    saveButton.isEnabled = false
    original.isSelectable = false
    targetWord.isEnabled = false
    editButton.isEnabled = false
    spinner.startAnimation(nil)
    feedback.stringValue = "正在保存…"
    let token = revision
    saveTask = Task { [weak self] in
      guard let self else { return }
      do {
        let message = try await self.save(selection, result)
        guard self.revision == token else {
          self.finishSaving()
          return
        }
        self.savedRevision = token
        self.feedback.stringValue = message
      } catch {
        guard self.revision == token else {
          self.finishSaving()
          return
        }
        self.feedback.stringValue = "保存失败：\(error.localizedDescription)"
        self.saveButton.isEnabled = true
      }
      self.finishSaving()
    }
  }

  private func finishSaving() {
    isSaving = false
    original.isSelectable = true
    targetWord.isEnabled = true
    editButton.isEnabled = true
    spinner.stopAnimation(nil)
  }

  @objc private func retakeScreenshot() {
    guard !isSaving else { return }
    questionPanel?.orderOut(nil)
    onRetake?()
  }

  @objc private func finish() { close() }

  func hideForScreenshot() -> () -> Void {
    let wordWasVisible = isVisible
    let question = questionPanel
    let questionWasVisible = question?.isVisible == true
    orderOut(nil)
    question?.orderOut(nil)
    return { [weak self] in
      if wordWasVisible { self?.present() }
      if questionWasVisible { question?.present() }
    }
  }

  func questionModelConfigurationChanged() { questionPanel?.modelConfigurationChanged() }

  func questionSearchConfigurationChanged() { questionPanel?.searchConfigurationChanged() }

  private var questionContext: ScreenshotQuestionContext {
    let word = targetWord.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return ScreenshotQuestionContext(
      text: original.string, selectedWord: word.isEmpty ? nil : word,
      imageData: screenshotImageData)
  }

  private func updateQuestions() { questionPanel?.updateContext(questionContext) }

  @objc private func openQuestions() {
    guard let ask else { return }
    if let questionPanel {
      questionPanel.updateContext(questionContext)
      questionPanel.present()
      return
    }
    let panel = ScreenshotQuestionPanel(
      context: questionContext, answer: ask, onModelSettings: onQuestionSettings,
      modelPreferences: questionPreferences, measuredAnswer: measuredAsk,
      webAnswer: webAsk, onSearchSettings: onSearchSettings)
    questionPanel = panel
    panel.present()
  }
}

/// Let AppKit perform ordinary drag/double-click selection, then expand a
/// single click to its word. Query only after mouse tracking has finished.
private final class OCRTextView: NSTextView {
  var onCommitSelection: (() -> Void)?
  var onConfirm: (() -> Void)?
  private(set) var isTrackingMouse = false

  override func keyDown(with event: NSEvent) {
    if !isEditable, event.keyCode == 36 || event.keyCode == 76 {
      onConfirm?()
      return
    }
    super.keyDown(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    isTrackingMouse = true
    super.mouseDown(with: event)
    if !isEditable, selectedRange().length == 0,
      let layoutManager, let textContainer
    {
      let pointer = convert(event.locationInWindow, from: nil)
      let point = NSPoint(
        x: pointer.x - textContainerOrigin.x, y: pointer.y - textContainerOrigin.y)
      let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
      if glyph < layoutManager.numberOfGlyphs,
        layoutManager.boundingRect(
          forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer
        ).contains(point),
        let word = OCRSelection(text: string).wordRange(
          at: layoutManager.characterIndexForGlyph(at: glyph))
      {
        setSelectedRange(word)
      }
    }
    isTrackingMouse = false
    if !isEditable { onCommitSelection?() }
  }
}
