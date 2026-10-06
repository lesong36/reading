import AppKit

@MainActor
final class ScreenshotQuestionQuickPromptSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 620, height: 610),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  private struct Editor {
    let id: String
    let title: NSTextField
    let prompt: NSTextView
  }
  private let preferences: ScreenshotQuestionQuickPrompts
  private let onSave: () -> Void
  private let rows = NSStackView()
  private let error = NSTextField(wrappingLabelWithString: "")
  private let count = NSTextField(labelWithString: "")
  private let addButton = NSButton(title: "新增快捷问题", target: nil, action: nil)
  private var editors: [Editor] = []

  init(preferences: ScreenshotQuestionQuickPrompts, onSave: @escaping () -> Void = {}) {
    self.preferences = preferences
    self.onSave = onSave
    super.init()
    panel.title = "快捷问题设置"
    panel.minSize = NSSize(width: 530, height: 440)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self
    buildContent()
    render(preferences.prompts)
  }

  func present() {
    render(preferences.prompts)
    error.stringValue = ""
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.contentView?.layoutSubtreeIfNeeded()
    if let title = editors.first?.title { title.scrollToVisible(title.bounds) }
    panel.makeFirstResponder(editors.first?.title ?? addButton)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancel()
    return false
  }

  private func buildContent() {
    let root = panel.contentView!
    let heading = NSTextField(labelWithString: "自定义快捷问题")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let note = NSTextField(
      wrappingLabelWithString: "最多 5 个。按钮名称用于显示，提问内容可以写得更完整。保存后立即生效。")
    note.textColor = .secondaryLabelColor
    addButton.target = self
    addButton.action = #selector(addPrompt)
    addButton.bezelStyle = .rounded
    count.textColor = .secondaryLabelColor
    count.setAccessibilityLabel("快捷问题数量")
    let toolbar = NSStackView(views: [addButton, NSView(), count])
    toolbar.spacing = 10
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 16
    rows.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    rows.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = rows
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
    ])
    error.textColor = .systemRed
    error.font = .systemFont(ofSize: 12)
    error.setAccessibilityLabel("快捷问题设置状态")
    error.heightAnchor.constraint(equalToConstant: 32).isActive = true
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存", target: self, action: #selector(save))
    // Return remains available for line breaks in the multi-line prompt editor.
    let actions = NSStackView(views: [NSView(), cancel, save])
    actions.spacing = 10
    let column = NSStackView(views: [heading, note, toolbar, scroll, error, actions])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      column.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
    ])
    for view in column.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
  }

  private func render(_ prompts: [ScreenshotQuestionQuickPrompt]) {
    for view in rows.arrangedSubviews {
      rows.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    editors = prompts.enumerated().map { index, entry in
      let title = NSTextField(string: entry.title)
      title.placeholderString = "按钮名称（最多 20 字）"
      title.setAccessibilityLabel("快捷问题 \(index + 1) 标题")
      title.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let delete = NSButton(title: "删除", target: self, action: #selector(removePrompt(_:)))
      delete.tag = index
      delete.setAccessibilityLabel("删除快捷问题 \(index + 1)")
      let titleRow = NSStackView(views: [
        NSTextField(labelWithString: "\(index + 1)."), title, delete,
      ])
      titleRow.spacing = 8
      let prompt = NSTextView(frame: NSRect(x: 0, y: 0, width: 530, height: 84))
      prompt.string = entry.prompt
      prompt.font = .systemFont(ofSize: 14)
      prompt.isRichText = false
      prompt.isHorizontallyResizable = false
      prompt.isVerticallyResizable = true
      prompt.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      prompt.autoresizingMask = [.width]
      prompt.textContainer?.widthTracksTextView = true
      prompt.textContainer?.heightTracksTextView = false
      prompt.textContainerInset = NSSize(width: 6, height: 6)
      prompt.setAccessibilityLabel("快捷问题 \(index + 1) 内容")
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
      scroll.documentView = prompt
      scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
      let row = NSStackView(views: [titleRow, scroll])
      row.orientation = .vertical
      row.alignment = .leading
      row.spacing = 6
      rows.addArrangedSubview(row)
      NSLayoutConstraint.activate([
        row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -24),
        titleRow.widthAnchor.constraint(equalTo: row.widthAnchor),
        scroll.widthAnchor.constraint(equalTo: row.widthAnchor),
      ])
      return Editor(id: entry.id, title: title, prompt: prompt)
    }
    count.stringValue = "\(editors.count) / \(ScreenshotQuestionQuickPrompts.maximumCount)"
    addButton.isEnabled = editors.count < ScreenshotQuestionQuickPrompts.maximumCount
  }

  private func draft() -> [ScreenshotQuestionQuickPrompt] {
    panel.makeFirstResponder(nil)
    return editors.map {
      ScreenshotQuestionQuickPrompt(
        id: $0.id, title: $0.title.stringValue, prompt: $0.prompt.string)
    }
  }

  @objc private func addPrompt() {
    guard editors.count < ScreenshotQuestionQuickPrompts.maximumCount else { return }
    var entries = draft()
    entries.append(ScreenshotQuestionQuickPrompt(title: "", prompt: ""))
    render(entries)
    error.stringValue = ""
    panel.contentView?.layoutSubtreeIfNeeded()
    if let title = editors.last?.title {
      title.scrollToVisible(title.bounds)
      panel.makeFirstResponder(title)
    }
  }

  @objc private func removePrompt(_ sender: NSButton) {
    var entries = draft()
    guard entries.indices.contains(sender.tag) else { return }
    entries.remove(at: sender.tag)
    render(entries)
    error.stringValue = ""
  }

  @objc private func save() {
    do {
      try preferences.save(draft())
      panel.orderOut(nil)
      onSave()
    } catch { self.error.stringValue = error.localizedDescription }
  }

  @objc private func cancel() { panel.orderOut(nil) }
}
