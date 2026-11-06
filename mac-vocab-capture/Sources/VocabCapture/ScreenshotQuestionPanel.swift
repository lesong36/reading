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
  private let richTranscript = ScreenshotAnswerWebView()
  private let webDiagramImages = NSCache<NSData, NSString>()
  private let copyAnswerButton = NSButton(title: "", target: nil, action: nil)
  private let question = NSTextField()
  private let askButton = NSButton(title: "提问", target: nil, action: nil)
  private let stopButton = NSButton(title: "停止", target: nil, action: nil)
  private let imageCheckbox = NSButton(checkboxWithTitle: "参考原截图", target: nil, action: nil)
  private let status = NSTextField(wrappingLabelWithString: "输入问题，或点击快捷问题开始。")
  private let previewOriginalButton = NSButton(title: "查看原截图", target: nil, action: nil)
  private var originalPreview: ScreenshotPanel?
  private let saveQuestionButton = NSButton(title: "保存题目", target: nil, action: nil)
  private let supplementDiagramButton = NSButton(title: "补图", target: nil, action: nil)
  private let openQuestionButton = NSButton(title: "查看已保存题目", target: nil, action: nil)
  private let saveStatus = NSTextField(wrappingLabelWithString: "")
  private let researchMethod: MathSkillProfileResearchCoordinator.Research?
  private let onMethodsChanged: () -> Void
  private let mathStore: MathQuestionStore?
  private let selectMethodAutomatically: MathMethodSelection?
  private let singlePassAutomaticMethods: Bool
  private let programArithmetic: Bool
  private let singleSubmissionMath: Bool
  private let rendererToolsMath: Bool
  private let canUseMathRendererTools: () -> Bool
  private let canUseReviewedMathExamples: () -> Bool
  private var automaticMethodSelection: Bool
  private var methodItemOffset: Int { selectMethodAutomatically == nil ? 1 : 2 }
  private let methodPicker = NSPopUpButton()
  private let methodStatus = NSTextField(wrappingLabelWithString: "")
  private var teachingMethods: [MathTeachingMethod] = []
  private var selectedMethod: MathTeachingMethod?
  private var methodSettings: MathMethodSettings?
  private var methodLoadRevision = UUID()
  private var saveQuestion: MathQuestionSave?
  private let onOpenQuestion: (@MainActor (String) -> Void)?
  private let solutionModel: (@MainActor () -> String)?
  private var originalImageData: Data?
  private var captureID = UUID().uuidString
  private var saveRevision = UUID()
  private var saveTask: Task<Void, Never>?
  private var persistenceFollowupScheduled = false
  private var completedSolutions: [MathQuestionSolution] = []
  private var conversationSolutions: [Int: MathQuestionSolution] = [:]
  private var persistedSolutionIDs: Set<String> = []
  private(set) var savedQuestionID: String?
  private(set) var isSavingQuestion = false
  private let suggestions = NSStackView()
  private let performanceLabel = NSTextField(wrappingLabelWithString: "")
  private let performanceDetailsButton = NSButton(title: "耗时明细…", target: nil, action: nil)
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
  private(set) var singlePassPreparationDurations: [String: Double] = [:]
  static let zoomKey = "VocabCapture.questionZoomScale"
  private let sessionStore: ScreenshotQuestionSessionStore?
  var onAppendCapture: (() -> Void)?
  private var sessionEpoch = UUID()
  private var sessionID: String?
  private var sessionAttachmentID: String?
  private var sessionPersistenceTask: Task<Void, Never>?
  private let sessionButton = NSButton(title: "问答记录", target: nil, action: nil)
  private let pinButton = NSButton(title: "", target: nil, action: nil)
  private let answer: ScreenshotQuestionAnswer
  private let onModelSettings: (() -> Void)?
  private let modelPreferences: ScreenshotQuestionPreferences?
  private let modelPicker = NSPopUpButton()
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
    solutionModel: (@MainActor () -> String)? = nil,
    mathStore: MathQuestionStore? = nil,
    selectMethodAutomatically: MathMethodSelection? = nil,
    singlePassAutomaticMethods: Bool = false,
    programArithmetic: Bool = false,
    singleSubmissionMath: Bool = false,
    rendererToolsMath: Bool = false,
    canUseMathRendererTools: @escaping () -> Bool = { true },
    canUseReviewedMathExamples: @escaping () -> Bool = { false },
    researchMethod: MathSkillProfileResearchCoordinator.Research? = nil,
    onMethodsChanged: @escaping () -> Void = {},
    sessionStore: ScreenshotQuestionSessionStore? = nil
  ) {
    self.sessionStore = sessionStore
    self.mathStore = mathStore
    self.researchMethod = researchMethod
    self.onMethodsChanged = onMethodsChanged
    self.selectMethodAutomatically = selectMethodAutomatically
    self.singlePassAutomaticMethods = singlePassAutomaticMethods
    self.programArithmetic = programArithmetic
    self.singleSubmissionMath = singleSubmissionMath
    self.rendererToolsMath = rendererToolsMath
    self.canUseMathRendererTools = canUseMathRendererTools
    self.canUseReviewedMathExamples = canUseReviewedMathExamples
    self.automaticMethodSelection = selectMethodAutomatically != nil
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
    keepsOnTop = interfaceDefaults.bool(forKey: "VocabCapture.questionWindowPinned")
    refreshPinButton()
    refreshSource()
    applyZoom()
    center()
  }

  func present() {
    isClosed = false
    refreshModels()
    refreshSuggestions()
    refreshSaveControls()
    refreshMethods()
    persistCurrentCaptureIfNeeded()
    bringToFront()
    updateTranscriptWidth()
    makeFirstResponder(question)
  }

  func windowDidResize(_ notification: Notification) { renderTranscript() }

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
    _ newContext: ScreenshotQuestionContext, originalImageData newOriginal: Data? = nil,
    persistSessionCapture: Bool = true
  ) {
    let changedImage =
      newContext.imageData != context.imageData
      || (newOriginal != nil && newOriginal != originalImageData)
    if changedImage {
      sessionAttachmentID = nil
      originalPreview?.close()
      originalPreview = nil
      selectedMethod = nil
      automaticMethodSelection = selectMethodAutomatically != nil
      methodPicker.selectItem(at: 0)
      methodStatus.stringValue = defaultMethodStatus
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
    if persistSessionCapture { persistCurrentCaptureIfNeeded() }
    if sessionStore == nil { history.removeAll() }
    conversationSolutions.removeAll()
    pendingQuestion = nil
    partialAnswer = ""
    pendingOutcome = ""
    transcript.string = ""
    richTranscript.render(turns: [], zoom: zoomScale)
    refreshCopyAnswerButton()
    performance = nil
    refreshPerformance()
    refreshSource()
    renderTranscript()
    status.stringValue = sessionStore == nil
      ? "截图或选词已改变，已开始新的对话。"
      : "已更新截图，保留当前会话；可以继续追问。"
  }

  func windowWillClose(_ notification: Notification) {
    originalPreview?.close()
    originalPreview = nil
    preservePendingCapturePersistence()
    isClosed = true
    saveRevision = UUID()
    isSavingQuestion = false
    saveTask = nil
    cancelAnswer()
    quickPromptSettings?.panel.close()
    quickPromptSettings = nil
  }

  func prepareForLibraryRestore() async {
    cancelAnswer()
    let settings = methodSettings
    methodSettings = nil
    await settings?.prepareForLibraryRestore()
    for sheet in sheets { endSheet(sheet, returnCode: .cancel); sheet.close() }
    await saveTask?.value
    savedQuestionID = nil
    persistedSolutionIDs.removeAll()
    refreshSaveControls()
  }

  func mathLibraryDidRestore(saveQuestion: MathQuestionSave? = nil) {
    if let saveQuestion { self.saveQuestion = saveQuestion }
    selectedMethod = nil
    automaticMethodSelection = selectMethodAutomatically != nil
    refreshMethods()
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
    sessionButton.isHidden = sessionStore == nil
    pinButton.target = self
    pinButton.action = #selector(togglePinned)
    pinButton.bezelStyle = .rounded
    pinButton.imagePosition = .imageOnly
    pinButton.setAccessibilityLabel("置顶问答窗口")
    let headingRow = NSStackView(views: [heading, NSView(), pinButton, sessionButton, modelSettings])
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
    let answerArea = NSView()
    answerArea.wantsLayer = true
    answerArea.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    scroll.translatesAutoresizingMaskIntoConstraints = false
    copyAnswerButton.translatesAutoresizingMaskIntoConstraints = false
    copyAnswerButton.target = self
    copyAnswerButton.action = #selector(copyGeneratedAnswers)
    copyAnswerButton.bezelStyle = .inline
    copyAnswerButton.imagePosition = .imageLeading
    copyAnswerButton.setAccessibilityLabel("复制回答")
    answerArea.addSubview(scroll)
    richTranscript.translatesAutoresizingMaskIntoConstraints = false
    richTranscript.isHidden = true
    richTranscript.onReady = { [weak self, weak scroll] ready in
      self?.richTranscript.isHidden = !ready
      scroll?.isHidden = ready
    }
    webDiagramImages.countLimit = 24
    answerArea.addSubview(richTranscript)
    answerArea.addSubview(copyAnswerButton)
    NSLayoutConstraint.activate([
      richTranscript.topAnchor.constraint(equalTo: scroll.topAnchor),
      richTranscript.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
      richTranscript.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
      richTranscript.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
      scroll.topAnchor.constraint(equalTo: answerArea.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: answerArea.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: answerArea.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: copyAnswerButton.topAnchor, constant: -4),
      copyAnswerButton.trailingAnchor.constraint(equalTo: answerArea.trailingAnchor, constant: -10),
      copyAnswerButton.bottomAnchor.constraint(equalTo: answerArea.bottomAnchor, constant: -6),
      copyAnswerButton.heightAnchor.constraint(equalToConstant: 24),
      copyAnswerButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])
    refreshCopyAnswerButton()
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
    let appendButton = NSButton(title: "追加截图", target: self, action: #selector(appendCapture))
    appendButton.isHidden = sessionStore == nil
    let clearButton = NSButton(title: "清空对话", target: self, action: #selector(clearConversation))
    for button in [appendButton, stopButton, clearButton] {
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
    performanceDetailsButton.target = self
    performanceDetailsButton.action = #selector(showPerformanceDetails)
    performanceDetailsButton.setAccessibilityIdentifier("ScreenshotQuestion.performanceDetails")
    performanceDetailsButton.isEnabled = false
    let performanceRow = NSStackView(views: [performanceLabel, performanceDetailsButton])
    performanceRow.spacing = 10
    performanceLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
    previewOriginalButton.bezelStyle = .rounded
    previewOriginalButton.controlSize = .small
    previewOriginalButton.target = self
    previewOriginalButton.action = #selector(previewOriginalScreenshot)
    previewOriginalButton.setAccessibilityIdentifier("ScreenshotQuestion.previewOriginal")
    previewOriginalButton.toolTip = "检查保存用的原始截图；不会解题或入库。"
    let controls = NSStackView(views: [
      imageCheckbox, previewOriginalButton, searchControls, NSView(), appendButton, stopButton, clearButton,
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
    supplementDiagramButton.target = self
    supplementDiagramButton.action = #selector(supplementDiagram)
    supplementDiagramButton.bezelStyle = .rounded
    supplementDiagramButton.isHidden = true
    supplementDiagramButton.toolTip = "按当前原图单独请求图解，会发起一次新的模型请求。"
    openQuestionButton.target = self
    openQuestionButton.action = #selector(openSavedQuestion)
    openQuestionButton.bezelStyle = .rounded
    saveStatus.font = .systemFont(ofSize: 12)
    saveStatus.textColor = .secondaryLabelColor
    saveStatus.maximumNumberOfLines = 2
    saveStatus.setAccessibilityLabel("题目保存状态")
    let saveRow = NSStackView(views: [
      saveQuestionButton, openQuestionButton, supplementDiagramButton, NSView(),
    ])
    saveRow.orientation = .horizontal
    saveRow.spacing = 10
    saveRow.isHidden = saveQuestion == nil
    saveStatus.isHidden = saveQuestion == nil
    refreshSaveControls()
    if selectMethodAutomatically != nil { methodPicker.addItem(withTitle: "AI 自动选择方法") }
    methodPicker.addItem(withTitle: "不指定解题方法")
    methodPicker.setAccessibilityLabel("当前题目的解题方法")
    methodPicker.target = self
    methodPicker.action = #selector(selectTeachingMethod)
    let methodEditor = NSButton(
      title: "管理方法…", target: self, action: #selector(editTeachingMethods))
    let temporary = NSButton(
      title: "临时方法…", target: self, action: #selector(temporaryTeachingMethod))
    let methodRow = NSStackView(views: [methodPicker, temporary, methodEditor])
    methodRow.spacing = 10
    methodRow.isHidden = mathStore == nil
    methodStatus.font = .systemFont(ofSize: 11)
    methodStatus.textColor = .secondaryLabelColor
    methodStatus.stringValue = defaultMethodStatus
    methodStatus.isHidden = mathStore == nil
    let column = NSStackView(views: [
      headingRow, modelRow, source, answerArea, suggestions, methodRow, methodStatus, input, controls,
      status, performanceRow,
      saveRow, saveStatus,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 10
    column.setCustomSpacing(16, after: source)
    column.setCustomSpacing(14, after: answerArea)
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
      headingRow, modelRow, source, answerArea, suggestions, input, status, performanceRow, controls,
      saveRow, saveStatus, methodRow, methodStatus,
    ] {
      view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    answerArea.setContentHuggingPriority(.defaultLow, for: .vertical)
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
    renderRichTranscript()
    updateMinimumHeight()
    refreshPerformance()
  }

  private func refreshPerformance() {
    performanceDetailsButton.isEnabled = performance != nil
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

  @objc private func showPerformanceDetails() {
    guard let performance else { return }
    let report = performance.breakdown(localDurations: singlePassPreparationDurations)
    let alert = NSAlert()
    alert.messageText = "本次回答耗时"
    alert.informativeText = "已包含的阶段不重复累加；未测得的时间显示为未记录。"
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
    text.string = report
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.isEditable = false
    text.setAccessibilityLabel("本次回答耗时明细")
    let scroll = MathEditorLayout.scroll(text, height: 320, editable: false)
    scroll.frame = NSRect(x: 0, y: 0, width: 560, height: 320)
    alert.accessoryView = scroll
    alert.addButton(withTitle: "关闭")
    alert.addButton(withTitle: "复制明细")
    alert.beginSheetModal(for: self) { response in
      if response == .alertSecondButtonReturn {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
      }
    }
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

  private var defaultMethodStatus: String {
    automaticMethodSelection ? "提问时自动匹配方法；可手动指定或不使用。" : "仅用于当前题目，不自动套用。"
  }

  private func refreshMethods() {
    guard let mathStore else { return }
    let loadID = UUID()
    methodLoadRevision = loadID
    Task { [weak self] in
      do {
        let entries = try await mathStore.methods()
        guard let self, self.methodLoadRevision == loadID else { return }
        self.teachingMethods = entries
        // Retain the version explicitly selected for this question after an editor update.
        if !self.automaticMethodSelection, let selected = self.selectedMethod,
          !self.teachingMethods.contains(where: { $0.versionID == selected.versionID })
        {
          self.teachingMethods.append(selected)
        }
        self.methodPicker.removeAllItems()
        if self.selectMethodAutomatically != nil {
          self.methodPicker.addItem(withTitle: "AI 自动选择方法")
        }
        self.methodPicker.addItem(withTitle: "不指定解题方法")
        self.methodPicker.addItems(
          withTitles: self.teachingMethods.map {
            $0.title + ($0.category.isEmpty ? "" : " · " + $0.category)
          })
        if self.automaticMethodSelection {
          self.methodPicker.selectItem(at: 0)
        } else if let selected = self.selectedMethod,
          let index = self.teachingMethods.firstIndex(where: { $0.versionID == selected.versionID })
        {
          self.methodPicker.selectItem(at: index + self.methodItemOffset)
        } else {
          self.methodPicker.selectItem(at: self.methodItemOffset - 1)
        }
      } catch { self?.methodStatus.stringValue = "方法读取失败：\(error.localizedDescription)" }
    }
  }

  @objc private func selectTeachingMethod() {
    guard !isAnswering else { return }
    automaticMethodSelection =
      selectMethodAutomatically != nil && methodPicker.indexOfSelectedItem == 0
    let index = methodPicker.indexOfSelectedItem - methodItemOffset
    selectedMethod = teachingMethods.indices.contains(index) ? teachingMethods[index] : nil
    clearConversation()
    methodStatus.stringValue =
      selectedMethod.map { "使用：\($0.title)，仅当前题目。可在菜单中取消。" } ?? defaultMethodStatus
    methodPicker.toolTip = selectedMethod?.instructions
  }

  @objc private func editTeachingMethods() {
    guard let mathStore else { return }
    if methodSettings == nil {
      methodSettings = MathMethodSettings(store: mathStore, research: researchMethod, onSave: { [weak self] in self?.refreshMethods(); self?.onMethodsChanged()
      })
    }
    methodSettings?.present()
  }

  @objc private func temporaryTeachingMethod() {
    guard !isAnswering else { return }
    let alert = NSAlert()
    alert.messageText = "本次题目的临时方法"
    alert.informativeText = "填写步骤、适用条件或示例。本次回答会保留方法，不加入方法库。"
    alert.addButton(withTitle: "使用此方法")
    alert.addButton(withTitle: "取消")
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
    let scroll = MathEditorLayout.scroll(text, height: 150)
    scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 150)
    text.setAccessibilityLabel("临时解题方法")
    alert.accessoryView = scroll
    alert.beginSheetModal(for: self) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self, !self.isAnswering else { return }
      let body = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return }
      let method = MathTeachingMethod(
        id: UUID().uuidString, versionID: UUID().uuidString, title: "本次临时方法", category: "",
        instructions: body, createdAt: Date())
      self.selectedMethod = method
      self.automaticMethodSelection = false
      self.clearConversation()
      self.refreshMethods()
      self.methodStatus.stringValue = "使用本次临时方法；不会成为其他题目的默认方法。"
    }
  }

  @objc private func togglePinned() {
    keepsOnTop.toggle()
    interfaceDefaults.set(keepsOnTop, forKey: "VocabCapture.questionWindowPinned")
    refreshPinButton()
  }

  private func refreshPinButton() {
    pinButton.image = NSImage(systemSymbolName: keepsOnTop ? "pin.fill" : "pin", accessibilityDescription: nil)
    pinButton.state = keepsOnTop ? .on : .off
    pinButton.toolTip = keepsOnTop ? "取消置顶" : "置顶：切换应用时仍保持在前台"
    pinButton.setAccessibilityValue(keepsOnTop ? "已置顶" : "未置顶")
  }

  private func persistCurrentCaptureIfNeeded() {
    guard let sessionStore, let originalImageData else { return }
    let previous = sessionPersistenceTask
    let epoch = sessionEpoch
    let attachmentID = self.sessionAttachmentID ?? UUID().uuidString
    self.sessionAttachmentID = attachmentID
    let context = self.context
    sessionPersistenceTask = Task { [weak self] in
      await previous?.value
      guard let self, self.sessionEpoch == epoch else { return }
      do {
        let id: String
        if let sessionID = self.sessionID {
          id = sessionID
        } else {
          let title = context.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
          let trimmedTitle = String(title.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines)
          let session = try await sessionStore.create(title: trimmedTitle.isEmpty ? "截图问答" : trimmedTitle)
          id = session.id
          self.sessionID = id
        }
        let attachment = try await sessionStore.appendAttachment(
          id: id, attachmentID: attachmentID,
          imageData: originalImageData, ocrText: context.text)
        if self.sessionEpoch == epoch { self.sessionID = id }

      } catch {
        // A failed local archive must not interrupt the live question flow.
      }
    }
  }

  @objc private func appendCapture() {
    guard !isAnswering else {
      status.stringValue = "回答完成后才能追加截图。"
      return
    }
    onAppendCapture?()
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
    sessionEpoch = UUID()
    sessionID = nil
    sessionAttachmentID = nil
    clearConversation()
    persistCurrentCaptureIfNeeded()
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
          self.clearConversation()
          self.sessionEpoch = UUID()
          self.updateContext(ScreenshotQuestionContext(
            text: attachment.ocrText, selectedWord: nil, imageData: image),
            originalImageData: image, persistSessionCapture: false)
          self.sessionID = id
          self.sessionAttachmentID = attachment.id
          self.history = session.turns.map {
            ScreenshotQuestionTurn(question: $0.question, answer: $0.answer)
          }
          self.refreshSource()
          self.renderTranscript()
          self.status.stringValue = "已恢复“\(session.title)”；可以继续追问或追加截图。"
        }
      } catch {
        await MainActor.run { self?.status.stringValue = "恢复会话失败：\(error.localizedDescription)" }
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
    supplementDiagramButton.isHidden = true
    let requestStartedAt = now()
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
    let explicitMathRequest = ["数学", "解题", "方程", "算术", "solve"].contains(where: submitted.lowercased().contains)
    let mathFollowup = ["换一种方法", "检查另一道题", "验算", "画图", "补图"].contains(where: submitted.contains)
      && history.contains { turn in
        ["数学", "解题", "方程", "算术", "solve"].contains(where: turn.question.lowercased().contains)
      }
    let isMathRequest = explicitMathRequest || mathFollowup
    let explicitMethod = automaticMethodSelection && !isMathRequest ? nil : selectedMethod
    let autoSelect = automaticMethodSelection && isMathRequest ? selectMethodAutomatically : nil
    // Resolve the current profile at submission, since it can change while this window is open.
    let supportsRendererTools = isMathRequest && canUseMathRendererTools()
    let selectionContext = ScreenshotQuestionContext(
      text: context.text, selectedWord: context.selectedWord,
      imageData: snapshot.imageData == nil ? nil : (originalImageData ?? snapshot.imageData))
    let previous = history
    let modelSnapshot = solutionModel?() ?? "未知模型"
    let requestID = UUID()
    revision = requestID
    pendingQuestion = submitted
    partialAnswer = ""
    pendingOutcome = ""
    question.stringValue = ""
    isAnswering = true
    performance = ScreenshotQuestionPerformance(startedAt: requestStartedAt)
    singlePassPreparationDurations = [:]
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
    methodPicker.isEnabled = false
    stopButton.isEnabled = true
    status.stringValue = "正在回答… 可以先输入下一条问题。"
    renderTranscript()
    answerTask = Task { [weak self] in
      guard let self, self.revision == requestID, !self.isClosed, !Task.isCancelled else { return }
      do {
        var methodSnapshot = explicitMethod
        var visualSnapshots: [MathTeachingMethod] = []
        var selectionFailed = false
        var selectionFailure: String?
        var singlePassCandidates: [MathTeachingMethod]?
        var reviewedExamples: [MathReviewedExample] = []
        let singlePass = self.singlePassAutomaticMethods && autoSelect != nil && supportsRendererTools
        if singlePass, let store = self.mathStore {
          self.methodStatus.stringValue = "正在参考本机方法库；由本次回答判断是否采用。"
          let methodsStarted = Date()
          let candidates = try await store.automaticMethods()
          try Task.checkCancellation()
          guard self.revision == requestID, !self.isClosed else { return }
          self.singlePassPreparationDurations["methodLookup"] = Date().timeIntervalSince(methodsStarted)
          let requirements = (previous.map(\.question) + [submitted]).joined(separator: "\n")
          // This OCR is solely a retrieval hint, never a grant of grade/equation
          // permission. The original image still goes to the answering model.
          let hint: String
          let indexingStarted = Date()
          if let photo = selectionContext.imageData {
            let recognized = (try? await MathQuestionIndexer.recognize(photo))?
              .trimmingCharacters(in: .whitespacesAndNewlines)
            hint = recognized.flatMap { $0.isEmpty ? nil : $0 } ?? selectionContext.text
          } else { hint = selectionContext.text }
          try Task.checkCancellation()
          guard self.revision == requestID, !self.isClosed else { return }
          self.singlePassPreparationDurations["sourceIndex"] = Date().timeIntervalSince(indexingStarted)
          let retrievalStarted = Date()
          singlePassCandidates = MathLocalSkillRetrieval.retrieve(
            methods: candidates, requirements: requirements, textHint: hint)
          self.singlePassPreparationDurations["skillRetrieval"] = Date().timeIntervalSince(retrievalStarted)
          if snapshot.imageData != nil && self.canUseReviewedMathExamples() {
            let examplesStarted = Date()
            // Optional local references never block independent solving, grant
            // teaching permissions, or promote an answer-only review to a skill.
            reviewedExamples = (try? await store.reviewedExamples(
              methods: singlePassCandidates ?? [], textHint: hint,
              excludingImageData: selectionContext.imageData)) ?? []
            self.singlePassPreparationDurations["reviewedExampleRetrieval"] = Date().timeIntervalSince(examplesStarted)
            try Task.checkCancellation()
            guard self.revision == requestID, !self.isClosed else { return }
          }
          methodSnapshot = nil
        } else if let autoSelect, let store = self.mathStore {
          self.methodStatus.stringValue = "正在判断适用方法…"
          do {
            let candidates = try await store.automaticMethods()
            let request = (previous.map(\.question) + [submitted]).joined(separator: "\n")
            let match = try await autoSelect(request, selectionContext, candidates)
            try Task.checkCancellation()
            guard self.revision == requestID, !self.isClosed else { return }
            // An injected selector must also return an exact active version from this request.
            if let chosen = match.method, !candidates.contains(chosen) {
              throw MathMethodMatchError.invalidOutput
            }
            guard match.visualMethods.count <= 2,
              Set(match.visualMethods.map(\.id)).count == match.visualMethods.count,
              match.visualMethods.allSatisfy({
                candidates.contains($0) && $0.id != match.method?.id
              })
            else { throw MathMethodMatchError.invalidOutput }
            methodSnapshot = match.method
            visualSnapshots = match.visualMethods
            self.selectedMethod = match.method
            let visual =
              match.visualMethods.isEmpty
              ? "" : "数形结合：" + match.visualMethods.map(\.title).joined(separator: "、") + "。"
            self.methodStatus.stringValue =
              (match.method.map { "自动选择：\($0.title)。" } ?? (visual.isEmpty ? "未套用方法。" : ""))
              + visual + match.reason
            self.methodStatus.toolTip = self.methodStatus.stringValue
            self.methodPicker.toolTip = ([match.method].compactMap { $0 } + match.visualMethods)
              .map(\.instructions).joined(separator: "\n\n")
          } catch {
            try Task.checkCancellation()
            guard self.revision == requestID, !self.isClosed else { return }
            selectionFailed = true
            methodSnapshot = nil
            visualSnapshots = []
            self.selectedMethod = nil
            if case MathMethodMatchError.prerequisiteNotSatisfied = error {
              selectionFailure = error.localizedDescription
              self.methodStatus.stringValue = error.localizedDescription
            } else {
              self.methodStatus.stringValue = "自动选择失败，未套用方法。可手动指定：\(error.localizedDescription)"
            }
            self.methodStatus.toolTip = self.methodStatus.stringValue
            self.methodPicker.toolTip = nil
          }
        }
        let diagramFollowup = Self.isDiagramFollowup(submitted)
        let requestScope = diagramFollowup ? Self.diagramRequestScope(submitted, history: previous) : submitted
        let useProgramArithmetic = self.programArithmetic && !Self.prohibitsDiagram(submitted)
        let hasDeferredCandidate = !Self.prohibitsDiagram(submitted)
          && (singlePassCandidates ?? []).contains { Self.hasDeferredPresentation(in: $0.instructions) }
        let nativeOnly = self.singleSubmissionMath && self.rendererToolsMath
          && !Self.explicitlyRequestsDiagram(submitted) && !hasDeferredCandidate
        let promptStarted = Date()
        var modelQuestion = Self.question(
          requestScope, using: methodSnapshot, visualMethods: visualSnapshots,
          automaticSelectionFailed: selectionFailed && snapshot.imageData != nil,
          automaticSelectionAttempted: autoSelect != nil)
        if let candidates = singlePassCandidates {
          modelQuestion = useProgramArithmetic
            ? MathStructuredSolution.prompt(requestScope, candidates: candidates, requireDiagram: !nativeOnly, singleSubmission: self.singleSubmissionMath, rendererTools: self.rendererToolsMath, nativeOnly: nativeOnly)
            : MathSinglePassSolution.prompt(requestScope, candidates: candidates)
          if !Self.prohibitsDiagram(submitted) {
            let views = Self.diagramViews(requestScope, method: nil, visualMethods: [])
            modelQuestion += "\n" + (useProgramArithmetic
              ? (self.singleSubmissionMath
                ? (self.rendererToolsMath ? (nativeOnly ? MathStructuredSolution.fastRendererDiagramContract : MathStructuredSolution.rendererDiagramContract) : MathStructuredSolution.submissionDiagramContract)
                : MathStructuredSolution.diagramContract(views: views))
              : MathDiagramAnswer.prompt(views: views))
          }
        }
        if singlePassCandidates != nil {
          self.singlePassPreparationDurations["promptAssembly"] = Date().timeIntervalSince(promptStarted)
        }
        let diagramRequired = Self.requestsDiagram(
          submitted, using: methodSnapshot, visualMethods: visualSnapshots,
          automaticSelectionFailed: selectionFailed && snapshot.imageData != nil)
        let onPartial: @MainActor @Sendable (String) -> Void = { [weak self] partial in
          guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
            return
          }
          let visiblePartial = useProgramArithmetic && singlePassCandidates != nil
            ? MathStructuredSolution.displayText(partial)
            : singlePass ? MathSinglePassSolution.displayText(partial) : MathDiagramAnswer.displayText(partial)
          let firstText =
            self.performance?.firstTextAt == nil
            && !visiblePartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          if firstText {
            self.performance?.firstTextAt = self.now()
            self.refreshPerformance()
          }
          self.partialAnswer = visiblePartial
          if firstText {
            self.renderTranscript()
          } else {
            self.scheduleTranscriptUpdate()
          }
        }
        let onUsage: @MainActor @Sendable (ScreenshotQuestionUsage) -> Void = { [weak self] usage in
          guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
            return
          }
          self.performance?.usage = usage
          self.refreshPerformance()
        }
        let performAnswer: ScreenshotQuestionAnswer = { [weak self] prompt, source, turns, partial in
          guard let self else { throw CancellationError() }
          if let webAnswer = self.webAnswer {
            return try await webAnswer(
            prompt, source, turns, searchEnabled, onUsage,
            { [weak self] stage in
              guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
                return
              }
              self.status.stringValue = stage.title
            }, partial)
          } else if let measuredAnswer = self.measuredAnswer {
            return try await measuredAnswer(
            prompt, source, turns,
            { [weak self] usage in
              guard let self, self.revision == requestID, self.isAnswering, !self.isClosed else {
                return
              }
              self.performance?.usage = usage
              self.refreshPerformance()
            }, partial)
          } else {
            return try await self.answer(prompt, source, turns, partial)
          }
        }
        let answerContext = ScreenshotQuestionContext(text: snapshot.text,
          selectedWord: snapshot.selectedWord, imageData: snapshot.imageData,
          mathReferences: reviewedExamples)
        let modelStarted = self.now()
        let result: String
        do {
          result = try await performAnswer(modelQuestion, answerContext, diagramFollowup ? [] : previous, onPartial)
        } catch {
          if self.revision == requestID, self.isAnswering, !self.isClosed {
            self.singlePassPreparationDurations["modelRequest"] = max(0, self.now() - modelStarted)
          }
          throw error
        }
        try Task.checkCancellation()
        guard self.revision == requestID, !self.isClosed else { return }
        self.singlePassPreparationDurations["modelRequest"] = max(0, self.now() - modelStarted)
        let processingStarted = Date()
        var answerResult = result
        var diagramOmissionReason: String?
        var diagramSubmissionFailure: String?
        var answerIncomplete = false
        var methodClaimWarning: String?
        if let candidates = singlePassCandidates {
          let usage = useProgramArithmetic
            ? MathStructuredSolution.parse(result, candidates: candidates, rendererTools: self.singleSubmissionMath && self.rendererToolsMath)
            : MathSinglePassSolution.parse(result, candidates: candidates)
          answerResult = usage.answer
          methodSnapshot = usage.method
          visualSnapshots = usage.visualMethods
          selectionFailure = usage.failure
          diagramOmissionReason = usage.diagramOmissionReason
          diagramSubmissionFailure = usage.diagramSubmissionFailure
          answerIncomplete = usage.answerIncomplete
          // Same-answer claims are displayed honestly and remain unverified in
          // storage; a local shortlist is never presented as an adopted method.
          self.selectedMethod = usage.method
          self.methodStatus.stringValue = usage.failure ?? (usage.method.map {
            "回答声明采用：\($0.title)（尚未核验）。"
          } ?? "回答未声明采用已有主方法（尚未核验）。")
        }
        let effectiveDiagramRequired = diagramOmissionReason == nil && (diagramRequired || (singlePassCandidates != nil && useProgramArithmetic) || (singlePassCandidates != nil
          && Self.requestsDiagram(submitted, using: methodSnapshot, visualMethods: visualSnapshots)))
        // A same-answer method claim is unverified metadata, not a user constraint.
        // Keep a validated native diagram even when the model names another visual skill.
        let requiredViews = effectiveDiagramRequired ? Self.diagramViews(
          requestScope, method: singlePassCandidates == nil ? methodSnapshot : nil,
          visualMethods: singlePassCandidates == nil ? visualSnapshots : []) : []
        var processed = Self.prohibitsDiagram(submitted)
          ? MathDiagramAnswer.Result(text: MathDiagramAnswer.displayText(answerResult), diagrams: [], failure: nil, hasDiagramBlock: false)
          : MathDiagramAnswer.requireViews(MathDiagramAnswer.requireComputedDisplay(MathDiagramAnswer.parse(answerResult), request: submitted), views: requiredViews)
        if singlePassCandidates != nil && !processed.diagrams.isEmpty {
          let inconsistent = visualSnapshots.filter { method in
            let claimedViews = Self.diagramViews("", method: nil, visualMethods: [method])
            return !claimedViews.isEmpty && !processed.diagrams.contains { claimedViews.contains($0.kind) }
          }
          if !inconsistent.isEmpty {
            visualSnapshots.removeAll { inconsistent.contains($0) }
            let notice = "模型声明的画法与实际图解不一致，本次未记录该画法采用；答案和图解仍需核验。"
            methodClaimWarning = notice
            self.methodStatus.stringValue = notice
          }
        }
        if let diagramSubmissionFailure {
          processed.failure = [processed.failure, diagramSubmissionFailure].compactMap { $0 }.joined(separator: "\n")
        }
        if nativeOnly, let reason = diagramOmissionReason, !processed.text.contains(reason) {
          processed.text += "\n\n图解说明：" + reason
        }
        // Do not hide another model round-trip behind a completed answer. A user can
        // explicitly request a diagram next; preserve checked pictures and the answer now.
        // Inline fences are checked and rendered by the offline WebView, not the
        // quantity-diagram compiler. Presence defers display checks, not review.
        let deferredPresentation = requiredViews.isEmpty
          && Self.hasDeferredPresentation(in: processed.text)
        if effectiveDiagramRequired && processed.diagrams.isEmpty && processed.failure == nil
          && !deferredPresentation {
          processed.failure = "本次未返回可显示的图解，可以单独提问补图。"
        }
        if singlePassCandidates != nil && useProgramArithmetic {
          let recipeIDs = MathSinglePassSolution.nativeRecipeIDs(in: answerResult)
          for diagram in processed.diagrams where recipeIDs.contains(diagram.id) {
            do {
              let explanation = try MathCheckedDiagramExplanation.text(for: diagram)
              processed.text += "\n\n\(diagram.title) · 程序计算\n" + explanation
            } catch {
              processed.failure = [processed.failure, "本机计算说明未生成：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
          }
        }
        guard self.revision == requestID, !self.isClosed, !Task.isCancelled else { return }
        if singlePassCandidates != nil && useProgramArithmetic
          && !MathSinglePassSolution.nativeRecipeIDs(in: answerResult).isSubset(of: Set(processed.diagrams.map(\.id)))
          && processed.failure != nil {
          answerIncomplete = true
        }
        let visible = answerIncomplete
          ? (processed.diagrams.isEmpty
            ? "解答尚未完成：以下仅保留模型的关系说明，图解与程序计算未完成。\n\n"
            : "解答尚未完成：部分程序计算或图解未通过检查，已保留可用内容，仍需核验。\n\n") + processed.text
          : processed.text
        self.history.append(ScreenshotQuestionTurn(question: submitted, answer: visible))
        await self.sessionPersistenceTask?.value
        if let sessionStore = self.sessionStore, let sessionID = self.sessionID {
          _ = try? await sessionStore.appendTurn(id: sessionID, question: submitted, answer: visible,
            model: modelSnapshot, attachmentIDs: self.sessionAttachmentID.map { [$0] } ?? [])
        }
        if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !processed.diagrams.isEmpty {
          let solution = MathQuestionSolution(
              id: requestID.uuidString, question: submitted, answer: visible,
              model: modelSnapshot, createdAt: Date(), method: methodSnapshot,
              visualMethods: visualSnapshots, diagrams: processed.diagrams,
              diagramFailure: processed.failure, selectionFailure: selectionFailure,
              methodClaimWarning: methodClaimWarning,
              reviewedExamples: reviewedExamples.map(\.reference))
          self.completedSolutions.append(solution)
          self.conversationSolutions[self.history.count - 1] = solution
        }
        self.pendingQuestion = nil
        self.partialAnswer = ""
        self.singlePassPreparationDurations["answerProcessing"] = Date().timeIntervalSince(processingStarted)
        let renderingStarted = Date()
        self.renderTranscript(focusLatestDiagram: !processed.diagrams.isEmpty)
        if self.performance?.firstTextAt == nil && (!visible.isEmpty || !processed.diagrams.isEmpty) {
          self.performance?.firstTextAt = self.now()
        }
        self.singlePassPreparationDurations["transcriptRendering"] = Date().timeIntervalSince(renderingStarted)
        self.finishAnswer(status: MathExplicitAdditionAudit.notice(in: visible) != nil
          ? "回答已保留 · 发现算式不相等，请核对原文。"
          : answerIncomplete
          ? "解答尚未完成，已保留\(processed.diagrams.isEmpty ? "关系说明" : "可用内容")；可继续追问或换模型。"
          : processed.failure == nil
          ? "回答完成，可继续追问。"
          : "回答已保留 · \(processed.diagrams.isEmpty ? "图解未生成" : "部分图解未完成")：\(processed.failure!)")
        self.refreshSaveControls()
        self.supplementDiagramButton.isHidden = !(nativeOnly && diagramOmissionReason != nil && !answerIncomplete)
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

  static func question(
    _ submitted: String, using method: MathTeachingMethod?, visualMethods: [MathTeachingMethod] = [],
    automaticSelectionFailed: Bool = false, automaticSelectionAttempted: Bool = false
  ) -> String {
    let draw = requestsDiagram(submitted, using: method, visualMethods: visualMethods,
      automaticSelectionFailed: automaticSelectionFailed)
    guard method != nil || !visualMethods.isEmpty else {
      // Abstaining from a named skill must not suppress useful native diagrams.
      // This is optional assistance for an explicit math request, not a requirement
      // to invent a method or draw an unrelated chart for English questions.
      let optionalMathDiagram = automaticSelectionAttempted && !prohibitsDiagram(submitted)
        && ["小学", "数学", "方程", "算术", "四年级"].contains(where: submitted.contains)
      if !draw && optionalMathDiagram {
        return submitted + "\n\n没有匹配的已有主方法，直接根据原图解题，不强行命名解法。若表格或线段能帮助解释关键关系，使用下列图解协议实际出图；没有帮助则保留正常文字解答，不增加无关图形。\n"
          + MathDiagramAnswer.prompt(views: diagramViews(submitted, method: nil, visualMethods: []))
      }
      return draw ? submitted + "\n\n请根据原题选择适用的图解，画出数量关系；条件不清时说明缺失内容，不补造条件。\n"
        + MathDiagramAnswer.prompt(views: diagramViews(submitted, method: method, visualMethods: visualMethods)) : submitted
    }
    let primary =
      method.map { "主解法建议\n名称：\($0.title)\n适用题型：\($0.category)\n方法内容：\n\($0.instructions)" } ?? ""
    let visual = visualMethods.enumerated().map { index, entry in
      "数形结合方法 \(index + 1)\n名称：\(entry.title)\n适用题型：\(entry.category)\n画法全文：\n\(entry.instructions)"
    }.joined(separator: "\n\n")
    let protocolPrompt = diagramProtocol(submitted, method: method, visualMethods: visualMethods)
    let diagramPrompt = draw ? "\n\n" + protocolPrompt : ""
    return """
      本题可参考的教学方法建议（不代表已采用，不是原题条件或正确答案的证明）：
      \(primary)
      \(visual)

      先独立判断建议与原题的关键解题关系是否相符。只有直接适用时才使用；不适用时拒绝该建议，按原题正常解题。允许没有匹配的已有主解法，不要求100%套用目录中的方法，不补造题目条件。
      不要把中间算式含乘除或单价乘数量当作归一归总；归一须以求出一份后换求另一份数为关键，归总须以不变总量换分法为关键。优惠比较应按各优惠规则算实际付款再比较，不能因涉及单价而硬归类。
      说明实际思路；只有实际适用并采用时才称其为主解法。没有适用名称时直接解释思路，不捏造技能名称。图解建议也须有助理解，不能因选中了某画法而强行套用；应画出或列出本题关键关系，
      用下述原生图解数据呈现线段、状态、面积分块或表格；标注本题已知量与未知量，
      解释图中各段、各块、各行对应的数量关系，再从图中推导算式。不能只提方法名称而省略图解，
      不得把方法例题的数字当作本题条件，也不得假定图形按比例、补造长度或面积。
      以下本次明确提问优先于方法中的要求：
      \(submitted)
      """ + diagramPrompt
  }

  /// Only exact project skill bodies select a native recipe; names in custom
  /// methods or an earlier AI answer are not proof of a matching contract.
  static func boundDiagramRecipe(_ method: MathTeachingMethod?) -> String? {
    guard let method, let catalogue = try? MathSkillCatalogue.load() else { return nil }
    return catalogue.discoveryMetadata(for: method)?.name
  }

  static func diagramProtocol(_ submitted: String, method: MathTeachingMethod?, visualMethods: [MathTeachingMethod]) -> String {
    let views = diagramViews(submitted, method: method, visualMethods: visualMethods)
    switch boundDiagramRecipe(method) {
    case "surplus-and-shortfall" where views.contains(where: { [.table, .barComparison].contains($0) }) && views.allSatisfy({ [.table, .barComparison, .equalParts].contains($0) }):
      return MathDiagramAnswer.distributionPrompt(view: views[0])
    case "difference-and-ratio" where !views.isEmpty && views.allSatisfy({ [.equalParts, .barComparison].contains($0) }):
      return MathDiagramAnswer.differenceRatioPrompt
    default: return MathDiagramAnswer.prompt(views: views)
    }
  }

  static func isDiagramFollowup(_ submitted: String) -> Bool {
    ["补图", "补个图", "重新画图", "重画图", "只画图", "仅画图", "补充图解"]
      .contains(where: submitted.contains)
  }

  static func usesDifferenceRatioRecipe(_ method: MathTeachingMethod?, answer: String) -> Bool {
    if ["不是差倍", "不属于差倍", "不适合差倍", "不能用差倍", "不能使用差倍"]
      .contains(where: { answer.contains($0) }) { return false }
    return method?.title.contains("差倍") == true || answer.contains("差倍")
      || (method == nil && answer.contains("倍")
        && ["年龄差", "相差", "多出", "多了", "比原"].contains(where: answer.contains))
  }

  /// Preserve user-selected scope across follow-ups without using earlier AI answers as facts.
  static func diagramRequestScope(_ submitted: String, history: [ScreenshotQuestionTurn]) -> String {
    guard !history.isEmpty else { return submitted }
    let requests = history.suffix(6).map { String($0.question.prefix(2000)) }.joined(separator: "\n")
    return "此前用户提问（仅用于理解指定题号等请求范围；不含助手答案）：\n" + requests
      + "\n最新用户请求优先；若最新请求仅为补图或继续，保留此前明确限定的范围。\n本次用户请求：\n" + submitted
  }

  /// A complete, bounded presentation declaration only. Connectivity and rigid
  /// congruence remain the offline renderer's checks; this never approves math.
  static func hasDeferredPresentation(in answer: String) -> Bool {
    hasDeferredGridPresentation(in: answer) || hasDeferredGeometryPresentation(in: answer)
      || hasDeferredCubePathPresentation(in: answer) || hasDeferredTrianglePresentation(in: answer)
      || hasDeferredGridRoutePresentation(in: answer) || hasDeferredHexagonPresentation(in: answer)
      || hasDeferredRectangleDissectionPresentation(in: answer)
  }

  static func hasDeferredGridRoutePresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-grid-route", requireAll: true) { value in
      func integer(_ item: Any?) -> Int? {
        guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
          (0...100).contains(n.doubleValue) else { return nil }
        return n.intValue
      }
      guard Set(value.keys) == ["width", "height", "points", "stars"],
        let width = integer(value["width"]), (1...8).contains(width),
        let height = integer(value["height"]), (1...8).contains(height),
        let points = value["points"] as? [[Any]], (2...100).contains(points.count),
        let stars = value["stars"] as? [[Any]], stars.count <= 32 else { return false }
      func coordinates(_ input: [[Any]]) -> [(Int, Int)]? {
        var output: [(Int, Int)] = []
        for p in input {
          guard p.count == 2, let x = integer(p[0]), let y = integer(p[1]),
            x <= width, y <= height else { return nil }
          output.append((x, y))
        }
        return output
      }
      guard let route = coordinates(points), coordinates(stars) != nil else { return false }
      return zip(route, route.dropFirst()).allSatisfy { a, b in
        abs(a.0-b.0) + abs(a.1-b.1) == 1
      }
    }
  }

  static func hasDeferredHexagonPresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-hexagon-partition", requireAll: true,
      rawValidate: { $0.range(of: #"^\s*\{\s*"sides"\s*:\s*[345]\s*\}\s*$"#, options: .regularExpression) != nil }) { value in
      guard Set(value.keys) == ["sides"], let sides = value["sides"] as? NSNumber,
        CFGetTypeID(sides) != CFBooleanGetTypeID(), sides.doubleValue.isFinite else { return false }
      return [3.0, 4.0, 5.0].contains(sides.doubleValue)
    }
  }

  static func hasDeferredTrianglePresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-triangle-dissection", requireAll: true) { value in
      if Set(value.keys) == ["case"], let name = value["case"] as? String { return name == "404-e03" }
      guard Set(value.keys) == ["pieces"], let pieces = value["pieces"] as? NSNumber,
        CFGetTypeID(pieces) != CFBooleanGetTypeID(), pieces.doubleValue.isFinite else { return false }
      return pieces.doubleValue == 5 || pieces.doubleValue == 13
    }
  }

  static func hasDeferredCubePathPresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-cube-path", requireAll: true) { value in
      guard Set(value.keys) == ["title", "edge"], let title = value["title"] as? String,
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 120,
        !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 60 || $0.value == 62 }),
        let edge = value["edge"] as? NSNumber, CFGetTypeID(edge) != CFBooleanGetTypeID(),
        edge.doubleValue.isFinite, edge.doubleValue.rounded() == edge.doubleValue else { return false }
      return (0...5).contains(edge.intValue)
    }
  }

  static func hasDeferredGeometryPresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-center-cut", requireAll: true) { value in
      guard Set(value.keys) == ["title", "outerWidth", "outerHeight", "hole"],
        let title = value["title"] as? String,
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 120,
        !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 60 || $0.value == 62 }),
        let hole = value["hole"] as? [String: Any],
        Set(hole.keys) == ["x", "y", "width", "height"] else { return false }
      func number(_ object: [String: Any], _ key: String) -> Double? {
        guard let value = object[key] as? NSNumber,
          CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
          value.doubleValue >= 0.001, value.doubleValue <= 1000 else { return nil }
        return value.doubleValue
      }
      guard let width = number(value, "outerWidth"), let height = number(value, "outerHeight"),
        let x = number(hole, "x"), let y = number(hole, "y"),
        let holeWidth = number(hole, "width"), let holeHeight = number(hole, "height") else { return false }
      return max(width, height) / min(width, height) <= 20
        && x < x + holeWidth && x + holeWidth < width
        && y < y + holeHeight && y + holeHeight < height
    }
  }

  static func hasDeferredRectangleDissectionPresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-rectangle-dissection", requireAll: true) { value in
      Set(value.keys) == ["case"] && value["case"] as? String == "404-e12"
    }
  }

  static func hasDeferredGridPresentation(in answer: String) -> Bool {
    hasDeferredPresentation(in: answer, language: "math-grid") { value in
      guard Set(value.keys) == ["title", "unitWidth", "unitHeight", "source", "target"],
        let title = value["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        title.count <= 120,
        ["unitWidth", "unitHeight"].allSatisfy({ key in
          guard let number = value[key] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
          return number.doubleValue.isFinite && number.doubleValue > 0 && number.doubleValue <= 1000
        }), ["source", "target"].allSatisfy({ key in
          guard let board = value[key] as? [[String]], (1...16).contains(board.count),
            let width = board.first?.count, (1...16).contains(width) else { return false }
          return board.allSatisfy { $0.count == width && $0.allSatisfy { $0.count <= 12 } }
        }) else { return false }
      return true
    }
  }

  private static func hasDeferredPresentation(
    in answer: String, language: String, requireAll: Bool = false, rawValidate: ((String) -> Bool)? = nil, validate: ([String: Any]) -> Bool
  ) -> Bool {
    let lines = answer.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    let opening = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})([^\n]*)$"#)
    var active: (character: String, count: Int, language: String, start: Int)?
    var found = false
    for (index, line) in lines.enumerated() {
      let text = line.trimmingCharacters(in: .newlines) as NSString
      guard let frame = active else {
        if let match = opening.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) {
          let fence = text.substring(with: match.range(at: 1))
          active = (String(fence.prefix(1)), fence.count,
            text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces), index + 1)
        }
        continue
      }
      guard let closing = try? NSRegularExpression(pattern: "^ {0,3}" + frame.character + "{\(frame.count),}[ \t]*$"),
        closing.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) != nil else { continue }
      active = nil
      guard frame.language == language else { continue }
      let payload = lines[frame.start..<index].joined(separator: "\n")
      guard rawValidate?(payload) != false, let data = payload.data(using: .utf8),
        (requireAll ? payload.utf16.count <= 2000 : data.count <= 30_000),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        validate(value) else {
          if requireAll { return false }
          continue
        }
      if !requireAll { return true }
      found = true
    }
    return found && active?.language != language
  }

  static func requestsDiagram(
    _ submitted: String, using method: MathTeachingMethod?, visualMethods: [MathTeachingMethod],
    automaticSelectionFailed: Bool = false
  ) -> Bool {
    if prohibitsDiagram(submitted) { return false }
    let lower = submitted.lowercased()
    let explicitDrawing = ["画图", "画出", "线段图", "图解", "数形结合", "draw a diagram"].contains(where: lower.contains)
      || ["面积图", "状态图", "周期图", "韦恩图", "间隔图", "整体分段图", "部分整体图"].contains(where: lower.contains)
      || (["画", "绘", "draw"].contains(where: lower.contains)
        && !diagramViews(submitted, method: nil, visualMethods: []).isEmpty)
    let solving = ["解题", "数学", "solve"].contains(where: lower.contains)
    let visualPrimary = method.map { entry in
      entry.category.contains("数形结合") || ["线段图", "面积图", "状态图", "列表法", "韦恩", "周期", "部分整体", "平均", "差倍"]
        .contains(where: entry.title.contains)
    } ?? false
    return explicitDrawing || !visualMethods.isEmpty || visualPrimary
      || (solving && (automaticSelectionFailed || method != nil))
  }

  static func explicitlyRequestsDiagram(_ submitted: String) -> Bool {
    guard !prohibitsDiagram(submitted) else { return false }
    return isDiagramFollowup(submitted)
      || requestsDiagram(submitted, using: nil, visualMethods: [])
      || !diagramViews(submitted, method: nil, visualMethods: []).isEmpty
  }

  @objc private func supplementDiagram() {
    guard !isAnswering, !history.isEmpty else { return }
    imageCheckbox.state = .on
    question.stringValue = "请补图，依据当前原图选择真正帮助理解的画法；不合适时说明原因，不编造条件。"
    ask()
  }

  /// Explicit requested geometry wins; category labels are not a rendering capability.
  static func diagramViews(_ submitted: String, method: MathTeachingMethod?, visualMethods: [MathTeachingMethod]) -> [MathDiagram.Kind] {
    func kinds(_ text: String) -> [MathDiagram.Kind] {
      let mapping: [(String, MathDiagram.Kind)] = [("面积图", .area), ("韦恩", .venn), ("平均移量", .balance),
        ("整体分段", .partWhole), ("部分整体", .partWhole), ("周期", .cycle), ("点与间隔", .interval),
        ("间隔图", .interval), ("状态图", .state), ("列表", .table), ("表格", .table),
        ("等份", .equalParts), ("份数线段", .equalParts), ("比较线段", .barComparison)]
      return mapping.compactMap { text.contains($0.0) ? $0.1 : nil }
    }
    var selected = kinds(submitted)
    if selected.isEmpty && submitted.contains("线段图") { selected = [.barComparison, .equalParts] }
    // A distribution table compares the two allocations directly. This default
    // does not override an explicit user-requested drawing family.
    if selected.isEmpty && boundDiagramRecipe(method) == "surplus-and-shortfall" { selected = [.table] }
    if selected.isEmpty { selected = visualMethods.flatMap { kinds($0.title) } }
    if selected.isEmpty, let method { selected = kinds(method.title) }
    if selected.isEmpty, let method, method.title.contains("差倍") || method.title.contains("和倍") { selected = [.equalParts] }
    if selected.isEmpty && (submitted.contains("线段图") || visualMethods.contains { $0.title.contains("线段图") }
      || method?.title.contains("线段图") == true) { selected = [.barComparison, .equalParts] }
    return selected.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }

  static func prohibitsDiagram(_ submitted: String) -> Bool {
    let lower = submitted.lowercased()
    return ["不画图", "不要画图", "不用画图", "无需画图", "不需要画图", "不画线段图", "不要画线段图", "不用线段图", "不要线段图", "不要图解", "不用图解", "只要文字", "只用文字", "without diagram", "no diagram"]
      .contains(where: lower.contains)
  }

  private func refreshSaveControls() {
    previewOriginalButton.isHidden = originalImageData == nil
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

  @objc private func previewOriginalScreenshot() {
    guard let originalImageData, let image = NSImage(data: originalImageData),
      let bitmap = NSBitmapImageRep(data: originalImageData) else { return }
    let preview = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    preview.title = "原截图 · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)"
    preview.isReleasedWhenClosed = false
    let view = NSImageView()
    view.image = image
    view.imageScaling = .scaleProportionallyDown
    view.setAccessibilityLabel("原始截图预览")
    preview.contentView = view
    originalPreview?.close()
    originalPreview = preview
    preview.center()
    preview.bringToFront()
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

  private var generatedAnswerText: String {
    var answers = history.map(\.answer).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if pendingQuestion != nil, !partialAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      answers.append(partialAnswer)
    }
    return answers.joined(separator: "\n\n──────────\n\n")
  }

  private func refreshCopyAnswerButton() {
    copyAnswerButton.isEnabled = !generatedAnswerText.isEmpty
    copyAnswerButton.title = ""
    copyAnswerButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制回答")
    copyAnswerButton.toolTip = "复制全部已生成回答的原文，保留 Markdown、公式和图表源码"
  }

  @objc private func copyGeneratedAnswers() {
    let text = generatedAnswerText
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else { return }
    copyAnswerButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
    copyAnswerButton.title = "已复制"
    copyAnswerButton.toolTip = "回答文字已复制"
  }

  private func renderRichTranscript(focusLatestDiagram: Bool = false) {
    var turns: [ScreenshotAnswerTurn] = history.enumerated().map { index, turn in
      let solution = conversationSolutions[index]
      var notes = solution?.reviewedExamples.map(\.displayLabel) ?? []
      if !notes.isEmpty { notes.append("供本次判断，不代表已采用或本题已通过核验。") }
      if let notice = solution?.arithmeticNotice { notes.append(notice) }
      if let failure = solution?.diagramFailure { notes.append("图解未完成：" + failure) }
      let images: [String] = (solution?.diagrams ?? []).compactMap { diagram in
        do {
          let key = try JSONEncoder().encode(diagram) as NSData
          if let cached = webDiagramImages.object(forKey: key) { return cached as String }
          let png = try MathDiagramRenderer.renderPNG(diagram).base64EncodedString()
          webDiagramImages.setObject(png as NSString, forKey: key)
          return png
        } catch {
          notes.append("图解未显示：" + error.localizedDescription)
          return nil
        }
      }
      return ScreenshotAnswerTurn(question: turn.question, answer: turn.answer,
        diagramPNGs: images, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
    if let pendingQuestion {
      let answer = partialAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? (pendingOutcome.isEmpty ? "正在思考…" : "没有生成完整回答。") : partialAnswer
      turns.append(ScreenshotAnswerTurn(question: pendingQuestion,
        answer: answer + (pendingOutcome.isEmpty ? "" : "\n\n[\(pendingOutcome)]")))
    }
    richTranscript.render(turns: turns, zoom: zoomScale, focusLatestDiagram: focusLatestDiagram)
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

  private func renderTranscript(focusLatestDiagram: Bool = false) {
    transcriptUpdateTask?.cancel()
    transcriptUpdateTask = nil
    updateTranscriptWidth()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 16 * zoomScale), .foregroundColor: NSColor.labelColor,
      .paragraphStyle: transcript.defaultParagraphStyle ?? NSParagraphStyle.default,
    ]
    let rendered = NSMutableAttributedString(string: "")
    var latestDiagramLocation: Int?
    for (index, turn) in history.enumerated() {
      if index > 0 { rendered.append(NSAttributedString(string: "\n\n──────────\n\n", attributes: attributes)) }
      rendered.append(NSAttributedString(string: "你：\(turn.question)\n\n", attributes: attributes))
      if let solution = conversationSolutions[index] {
        if let notice = solution.arithmeticNotice {
          rendered.append(NSAttributedString(string: notice + "\n\n", attributes: attributes))
        }
        let diagramStart = rendered.length
        MathDiagramPresentation.append(solution.diagrams, failure: solution.diagramFailure,
          to: rendered, width: (transcript.textContainer?.containerSize.width ?? 700) - 24,
          fontSize: 16 * zoomScale)
        if !solution.diagrams.isEmpty && index == history.count - 1 {
          rendered.enumerateAttribute(.attachment, in: NSRange(location: diagramStart, length: rendered.length - diagramStart)) { value, range, stop in
            if value is NSTextAttachment { latestDiagramLocation = range.location; stop.pointee = true }
          }
        }
      }
      if let references = conversationSolutions[index]?.reviewedExamples, !references.isEmpty {
        rendered.append(NSAttributedString(string: references.map(\.displayLabel).joined(separator: "\n")
          + "\n（供本次判断，不代表已采用或本题已通过核验。）\n\n", attributes: attributes))
      }
      rendered.append(NSAttributedString(string: "回答：\(turn.answer)", attributes: attributes))
    }
    if let pendingQuestion {
      let answerText =
        partialAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? (pendingOutcome.isEmpty ? "正在思考…" : "没有生成完整回答。") : partialAnswer
      if !history.isEmpty { rendered.append(NSAttributedString(string: "\n\n──────────\n\n", attributes: attributes)) }
      rendered.append(NSAttributedString(
        string: "你：\(pendingQuestion)\n\n回答：\(answerText)"
          + (pendingOutcome.isEmpty ? "" : "\n\n[\(pendingOutcome)]"), attributes: attributes))
    }
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
    renderRichTranscript(focusLatestDiagram: focusLatestDiagram)
    refreshCopyAnswerButton()
    if focusLatestDiagram, let location = latestDiagramLocation,
      let layout = transcript.layoutManager, let container = transcript.textContainer,
      let scroll = transcript.enclosingScrollView {
      layout.ensureLayout(for: container)
      let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
      let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bounds.minY + transcript.textContainerOrigin.y)))
      scroll.reflectScrolledClipView(scroll.contentView)
    } else {
      transcript.scrollToEndOfDocument(nil)
    }
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
    methodPicker.isEnabled = true
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
    supplementDiagramButton.isHidden = true
    history.removeAll()
    conversationSolutions.removeAll()
    pendingQuestion = nil
    partialAnswer = ""
    pendingOutcome = ""
    transcript.string = ""
    richTranscript.render(turns: [], zoom: zoomScale)
    refreshCopyAnswerButton()
    performance = nil
    refreshPerformance()
    status.stringValue = "已清空对话，可以重新提问。"
  }

  @objc private func imagePreferenceChanged() {
    clearConversation()
    status.stringValue = imageCheckbox.state == .on ? "新对话将同时参考原截图。" : "新对话将参考识别文字。"
  }
}
