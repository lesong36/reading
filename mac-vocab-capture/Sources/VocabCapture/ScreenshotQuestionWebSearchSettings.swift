import AppKit

@MainActor
final class ScreenshotQuestionWebSearchSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  private let preferences: ScreenshotQuestionWebSearchPreferences
  private let key = NSSecureTextField()
  private let direct = NSButton(checkboxWithTitle: "搜索服务直连（跳过系统 HTTP 代理）", target: nil, action: nil)
  private let error = NSTextField(wrappingLabelWithString: "")
  private var onChange: (() -> Void)?
  private var onClose: (() -> Void)?

  init(preferences: ScreenshotQuestionWebSearchPreferences) {
    self.preferences = preferences
    super.init()
    panel.title = "联网检索设置"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self
    key.stringValue = preferences.apiKey
    key.placeholderString = "tvly-…（留空保存可清除）"
    key.setAccessibilityLabel("Tavily API Key")
    direct.state = preferences.directConnection ? .on : .off
    direct.setAccessibilityLabel("搜索服务直连")
    let heading = NSTextField(labelWithString: "使用 Tavily 检索网页")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let link = NSButton(title: "获取 Tavily API Key ↗", target: self, action: #selector(openProvider))
    let note = NSTextField(
      wrappingLabelWithString:
        "开启联网检索后，检索关键词会发送到 Tavily；不会将截图或模型 API Key 发给搜索服务。网页资料会发送到你选择的问答模型。检索 Key 仅保存在本机 Keychain。")
    note.font = .systemFont(ofSize: 12)
    note.textColor = .secondaryLabelColor
    error.font = .systemFont(ofSize: 12)
    error.textColor = .systemRed
    error.setAccessibilityLabel("检索设置状态")
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存", target: self, action: #selector(save))
    save.keyEquivalent = "\r"
    let actions = NSStackView(views: [NSView(), cancel, save])
    actions.spacing = 10
    let column = NSStackView(views: [
      heading, NSTextField(labelWithString: "Tavily API Key"), key, link, direct, note, error,
      actions,
    ])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.translatesAutoresizingMaskIntoConstraints = false
    let root = panel.contentView!
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      column.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
      key.heightAnchor.constraint(equalToConstant: 26),
      error.heightAnchor.constraint(equalToConstant: 28),
    ])
    for view in [key, note, error, actions] {
      view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
  }

  func present(onChange: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
    self.onChange = onChange
    self.onClose = onClose
    show()
  }

  func show() {
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(key)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancel()
    return false
  }

  @objc private func openProvider() {
    guard let url = URL(string: "https://app.tavily.com") else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func save() {
    do {
      try preferences.save(apiKey: key.stringValue, directConnection: direct.state == .on)
      onChange?()
      finish()
    } catch { self.error.stringValue = "无法保存检索设置：\(error.localizedDescription)" }
  }

  @objc private func cancel() { finish() }

  private func finish() {
    panel.orderOut(nil)
    onChange = nil
    let callback = onClose
    onClose = nil
    callback?()
  }
}
