import AppKit

/// Sheet editors keep user judgements separate from the original model response.
@MainActor
final class MathQuestionReviewPanel: NSObject {
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let questionID: String
  private let onSave: () -> Void
  private let onNext: (() -> Void)?
  private let nextButton = NSButton(title: "保存并下一题", target: nil, action: nil)
  private let questionImage = NSImageView()
  private let questionImageStatus = NSTextField(wrappingLabelWithString: "正在读取题目原图…")
  private var questionImageRevision = UUID()
  private var questionImageTask: Task<Void, Never>?
  private let solutions: [MathQuestionSolution]
  private let references: [MathReferenceAnswer]
  private let answerPicker = NSPopUpButton()
  private let referencePicker = NSPopUpButton()
  private let decision = NSPopUpButton()
  private let scope = NSPopUpButton()
  private let source = NSTextField()
  private let note = NSTextField()
  private let editor = NSTextView()
  private let answer = NSTextView()
  private let referenceText = NSTextView()
  private let image = NSImageView()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "保存", target: nil, action: nil)
  private let imageButton = NSButton(title: "添加答案图片…", target: nil, action: nil)
  private var imageData: Data?
  private var imageRevision = UUID()
  private var isSaving = false
  private var isInvalidated = false
  private var mutationTask: Task<Void, Never>?
  private var originalPanel: ScreenshotPanel?

  init(
    store: MathQuestionStore, questionID: String, solutions: [MathQuestionSolution] = [],
    references: [MathReferenceAnswer] = [], pendingSolutionIDs: Set<String>? = nil, onNext: (() -> Void)? = nil, onSave: @escaping () -> Void
  ) {
    self.store = store
    self.questionID = questionID
    self.solutions = solutions
    self.references = references
    self.onSave = onSave
    self.onNext = onNext
    panel = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: solutions.isEmpty ? 760 : 1100, height: solutions.isEmpty ? 760 : 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = solutions.isEmpty ? "添加参考答案" : "核验 AI 回答"
    panel.minSize = NSSize(width: solutions.isEmpty ? 660 : 900, height: solutions.isEmpty ? 720 : 780)
    panel.isReleasedWhenClosed = false
    buildContent()
    if !solutions.isEmpty {
      answerPicker.selectItem(at: solutions.firstIndex { pendingSolutionIDs?.contains($0.id) ?? ($0.verificationStatus == "unverified") } ?? 0)
      selectAnswer()
      loadQuestionImage()
    }
    selectReference()
  }

  func present(on owner: NSWindow) { owner.beginSheet(panel) }
  func prepareForLibraryRestore() async {
    isInvalidated = true
    imageRevision = UUID()
    dismiss()
    await mutationTask?.value
  }

  private func buildContent() {
    let heading = NSTextField(labelWithString: panel.title)
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let explanation = NSTextField(
      wrappingLabelWithString: solutions.isEmpty
        ? "输入答案或添加答案图片。参考答案单独保存，添加后不会自动确认 AI 回答。"
        : "审核为可选操作，无需逐题完成。按实际检查范围确认或标记有误，即可保存并下一题；仅确认答案不会视为确认过程。")
    explanation.textColor = .secondaryLabelColor
    var rows: [NSView] = [heading, explanation]
    scope.addItems(withTitles: ["最终答案", "答案及解题过程", "指定小问（在备注中说明）"])
    scope.setAccessibilityLabel("核验范围")
    scope.target = self; scope.action = #selector(updateNextButton)
    note.placeholderString = "备注／小问编号（可选）"
    note.setAccessibilityLabel("核验备注")
    if solutions.isEmpty {
      source.placeholderString = "来源，例如教材、教师、自己填写"
      source.setAccessibilityLabel("参考答案来源")
      editor.setAccessibilityLabel("参考答案文字")
      referencePicker.addItem(withTitle: "新增参考答案")
      for (index, entry) in references.enumerated() {
        referencePicker.addItem(
          withTitle: "参考答案 \(index + 1) · \(entry.source.isEmpty ? "用户提供" : entry.source)")
      }
      referencePicker.target = self
      referencePicker.action = #selector(selectReference)
      referencePicker.setAccessibilityLabel("已保存的参考答案")
      rows += [referencePicker, source, scope, MathEditorLayout.scroll(editor, height: 150)]
      imageButton.target = self
      imageButton.action = #selector(chooseImage)
      let remove = NSButton(title: "移除图片", target: self, action: #selector(removeImage))
      rows.append(NSStackView(views: [imageButton, remove]))
      image.imageScaling = .scaleProportionallyUpOrDown
      image.heightAnchor.constraint(equalToConstant: 100).isActive = true
      rows.append(image)
    } else {
      for (index, solution) in solutions.enumerated() {
        answerPicker.addItem(
          withTitle:
            "回答 \(index + 1) · \(solution.model) · \(solution.createdAt.formatted(date: .omitted, time: .shortened))"
        )
      }
      answerPicker.target = self
      answerPicker.action = #selector(selectAnswer)
      answerPicker.setAccessibilityLabel("选择需要核验的回答")
      referencePicker.addItem(withTitle: "不指定参考答案，直接核验")
      for (index, entry) in references.enumerated() {
        referencePicker.addItem(
          withTitle:
            "参考答案 \(index + 1) · \(entry.source.isEmpty ? "用户提供" : entry.source) · \(entry.scope)")
      }
      referencePicker.target = self
      referencePicker.action = #selector(selectReference)
      referencePicker.setAccessibilityLabel("核验参考答案")
      decision.addItems(withTitles: ["待核验", "用户确认", "标记有误"])
      decision.setAccessibilityLabel("用户核验决定")
      decision.target = self; decision.action = #selector(updateNextButton)
      let controls = NSStackView(views: [decision, scope])
      controls.spacing = 12
      rows += [
        answerPicker, MathEditorLayout.scroll(answer, height: 180, editable: false),
        referencePicker,
      ]
      answer.setAccessibilityLabel("待核验回答及图解")
      answer.isRichText = true
      referenceText.setAccessibilityLabel("参考答案内容")
      rows.append(MathEditorLayout.scroll(referenceText, height: 75, editable: false))
      image.imageScaling = .scaleProportionallyUpOrDown
      image.heightAnchor.constraint(equalToConstant: 90).isActive = true
      image.isHidden = true
      rows += [image, controls, note]
      editor.setAccessibilityLabel("更正内容")
      rows.append(NSTextField(labelWithString: "更正内容（可选，原回答会保留）"))
      rows.append(MathEditorLayout.scroll(editor, height: 80))
    }
    let viewImage = NSButton(title: "查看答案原图", target: self, action: #selector(viewImage))
    rows.append(viewImage)
    message.textColor = .secondaryLabelColor
    message.font = .systemFont(ofSize: 12)
    message.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    saveButton.target = self
    saveButton.action = #selector(save)
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    nextButton.target = self; nextButton.action = #selector(saveAndNext)
    nextButton.isHidden = solutions.isEmpty || onNext == nil
    nextButton.isEnabled = false
    let buttons = NSStackView(views: [NSView(), cancel, saveButton, nextButton])
    buttons.spacing = 10
    rows += [message, buttons]
    if solutions.isEmpty { MathEditorLayout.install(rows, in: panel) }
    else {
      questionImage.setAccessibilityLabel("待核验题目原图")
      questionImage.imageScaling = .scaleProportionallyDown
      questionImage.imageAlignment = .alignTop
      questionImage.setContentHuggingPriority(.defaultLow, for: .vertical)
      questionImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      questionImage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
      questionImageStatus.font = .systemFont(ofSize: 11)
      let original = NSButton(title: "查看题目原图", target: self, action: #selector(viewQuestionImage))
      let sourceColumn = NSStackView(views: [NSTextField(labelWithString: "原题（原图为准）"), questionImageStatus, questionImage, original])
      sourceColumn.orientation = .vertical; sourceColumn.alignment = .leading; sourceColumn.spacing = 10
      questionImage.widthAnchor.constraint(equalTo: sourceColumn.widthAnchor).isActive = true
      questionImageStatus.widthAnchor.constraint(equalTo: sourceColumn.widthAnchor).isActive = true
      MathEditorLayout.install(rows, in: panel, beside: sourceColumn)
    }
  }

  @objc private func selectAnswer() {
    guard solutions.indices.contains(answerPicker.indexOfSelectedItem) else { return }
    let entry = solutions[answerPicker.indexOfSelectedItem]
    let rendered = NSMutableAttributedString(string: "")
    MathDiagramPresentation.append(entry.diagrams, failure: entry.diagramFailure, to: rendered, width: 480, fontSize: 13)
    rendered.append(NSAttributedString(string: (entry.arithmeticNotice.map { "\n\($0)\n" } ?? "")
      + "\n提问：\(entry.question)\n\n\(entry.answer)", attributes: [
      .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
    answer.textStorage?.setAttributedString(rendered)
    answer.scrollRangeToVisible(NSRange(location: 0, length: 0))
    decision.selectItem(
      at: entry.verificationStatus == "confirmed"
        ? 1 : entry.verificationStatus == "rejected" ? 2 : 0)
    editor.string = ""
    note.stringValue = ""
    updateNextButton()
  }

  private func loadQuestionImage() {
    let revision = questionImageRevision
    questionImageTask = Task { [weak self, store, questionID] in
      do {
        let data = try await store.originalImage(questionID: questionID)
        guard let self, !self.isInvalidated, self.questionImageRevision == revision,
          let image = NSImage(data: data) else { return }
        self.questionImage.image = image
        let bitmap = NSBitmapImageRep(data: data)
        self.questionImageStatus.stringValue = bitmap.map { "原图 \($0.pixelsWide) × \($0.pixelsHigh) · 未使用OCR替代" } ?? "原题原图"
      } catch {
        guard let self, !self.isInvalidated, self.questionImageRevision == revision else { return }
        self.questionImageStatus.stringValue = "原图读取失败，请返回题库检查后再核验。"
      }
    }
  }

  @objc private func viewQuestionImage() {
    guard let image = questionImage.image else { return }
    showImage(image, title: "题目原图")
  }

  @objc private func updateNextButton() {
    nextButton.isEnabled = !isSaving && !isInvalidated && canAdvance
  }

  private var canAdvance: Bool {
    decision.indexOfSelectedItem == 2 || decision.indexOfSelectedItem == 1
  }

  @objc private func selectReference() {
    imageRevision = UUID()
    let revision = imageRevision
    image.image = nil
    imageData = nil
    image.isHidden = !solutions.isEmpty
    let index = referencePicker.indexOfSelectedItem - 1
    guard references.indices.contains(index) else {
      referenceText.string = "未指定参考答案。请依据原题自行核验。"
      if solutions.isEmpty {
        editor.string = ""
        source.stringValue = ""
        saveButton.title = "保存"
      }
      return
    }
    let entry = references[index]
    referenceText.string = entry.text.isEmpty ? "参考答案为图片，请对照下图。" : entry.text
    if solutions.isEmpty {
      editor.string = entry.text
      source.stringValue = entry.source
      scope.selectItem(withTitle: entry.scope)
      saveButton.title = "另存参考答案"
      message.stringValue = "旧答案保留；修改后会新增一份参考答案。"
    }
    if let assetID = entry.imageAssetID {
      Task { [weak self, store] in
        do {
          let data = try await store.assetImage(assetID: assetID)
          guard let self, self.imageRevision == revision else { return }
          self.imageData = data
          self.image.image = NSImage(data: data)
          self.image.isHidden = false
        } catch {
          guard let self, self.imageRevision == revision else { return }
          self.message.stringValue = "答案图片读取失败：\(error.localizedDescription)"
        }
      }
    }
  }

  @objc private func viewImage() {
    guard let image = image.image else {
      message.stringValue = "当前参考答案没有图片。"
      return
    }
    showImage(image, title: "参考答案原图")
  }

  private func showImage(_ image: NSImage, title: String) {
    let viewer = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    viewer.title = title
    viewer.isReleasedWhenClosed = false
    let photo = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    photo.image = image
    photo.imageScaling = .scaleNone
    let scroll = NSScrollView()
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.documentView = photo
    viewer.contentView = scroll
    originalPanel?.close()
    originalPanel = viewer
    viewer.center()
    viewer.bringToFront()
  }

  @objc private func chooseImage() {
    let chooser = NSOpenPanel()
    chooser.allowedContentTypes = [.png, .jpeg]
    chooser.allowsMultipleSelection = false
    chooser.beginSheetModal(for: panel) { [weak self] response in
      guard response == .OK, let url = chooser.url, let self else { return }
      do {
        let bytes = try Data(contentsOf: url)
        guard let preview = NSImage(data: bytes) else { throw MathQuestionStoreError.invalidImage }
        self.imageRevision = UUID()
        self.imageData = bytes
        self.image.image = preview
        self.message.stringValue = "图片将按原始字节保存到本机。"
      } catch { self.message.stringValue = error.localizedDescription }
    }
  }

  @objc private func removeImage() {
    imageRevision = UUID()
    imageData = nil
    image.image = nil
  }

  @objc private func save() { persist(advance: false) }
  @objc private func saveAndNext() {
    guard canAdvance else { return }
    persist(advance: true)
  }

  private func persist(advance: Bool) {
    guard !isSaving, !isInvalidated else { return }
    panel.makeFirstResponder(nil)
    let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
    if solutions.isEmpty && text.isEmpty && imageData == nil {
      message.stringValue = "请输入参考答案，或添加答案图片。"
      return
    }
    let selectedSolution =
      solutions.indices.contains(answerPicker.indexOfSelectedItem)
      ? solutions[answerPicker.indexOfSelectedItem] : nil
    let referenceIndex = referencePicker.indexOfSelectedItem - 1
    let referenceID =
      references.indices.contains(referenceIndex) ? references[referenceIndex].id : nil
    let chosenScope = scope.titleOfSelectedItem ?? "最终答案"
    let chosenStatus = ["unverified", "confirmed", "rejected"][max(0, decision.indexOfSelectedItem)]
    let sourceText = source.stringValue
    let noteText = note.stringValue
    let bytes = imageData
    isSaving = true
    saveButton.isEnabled = false
    nextButton.isEnabled = false
    mutationTask = Task { [weak self, store, questionID] in
      guard let self, !self.isInvalidated else { return }
      do {
        if let selectedSolution {
          _ = try await store.reviewSolution(
            questionID: questionID, solutionID: selectedSolution.id, status: chosenStatus,
            scope: chosenScope, note: noteText, correction: text, referenceID: referenceID)
        } else {
          _ = try await store.addReferenceAnswer(
            questionID: questionID, text: text, source: sourceText, scope: chosenScope,
            imageData: bytes)
        }
        guard !self.isInvalidated else { return }
        self.onSave()
        self.dismiss()
        if advance { self.onNext?() }
      } catch {
        guard !self.isInvalidated else { return }
        self.isSaving = false
        self.saveButton.isEnabled = true
        self.updateNextButton()
        self.message.stringValue = "保存失败：\(error.localizedDescription)"
      }
    }
  }

  @objc private func cancel() { if !isSaving { dismiss() } }
  private func dismiss() {
    questionImageRevision = UUID(); questionImageTask?.cancel()
    originalPanel?.close()
    panel.sheetParent?.endSheet(panel)
    panel.close()
  }
}

@MainActor
enum MathEditorLayout {
  static func scroll(_ text: NSTextView, height: CGFloat, editable: Bool = true) -> NSScrollView {
    text.isEditable = editable
    text.isRichText = false
    text.font = .systemFont(ofSize: 13)
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = text
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    return scroll
  }

  static func install(_ rows: [NSView], in panel: NSWindow, beside source: NSView? = nil) {
    let root = NSView()
    let column = NSStackView(views: rows)
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 10
    let layout: NSView
    if let source {
      let split = NSStackView(views: [source, column])
      split.orientation = .horizontal; split.alignment = .top; split.spacing = 16
      source.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.32).isActive = true
      source.heightAnchor.constraint(equalTo: column.heightAnchor).isActive = true
      column.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
      layout = split
    } else { layout = column }
    root.addSubview(layout)
    layout.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
    ])
    for row in rows { row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    panel.contentView = root
  }
}
