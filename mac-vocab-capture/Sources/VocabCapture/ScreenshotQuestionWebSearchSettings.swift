import AppKit

@MainActor
final class ScreenshotQuestionWebSearchSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 540, height: 410),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  private let preferences: ScreenshotQuestionWebSearchPreferences
  private let key = NSSecureTextField()
  private let direct = NSButton(checkboxWithTitle: "搜索服务直连（跳过系统 HTTP 代理）", target: nil, action: nil)
  private let error = NSTextField(wrappingLabelWithString: "")
  private var onChange: (() -> Void)?
  private var onClose: (() -> Void)?
  private var embeddedView: NSView?
  private var formInsets: [NSLayoutConstraint] = []
  private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

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
    let link = NSButton(title: "获取 Tavily API Key ↗", target: self, action: #selector(openProvider))
    link.bezelStyle = .inline
    error.font = .systemFont(ofSize: 12)
    error.textColor = .systemRed
    error.setAccessibilityLabel("检索设置状态")
    error.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存", target: self, action: #selector(save))
    save.keyEquivalent = "\r"
    let page = SettingsForm.page(
      title: "联网检索", subtitle: "使用 Tavily 为问答补充网页资料，兼容已配置的问答模型。",
      contents: [
        SettingsForm.group([
          SettingsForm.row("API Key", control: key), link,
          SettingsForm.label("留空保存可清除已保存的检索 Key。", secondary: true),
        ]),
        SettingsForm.group([direct,
          SettingsForm.label("直连仅作用于搜索服务，不修改系统代理。", secondary: true)]),
        SettingsForm.label("在问一问窗口勾选“联网检索”即可使用。关键词会发送到 Tavily，截图和模型 Key 不会发送给搜索服务；网页资料会提供给所选问答模型。检索 Key 仅保存在本机钥匙串。", secondary: true),
        error, SettingsForm.actions([cancelButton, save]),
      ])
    let root = panel.contentView!
    page.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(page)
    formInsets = [
      page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      page.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
    ]
    NSLayoutConstraint.activate(formInsets)
  }

  /// The host retains the controller while this form is attached to its settings page.
  func makeEmbeddedView(onChange: @escaping () -> Void = {}) -> NSView {
    self.onChange = onChange
    if let embeddedView { return embeddedView }
    let view = panel.contentView!
    panel.contentView = NSView()
    embeddedView = view
    formInsets.forEach { $0.constant = 0 }
    cancelButton.title = "还原更改"
    cancelButton.keyEquivalent = ""
    return view
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
    error.textColor = .systemRed
    do {
      try preferences.save(apiKey: key.stringValue, directConnection: direct.state == .on)
      onChange?()
      if embeddedView != nil {
        error.textColor = .secondaryLabelColor
        error.stringValue = "已保存检索设置。"
      } else { finish() }
    } catch { self.error.stringValue = "无法保存检索设置：\(error.localizedDescription)" }
  }

  @objc private func cancel() {
    if embeddedView != nil {
      key.stringValue = preferences.apiKey
      direct.state = preferences.directConnection ? .on : .off
      error.stringValue = ""
      error.textColor = .systemRed
    } else { finish() }
  }

  private func finish() {
    panel.orderOut(nil)
    onChange = nil
    let callback = onClose
    onClose = nil
    callback?()
  }
}
