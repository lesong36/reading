import AppKit
import Foundation

@MainActor
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
  private var performanceLabel: NSTextField!

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
    performanceLabel = label("", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
    content.addArrangedSubview(performanceLabel)

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

  func showPerformance(_ performance: DictionaryPerformance) {
    guard !isFinished else { return }
    performanceLabel.stringValue = performance.summary
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
